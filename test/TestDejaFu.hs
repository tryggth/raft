{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeFamilies #-}

module TestDejaFu where

import Protolude hiding
  (STM, TChan, newTChan, readMVar, readTChan, writeTChan, atomically, killThread, ThreadId)

import Data.Sequence (Seq(..), (><), dropWhileR, (!?))
import qualified Data.Map as Map
import qualified Data.Serialize as S
import Numeric.Natural

import Control.Monad.Catch
import Control.Monad.Conc.Class
import Control.Concurrent.Classy.STM.TChan

import Test.DejaFu hiding (get, ThreadId)
import Test.DejaFu.Internal (Settings(..))
import Test.DejaFu.Conc hiding (ThreadId)
import Test.Tasty
import Test.Tasty.DejaFu hiding (get)
import qualified Test.HUnit.DejaFu as HUnit
import qualified Test.Tasty.HUnit as HUnit

import System.Random (mkStdGen)

import TestUtils

import Raft

--------------------------------------------------------------------------------
-- Test State Machine & Commands
--------------------------------------------------------------------------------

type Var = ByteString

data StoreCmd
  = Set Var Natural
  | Incr Var
  deriving (Show, Generic)

instance S.Serialize StoreCmd

type Store = Map Var Natural

instance StateMachine Store StoreCmd where
  applyCommittedLogEntry store cmd =
    case cmd of
      Set x n -> Map.insert x n store
      Incr x -> Map.adjust succ x store

type TestEventChan = EventChan ConcIO StoreCmd
type TestClientRespChan = TChan (STM ConcIO) (ClientResponse Store)

-- | Node specific environment
data TestNodeEnv = TestNodeEnv
  { testNodeEventChans :: Map NodeId TestEventChan
  , testClientRespChans :: Map ClientId TestClientRespChan
  , testNodeConfig :: NodeConfig
  }

-- | Node specific state
data TestNodeState = TestNodeState
  { testNodeLog :: Entries StoreCmd
  , testNodePersistentState :: PersistentState
  }

-- | A map of node ids to their respective node data
type TestNodeStates = Map NodeId TestNodeState

newtype RaftTestM a = RaftTestM {
    unRaftTestM :: ReaderT TestNodeEnv (StateT TestNodeStates ConcIO) a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadReader TestNodeEnv, MonadState TestNodeStates)

deriving instance MonadThrow RaftTestM
deriving instance MonadCatch RaftTestM
deriving instance MonadMask RaftTestM
deriving instance MonadConc RaftTestM

runRaftTestM :: TestNodeEnv -> TestNodeStates -> RaftTestM a -> ConcIO a
runRaftTestM testEnv testState =
  flip evalStateT testState . flip runReaderT testEnv . unRaftTestM

newtype RaftTestError = RaftTestError Text
  deriving (Show)

instance Exception RaftTestError
throwTestErr = throw . RaftTestError

askSelfNodeId :: RaftTestM NodeId
askSelfNodeId = asks (configNodeId . testNodeConfig)

lookupNodeEventChan :: NodeId -> RaftTestM TestEventChan
lookupNodeEventChan nid = do
  testChanMap <- asks testNodeEventChans
  case Map.lookup nid testChanMap of
    Nothing -> throwTestErr $ "Node id " <> show nid <> " does not exist in TestEnv"
    Just testChan -> pure testChan

getNodeState :: NodeId -> RaftTestM TestNodeState
getNodeState nid = do
  testState <- get
  case Map.lookup nid testState of
    Nothing -> throwTestErr $ "Node id " <> show nid <> " does not exist in TestNodeStates"
    Just testNodeState -> pure testNodeState

modifyNodeState :: NodeId -> (TestNodeState -> TestNodeState) -> RaftTestM ()
modifyNodeState nid f =
  modify $ \testState ->
    case Map.lookup nid testState of
      Nothing -> panic $ "Node id " <> show nid <> " does not exist in TestNodeStates"
      Just testNodeState -> Map.insert nid (f testNodeState) testState

instance RaftPersist RaftTestM where
  type RaftPersistError RaftTestM = RaftTestError
  writePersistentState pstate' = do
    nid <- askSelfNodeId
    fmap Right $ modify $ \testState ->
      case Map.lookup nid testState of
        Nothing -> testState
        Just testNodeState -> do
          let newTestNodeState = testNodeState { testNodePersistentState = pstate' }
          Map.insert nid newTestNodeState testState
  readPersistentState = do
    nid <- askSelfNodeId
    testState <- get
    case Map.lookup nid testState of
      Nothing -> pure $ Left (RaftTestError "Failed to find node in environment")
      Just testNodeState -> pure $ Right (testNodePersistentState testNodeState)

instance RaftSendRPC RaftTestM StoreCmd where
  sendRPC nid rpc = do
    eventChan <- lookupNodeEventChan nid
    atomically $ writeTChan eventChan (MessageEvent (RPCMessageEvent rpc))

instance RaftSendClient RaftTestM Store where
  sendClient cid cr = do
    clientRespChans <- asks testClientRespChans
    case Map.lookup cid clientRespChans of
      Nothing -> panic "Failed to find client id in environment"
      Just clientRespChan -> atomically (writeTChan clientRespChan cr)

instance RaftWriteLog RaftTestM StoreCmd where
  type RaftWriteLogError RaftTestM = RaftTestError
  writeLogEntries entries = do
    nid <- askSelfNodeId
    fmap Right $
      modifyNodeState nid $ \testNodeState ->
        let log = testNodeLog testNodeState
         in testNodeState { testNodeLog = log >< entries }

instance RaftDeleteLog RaftTestM StoreCmd where
  type RaftDeleteLogError RaftTestM = RaftTestError
  deleteLogEntriesFrom idx = do
    nid <- askSelfNodeId
    fmap (const $ Right DeleteSuccess) $
      modifyNodeState nid $ \testNodeState ->
        let log = testNodeLog testNodeState
            newLog = dropWhileR ((>=) idx . entryIndex) log
         in testNodeState { testNodeLog = newLog }

instance RaftReadLog RaftTestM StoreCmd where
  type RaftReadLogError RaftTestM = RaftTestError
  readLogEntry (Index idx') = do
    let idx = if idx' == 0 then 0 else pred idx'
    log <- fmap testNodeLog . getNodeState =<< askSelfNodeId
    case log !? fromIntegral idx of
      Nothing -> traceM (show log) >> pure (Right Nothing)
      Just e -> pure (Right $ Just e)
  readLastLogEntry = do
    log <- fmap testNodeLog . getNodeState =<< askSelfNodeId
    case log of
      Empty -> pure (Right Nothing)
      _ :|> lastEntry -> pure (Right (Just lastEntry))

--------------------------------------------------------------------------------

initTestChanMaps :: ConcIO (Map NodeId TestEventChan, Map ClientId TestClientRespChan)
initTestChanMaps = do
  eventChans <-
    Map.fromList . zip (toList nodeIds) <$>
      atomically (replicateM (length nodeIds) newTChan)
  clientRespChans <-
    Map.fromList . zip [client0] <$>
      atomically (replicateM 1 newTChan)
  pure (eventChans, clientRespChans)

initRaftTestEnvs
  :: Map NodeId TestEventChan
  -> Map ClientId TestClientRespChan
  -> ([TestNodeEnv], TestNodeStates)
initRaftTestEnvs eventChans clientRespChans = (testNodeEnvs, testStates)
  where
    testNodeEnvs = map (TestNodeEnv eventChans clientRespChans) testConfigs
    testStates = Map.fromList $ zip (toList nodeIds) $
      replicate (length nodeIds) (TestNodeState mempty initPersistentState)

runTestNode :: TestNodeEnv -> TestNodeStates -> ConcIO ()
runTestNode testEnv testState =
    runRaftTestM testEnv testState $
      runRaftT initRaftNodeState raftEnv $
        handleEventLoop (mempty :: Store)
  where
    nid = configNodeId (testNodeConfig testEnv)
    Just eventChan = Map.lookup nid (testNodeEventChans testEnv)
    raftEnv = RaftEnv eventChan dummyTimer dummyTimer (testNodeConfig testEnv) NoLogs
    dummyTimer = pure ()

forkTestNodes :: [TestNodeEnv] -> TestNodeStates -> ConcIO [ThreadId ConcIO]
forkTestNodes testEnvs testStates =
  mapM (fork . flip runTestNode testStates) testEnvs

--------------------------------------------------------------------------------

type TestEventChans = Map NodeId TestEventChan
type TestClientRespChans = Map ClientId TestClientRespChan

test_concurrency :: [TestTree]
test_concurrency =
    [ testGroup "Leader Election" [ noDeadlocksAndExpectedRes leaderElection mempty ]
    , testGroup "incr(incr(set 'x' 40)) == x := 42"
        [ noDeadlocksAndExpectedRes incrValue (Map.fromList [("x", 42)], Index 3) ]
    ]
  where
    settings = defaultSettings
      { _discard = Nothing -- Just $ \efa -> Just DiscardTrace -- (if either isDeadlock (const False) efa then DiscardTrace else DiscardResultAndTrace)
      , _way = randomly (mkStdGen 42) 1
      }

    noDeadlocksAndExpectedRes :: (Eq a, Show a) => (TestEventChans -> TestClientRespChans -> ConcIO a) -> a -> TestTree
    noDeadlocksAndExpectedRes test expected =
      testDejafusWithSettings settings
        [ ("No deadlocks", deadlocksNever)
        , ("Success", alwaysTrue (== Right expected))
        ] $ concurrencyTest test

concurrencyTest :: (TestEventChans -> TestClientRespChans -> ConcIO a) -> ConcIO a
concurrencyTest runTest =
    Control.Monad.Catch.bracket setup teardown $
      uncurry runTest . snd
  where
    setup = do
      (eventChans, clientRespChans) <- initTestChanMaps
      let (testNodeEnvs, testNodeStates) = initRaftTestEnvs eventChans clientRespChans
      tids <- forkTestNodes testNodeEnvs testNodeStates
      pure (tids, (eventChans, clientRespChans))

    teardown = mapM_ killThread . fst

leaderElection :: TestEventChans -> TestClientRespChans -> ConcIO Store
leaderElection eventChans clientRespChans = do
    atomically $ writeTChan node0EventChan (TimeoutEvent ElectionTimeout)
    pollForReadResponse node0EventChan client0RespChan
  where
    Just node0EventChan = Map.lookup node0 eventChans
    Just client0RespChan = Map.lookup client0 clientRespChans

incrValue :: TestEventChans -> TestClientRespChans -> ConcIO (Store, Index)
incrValue eventChans clientRespChans = do
    leaderElection eventChans clientRespChans
    ClientWriteResponse (ClientWriteResp idx) <- do
      atomically $ writeTChan node0EventChan $ clientWriteReq client0 (Set "x" 40)
      atomically $ readTChan client0RespChan
    ClientWriteResponse (ClientWriteResp _) <- do
      atomically $ writeTChan node0EventChan $ clientWriteReq client0 (Incr "x")
      atomically $ readTChan client0RespChan
    -- ClientWriteResponse (ClientWriteResp idx) <- do
    --   atomically $ writeTChan node0EventChan $ clientWriteReq client0 (Incr "x")
    --   atomically $ readTChan client0RespChan
    store <- pollForReadResponse node0EventChan client0RespChan
    pure (store, idx)
  where
    Just node0EventChan = Map.lookup node0 eventChans
    Just client0RespChan = Map.lookup client0 clientRespChans

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

pollForReadResponse :: TestEventChan -> TestClientRespChan -> ConcIO Store
pollForReadResponse nodeEventChan clientRespChan = do
  -- Warning: Do not change the separate "atomically" calls, or you may
  -- introduce a deadlock
  atomically $ writeTChan nodeEventChan $ clientReadReq client0
  res <- atomically $ readTChan clientRespChan
  case res of
    ClientReadResponse (ClientReadResp res) -> pure res
    _ -> pollForReadResponse nodeEventChan clientRespChan

clientReadReq :: ClientId -> Event StoreCmd
clientReadReq cid = MessageEvent $ ClientRequestEvent $ ClientRequest cid ClientReadReq

clientWriteReq :: ClientId -> StoreCmd -> Event StoreCmd
clientWriteReq cid v = MessageEvent $ ClientRequestEvent $ ClientRequest cid $ ClientWriteReq v
