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

module TestRaft2 where

import Protolude hiding (STM, TChan, newTChan, readTChan, writeTChan, atomically)

import Data.Sequence (Seq(..), (><), dropWhileR, (!?))
import qualified Data.Map as Map
import qualified Data.Serialize as S
import Numeric.Natural

import Control.Monad.Catch
import Control.Monad.Conc.Class
import Control.Concurrent.Classy.STM.TChan

import Test.DejaFu.Conc
import qualified Test.Tasty.HUnit as HUnit

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

--------------------------------------------------------------------------------
-- Test Raft Scenarios
--
--   We want the 'RaftTestM' monad to encapsulate all state for every node in
--   the network. This includes datastructures for each node such as:
--     - the list or sequence representing the communication link used for
--       receiving messages from other nodes
--     - the event TChan (*)
--     - the replicated log
--     - the persistent state
--     - the client responses if the node was leader
--   and the read only environement for each node:
--     - the node config
--
--   For the 'RaftTestM' monad, most node interaction will happen in a pure way,
--   specified by the type class instances implemented for the monad as required
--   by the Raft library interface (but only the ones in 'runRaftNode'',
--   transitively from 'handleEventLoop')! These pure interfaces will look a lot
--   like the existing implementation details of the tests in 'test/TestRaft.hs`
--   There will, however, be a single impure component of this implementation:
--   under the hood, the raft library's core event handler loop fixes a 'TChan'
--   as the main event queue (for the moment), and thus we must use IO to fork
--   threads to run instances of raft nodes, such that they can progress via
--   `handleEvent` state machine steps called by each iteration of
--   `handleEventLoop` in which a thread blocking read on the event queue is
--   called.

--    Pure Interfaces:
--    ----------------
--      - RaftSendRPC
--      - RaftSendClient
--      - RaftPersist
--      - RaftLog
--
--    Impure Interfaces:
--    ------------------
--      - Controlled writes to nodes' event queues.
--
--
--    [note]:
--
--        Perhaps it _would_ be best to expose an event queue record or pair of
--        typeclasses parameterized by the underlying monad, exposing a
--        enqueue/dequeue interface such that the raft node can be run in pure
--        environments.
--
--        Furthermore, we could provide typeclasses or record fields to the
--        'runRaftNode' function specifiying the necessary timer behaviors
--        'startTimer', 'waitTimer', and 'resetTimer'.
--
--        These changes would result in _all_ event producers being configurable
--        by the user, instead of only the receiving of RPC messages. I'm not
--        sure if this is the best option, thus the questions remain:
--          > Is this type class overload?
--          > Are we leaving too many options to the user (programmer)?
--          > Which event producers are most important to be configurable?
--          > Which event producers would users want to configure?
--
--
--
--  TODO
--
--    Before implementation starts, we need to have a good approach to the
--    following roadblocks:
--
--      - Since timers are directly tied to the `handleAction` step of the main
--        `handleEventLoop`, we need to decide how to circumvent the
--        `runRaftNode` function's forced creation of timers.
--
--      - We need to write an intermediate `runRaftNode'` function that either
--        exposes the event 'TChan' that is used in the main `handleEventLoop` or
--        takes an event `TChan` as an argument so that the test module has
--        access to the event channel for manual placement of events.
--
--      - ... Alberto and I should discuss this implementation and decide if
--        the previous listed roadblocks are the only ones that need to be
--        crossed.
--
--------------------------------------------------------------------------------

type TestEventChan = EventChan RaftTestM StoreCmd
type TestClientRespChan = TChan (STM RaftTestM) (ClientResponse Store)

-- | Node specific environment
data TestNodeEnv = TestNodeEnv
  { testNodeEventChans :: Map NodeId TestEventChan
  , testNodeConfig :: NodeConfig
  , testClientRespChans :: Map ClientId TestClientRespChan
  }

-- | Node specific state
data TestNodeState = TestNodeState
  { testNodeLog :: Entries StoreCmd
  , testNodePersistentState :: PersistentState
  }

-- | A map of node ids to their respective node data
type TestState = Map NodeId TestNodeState

newtype RaftTestM a = RaftTestM {
    unRaftTestM :: ReaderT TestNodeEnv (StateT TestState ConcIO) a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadReader TestNodeEnv, MonadState TestState)

deriving instance MonadThrow RaftTestM
deriving instance MonadCatch RaftTestM
deriving instance MonadMask RaftTestM
deriving instance MonadConc RaftTestM

runRaftTestM :: TestNodeEnv -> TestState -> RaftTestM a -> ConcIO a
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
    Nothing -> throwTestErr $ "Node id " <> show nid <> " does not exist in TestState"
    Just testNodeState -> pure testNodeState

modifyNodeState :: NodeId -> (TestNodeState -> TestNodeState) -> RaftTestM ()
modifyNodeState nid f =
  modify $ \testState ->
    case Map.lookup nid testState of
      Nothing -> panic $ "Node id " <> show nid <> " does not exist in TestState"
      Just testNodeState -> Map.insert nid (f testNodeState) testState

instance RaftPersist RaftTestM where
  type RaftPersistError RaftTestM = RaftTestError
  writePersistentState pstate' = do
    nid <- askSelfNodeId
    fmap Right $ modify $ \testState ->
      case Map.lookup nid testState of
        Nothing -> testState
        Just testNodeState -> do
          let pstate = testNodePersistentState testNodeState
              newTestNodeState = testNodeState { testNodePersistentState = pstate' }
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

instance RaftDeleteLog RaftTestM where
  type RaftDeleteLogError RaftTestM = RaftTestError
  deleteLogEntriesFrom idx = do
    nid <- askSelfNodeId
    fmap Right $
      modifyNodeState nid $ \testNodeState ->
        let log = testNodeLog testNodeState
            newLog = dropWhileR ((>=) idx . entryIndex) log
         in testNodeState { testNodeLog = newLog }

instance RaftReadLog RaftTestM StoreCmd where
  type RaftReadLogError RaftTestM = RaftTestError
  readLogEntry (Index idx) = do
    log <- fmap testNodeLog . getNodeState =<< askSelfNodeId
    pure $ Right (log !? fromIntegral idx)
  readLastLogEntry = do
    log <- fmap testNodeLog . getNodeState =<< askSelfNodeId
    case log of
      Empty -> pure (Right Nothing)
      _ :|> lastEntry -> pure (Right (Just lastEntry))

runTestRaftNode
  :: NodeConfig
  -> RaftTestM ()
runTestRaftNode nodeConfig = do
  eventChan <- atomically newTChan
  let raftEnv = RaftEnv eventChan (pure ()) (pure ())
  runRaftT initRaftNodeState raftEnv $
    handleEventLoop nodeConfig (mempty :: Store) (liftIO . print)
