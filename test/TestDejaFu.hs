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
            newLog = dropWhileR ((<=) idx . entryIndex) log
         in testNodeState { testNodeLog = newLog }

instance RaftReadLog RaftTestM StoreCmd where
  type RaftReadLogError RaftTestM = RaftTestError
  readLogEntry (Index idx)
    | idx <= 0 = pure $ Right Nothing
    | otherwise = do
        log <- fmap testNodeLog . getNodeState =<< askSelfNodeId
        case log !? fromIntegral (pred idx) of
          Nothing -> pure (Right Nothing)
          Just e
            | entryIndex e == Index idx -> pure (Right $ Just e)
            | otherwise -> pure $ Left (RaftTestError "Malformed log")
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
    [ testGroup "Leader Election" [ testConcurrentProps (leaderElection node0) mempty ]
    , testGroup "incr(set('x', 41)) == x := 42"
        [ testConcurrentProps incrValue (Map.fromList [("x", 42)], Index 2) ]
    , testGroup "Follower redirect with no leader" [ testConcurrentProps followerRedirNoLeader NoLeader ]
    , testGroup "Follower redirect with leader" [ testConcurrentProps followerRedirLeader (CurrentLeader (LeaderId node0)) ]
    , testGroup "New leader election" [ testConcurrentProps newLeaderElection (CurrentLeader (LeaderId node2)) ]
    ]

testConcurrentProps
  :: (Eq a, Show a)
  => (TestEventChans -> TestClientRespChans -> ConcIO a)
  -> a
  -> TestTree
testConcurrentProps test expected =
  testDejafusWithSettings settings
    [ ("No deadlocks", deadlocksNever)
    , ("No Exceptions", exceptionsNever)
    , ("Success", alwaysTrue (== Right expected))
    ] $ concurrentRaftTest test
  where
    settings = defaultSettings
      { _way = randomly (mkStdGen 42) 100
      }

    concurrentRaftTest :: (TestEventChans -> TestClientRespChans -> ConcIO a) -> ConcIO a
    concurrentRaftTest runTest =
        Control.Monad.Catch.bracket setup teardown $
          uncurry runTest . snd
      where
        setup = do
          (eventChans, clientRespChans) <- initTestChanMaps
          let (testNodeEnvs, testNodeStates) = initRaftTestEnvs eventChans clientRespChans
          tids <- forkTestNodes testNodeEnvs testNodeStates
          pure (tids, (eventChans, clientRespChans))

        teardown = mapM_ killThread . fst

leaderElection :: NodeId -> TestEventChans -> TestClientRespChans -> ConcIO Store
leaderElection nid eventChans clientRespChans = do
    atomically $ writeTChan nodeEventChan (TimeoutEvent ElectionTimeout)
    pollForReadResponse nodeEventChan client0RespChan
  where
    Just nodeEventChan = Map.lookup nid eventChans
    Just client0RespChan = Map.lookup client0 clientRespChans

incrValue :: TestEventChans -> TestClientRespChans -> ConcIO (Store, Index)
incrValue eventChans clientRespChans = do
    leaderElection node0 eventChans clientRespChans
    Right idx <- do
      syncClientWrite node0EventChan (client0, client0RespChan) (Set "x" 41)
      syncClientWrite node0EventChan (client0, client0RespChan) (Incr"x")
    store <- pollForReadResponse node0EventChan client0RespChan
    pure (store, idx)
  where
    Just node0EventChan = Map.lookup node0 eventChans
    Just client0RespChan = Map.lookup client0 clientRespChans

leaderRedirect :: TestEventChans -> TestClientRespChans -> ConcIO CurrentLeader
leaderRedirect eventChans clientRespChans = do
    Left resp <- syncClientWrite node1EventChan (client0, client0RespChan) (Set "x" 42)
    pure resp
  where
    Just node1EventChan = Map.lookup node1 eventChans
    Just client0RespChan = Map.lookup client0 clientRespChans

followerRedirNoLeader :: TestEventChans -> TestClientRespChans -> ConcIO CurrentLeader
followerRedirNoLeader = leaderRedirect

followerRedirLeader :: TestEventChans -> TestClientRespChans -> ConcIO CurrentLeader
followerRedirLeader eventChans clientRespChans = do
    leaderElection node0 eventChans clientRespChans
    leaderRedirect eventChans clientRespChans

newLeaderElection :: TestEventChans -> TestClientRespChans -> ConcIO CurrentLeader
newLeaderElection eventChans clientRespChans = do
    leaderElection node0 eventChans clientRespChans
    leaderElection node1 eventChans clientRespChans
    leaderElection node2 eventChans clientRespChans
    atomically $ writeTChan node0EventChan $ clientReadReq client0
    ClientRedirectResponse (ClientRedirResp ldr) <- atomically $ readTChan client0RespChan
    pure ldr
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
    _ -> do
      liftIO $ Control.Monad.Conc.Class.threadDelay 1000
      pollForReadResponse nodeEventChan clientRespChan

syncClientRead :: TestEventChan -> (ClientId, TestClientRespChan) -> ConcIO (Either CurrentLeader Store)
syncClientRead nodeEventChan (cid, clientRespChan) = do
  atomically $ writeTChan nodeEventChan $ clientReadReq client0
  res <- atomically $ readTChan clientRespChan
  case res of
    ClientReadResponse (ClientReadResp store) -> pure $ Right store
    ClientRedirectResponse (ClientRedirResp ldr) -> pure $ Left ldr
    _ -> panic "Failed to recieve valid read response"

syncClientWrite :: TestEventChan -> (ClientId, TestClientRespChan) -> StoreCmd -> ConcIO (Either CurrentLeader Index)
syncClientWrite nodeEventChan (cid, clientRespChan) cmd = do
  atomically $ writeTChan nodeEventChan (clientWriteReq cid cmd)
  res <- atomically $ readTChan clientRespChan
  case res of
    ClientWriteResponse (ClientWriteResp idx) -> do
      heartbeat nodeEventChan
      pure $ Right idx
    ClientRedirectResponse (ClientRedirResp ldr) -> pure $ Left ldr
    _ -> panic "Failed to receive client write response..."

heartbeat :: TestEventChan -> ConcIO ()
heartbeat eventChan = atomically $ writeTChan eventChan (TimeoutEvent HeartbeatTimeout)

clientReadReq :: ClientId -> Event StoreCmd
clientReadReq cid = MessageEvent $ ClientRequestEvent $ ClientRequest cid ClientReadReq

clientWriteReq :: ClientId -> StoreCmd -> Event StoreCmd
clientWriteReq cid v = MessageEvent $ ClientRequestEvent $ ClientRequest cid $ ClientWriteReq v
