{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}

module TestRaft where

import Protolude
import qualified Data.Sequence as Seq
import Data.Sequence ((<|))
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Test.Tasty.HUnit as HUnit

import TestUtils

import Raft.Action
import Raft.Config
import Raft.Event
import Raft.Handle (handleEvent)
import Raft.Log
import Raft.Monad
import Raft.NodeState
import Raft.Persistent
import Raft.RPC
import Raft.Types


------------------------------------
-- Scenario Monad
------------------------------------

data TestValue = TestValue
  deriving (Show, Eq)


data TestState = TestState
  { testNodeIds :: NodeIds
  , testNodeMessages :: Map NodeId (Seq (Message TestValue))
  , testNodeStates :: Map NodeId (RaftNodeState TestValue, PersistentState TestValue)
  , testNodeConfigs :: Map NodeId NodeConfig
  , testSMEntries :: Map NodeId (Entries TestValue)
  -- ^ Entries in each of the nodes' state machines
  }
  deriving (Show)

type Scenario v = StateT TestState IO v

-- | At the beginning of time, they are all followers
runScenario :: Scenario () -> IO ()
runScenario scenario = do
  let initPersistentState = PersistentState term0 Nothing (Log Seq.empty)
  let initRaftState = RaftNodeState (NodeFollowerState (FollowerState NoLeader index0 index0))
  let initTestState = TestState
                    { testNodeIds = nodeIds
                    , testNodeMessages = Map.fromList $ (, Seq.empty) <$> Set.toList nodeIds
                    , testNodeStates = Map.fromList $ (, (initRaftState, initPersistentState)) <$> Set.toList nodeIds
                    , testNodeConfigs = Map.fromList $ zip (Set.toList nodeIds) testConfigs
                    , testSMEntries = Map.empty
                    }

  evalStateT scenario initTestState

testUpdateState
  :: NodeId
  -> Event TestValue
  -> RaftNodeState TestValue
  -> PersistentState TestValue
  -> Seq (Message TestValue)
  -> Scenario ()
testUpdateState nodeId event@(Message msg) raftState persistentState nodeMessages
  = modify $ \testState@TestState{..}
      -> testState
          { testNodeMessages = Map.insert nodeId (msg Seq.<| nodeMessages) testNodeMessages
          , testNodeStates = Map.insert nodeId (raftState, persistentState) testNodeStates
          }
testUpdateState nodeId _ raftState persistentState _
  = modify $ \testState@TestState{..}
      -> testState
          { testNodeStates = Map.insert nodeId (raftState, persistentState) testNodeStates
          }

testApplyCommittedLogEntry :: NodeId -> Entry TestValue -> Scenario ()
testApplyCommittedLogEntry nId entry = modify (\testState -> do
    let nodeLogEntries = fromMaybe Seq.empty (Map.lookup nId (testSMEntries testState))
    testState { testSMEntries
       = Map.insert nId (entry <| nodeLogEntries) (testSMEntries testState)
      })

getNodeInfo :: NodeId -> Scenario (NodeConfig, Seq (Message TestValue), RaftNodeState TestValue, PersistentState TestValue)
getNodeInfo nId = do
  nodeConfigs <- gets testNodeConfigs
  nodeMessages <- gets testNodeMessages
  nodeStates <- gets testNodeStates
  let Just nodeInfo = Map.lookup nId nodeConfigs >>= \config ->
                  Map.lookup nId nodeMessages >>= \msgs ->
                  Map.lookup nId nodeStates >>= \(raftState, persistentState) ->
                  pure (config, msgs, raftState, persistentState)
  pure nodeInfo

getNodesInfo :: Scenario (Map NodeId ((NodeConfig, Seq (Message TestValue)), (RaftNodeState TestValue, PersistentState TestValue)))
getNodesInfo = do
  nodeConfigs <- gets testNodeConfigs
  nodeMessages <- gets testNodeMessages
  nodeStates <- gets testNodeStates
  pure $ nodeConfigs `combine` nodeMessages `combine` nodeStates

----------------------------------------
-- Handle actions and events
----------------------------------------

testHandleActions :: NodeId -> [Action TestValue] -> Scenario ()
testHandleActions sender =
  mapM_ (testHandleAction sender)

testHandleAction :: NodeId -> Action TestValue -> Scenario ()
testHandleAction sender action = case action of
  SendMessage nId msg -> testHandleEvent nId (Message msg)
  SendMessages msgs -> notImplemented
  Broadcast nIds msg -> mapM_ (`testHandleEvent` Message msg) nIds
  ApplyCommittedLogEntry entry -> testApplyCommittedLogEntry sender entry
  RedirectClient clientId currentLeader -> notImplemented
  RespondToClient clientId -> notImplemented
  ResetTimeoutTimer _ _ -> noop
  where
    noop = liftIO $ print $ "Action: " ++ show action

testHandleEvent :: NodeId -> Event TestValue -> Scenario ()
testHandleEvent nodeId event = do
  --liftIO $ printIfNodes [node1] nodeId ("Received event: " ++ show event)
  (nodeConfig, nodeMessages, raftState, persistentState) <- getNodeInfo nodeId
  let (newRaftState, newPersistentState, transitionW) = handleEvent nodeConfig raftState persistentState event
  testUpdateState nodeId event newRaftState newPersistentState nodeMessages
  testHandleActions nodeId (actions transitionW)

----------------------------
-- Test raft events
----------------------------

testInitLeader :: NodeId -> Scenario ()
testInitLeader nId =
  testHandleEvent nId (Timeout ElectionTimeout)

testClientRequest :: NodeId -> Scenario ()
testClientRequest nId =
  testHandleEvent nId (ClientRequest (ClientReq client0 TestValue))

testHeartbeat :: NodeId -> Scenario ()
testHeartbeat sender = do
  nodeStates <- gets testNodeStates
  nIds <- gets testNodeIds
  let Just (raftState, persistentState) = Map.lookup sender nodeStates
  unless (isRaftLeader raftState) $ panic $ toS (show sender ++ " must a be a leader to heartbeat")
  let Just entry@Entry{..} = lastLogEntry $ psLog persistentState
  let LeaderState{..} = getInnerLeaderState raftState
  let appendEntry = AppendEntries
                        { aeTerm = psCurrentTerm persistentState
                        , aeLeaderId = LeaderId sender
                        , aePrevLogIndex = entryIndex
                        , aePrevLogTerm = entryTerm
                        , aeEntries = Seq.empty
                        , aeLeaderCommit = lsCommitIndex
                        }

  -- Broadcast AppendEntriesRPC
  mapM_ (flip testHandleEvent (Message (RPC sender (AppendEntriesRPC appendEntry))))
    (Set.filter (sender /=) nIds)
  where
    getInnerLeaderState :: RaftNodeState v -> LeaderState
    getInnerLeaderState nodeState = case nodeState of
      (RaftNodeState (NodeLeaderState leaderState)) -> leaderState
      _ -> panic "Node must be a leader"

-----------------------------------------
-- Unit tests
-----------------------------------------

-- When the protocol starts, every node is a follower
-- One of these followers must become a leader
unit_init_protocol :: IO ()
unit_init_protocol = runScenario $ do
  testInitLeader node0

  raftStates <- gets $ fmap fst . testNodeStates

  -- Test that node0 is a leader and the other nodes are followers
  liftIO $ assertLeader raftStates [(node0, NoLeader), (node1, CurrentLeader (LeaderId node0)), (node2, CurrentLeader (LeaderId node0))]
  liftIO $ assertNodeState raftStates [(node0, isRaftLeader), (node1, isRaftFollower), (node2, isRaftFollower)]

unit_append_entries_client_request :: IO ()
unit_append_entries_client_request = runScenario $ do
  ---------------------------------
  testInitLeader node0
  testClientRequest node0
  ---------------------------------

  persistentStates0 <- gets $ fmap snd . testNodeStates
  raftStates0 <- gets $ fmap fst . testNodeStates
  smEntries0 <- gets testSMEntries

  liftIO $ assertAppendedLogs persistentStates0 [(node0, 1), (node1, 1), (node2, 1)]
  liftIO $ assertCommittedLogIndex raftStates0 [(node0, Index 1), (node1, Index 0), (node2, Index 0)]
  liftIO $ assertAppliedLogIndex raftStates0 [(node0, Index 1), (node1, Index 0), (node2, Index 0)]
  liftIO $ assertSMEntries smEntries0 [(node0, 1), (node1, 0), (node2, 0)]

  -- -------------- HEARTBEAT 1 ---------------------
  testHeartbeat node0
  ---------------------------------------------------

  persistentStates1 <- gets $ fmap snd . testNodeStates
  raftStates1 <- gets $ fmap fst . testNodeStates
  smEntries1 <- gets testSMEntries

  -- Test all nodes have appended, committed and applied their logs
  liftIO $ assertAppendedLogs persistentStates1 [(node0, 1), (node1, 1),(node2, 1)]
  liftIO $ assertCommittedLogIndex raftStates1 [(node0, Index 1), (node1, Index 1), (node2, Index 1)]
  liftIO $ assertAppliedLogIndex raftStates1 [(node0, Index 1), (node1, Index 1), (node2, Index 1)]
  liftIO $ assertSMEntries smEntries1 [(node0, 1), (node1, 1), (node2, 1)]

unit_new_leader :: IO ()
unit_new_leader = runScenario $ do
  testInitLeader node0
  testHandleEvent node1 (Timeout ElectionTimeout)
  raftStates <- gets $ fmap fst . testNodeStates

  liftIO $ assertNodeState raftStates [(node0, isRaftFollower), (node1, isRaftLeader), (node2, isRaftFollower)]
  liftIO $ assertLeader raftStates [(node0, CurrentLeader (LeaderId node1)), (node1, NoLeader), (node2, CurrentLeader (LeaderId node1))]

--------------------------------------------
-- Assert utils
--------------------------------------------

assertNodeState :: Map NodeId (RaftNodeState v) -> [(NodeId, RaftNodeState v -> Bool)] -> IO ()
assertNodeState raftNodeStates =
  mapM_ (\(nId, isNodeState) -> HUnit.assertBool (show nId ++ " should be in a different state")
    (maybe False isNodeState (Map.lookup nId raftNodeStates)))

assertLeader :: Map NodeId (RaftNodeState v) -> [(NodeId, CurrentLeader)] -> IO ()
assertLeader raftNodeStates =
  mapM_ (\(nId, leader) -> HUnit.assertBool (show nId ++ " should recognize " ++ show leader ++ " as its leader")
    (maybe False ((== leader) . checkCurrentLeader) (Map.lookup nId raftNodeStates)))

assertAppendedLogs :: Map NodeId (PersistentState v) -> [(NodeId, Int)] -> IO ()
assertAppendedLogs persistentStates =
  mapM_ (\(nId, len) -> HUnit.assertBool (show nId ++ " should have appended " ++ show len ++ " logs")
    (maybe False ((== len) . Seq.length . unLog . psLog) (Map.lookup nId persistentStates)))

assertCommittedLogIndex :: Map NodeId (RaftNodeState v) -> [(NodeId, Index)] -> IO ()
assertCommittedLogIndex raftNodeStates =
  mapM_ (\(nId, idx) -> HUnit.assertBool (show nId ++ " should have " ++ show idx ++ " as its last committed index")
    (maybe False ((== idx) . getCommittedLogIndex) (Map.lookup nId raftNodeStates)))

assertAppliedLogIndex :: Map NodeId (RaftNodeState v) -> [(NodeId, Index)] -> IO ()
assertAppliedLogIndex raftNodeStates =
  mapM_ (\(nId, idx) -> HUnit.assertBool (show nId ++ " should have " ++ show idx ++ " as its last applied index")
    (maybe False ((== idx) . getLastAppliedLog) (Map.lookup nId raftNodeStates)))

assertSMEntries :: Map NodeId (Entries v) -> [(NodeId, Int)] -> IO ()
assertSMEntries smEntries =
  mapM_ (\(nId, len) -> HUnit.assertBool (show nId ++ " should have applied " ++ show len ++ " logs in its state machine")
    (maybe (len == 0) ((== len) . Seq.length) (Map.lookup nId smEntries)))
