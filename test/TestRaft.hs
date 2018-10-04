{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}

module TestRaft where

import Protolude
import qualified Data.Sequence as Seq
import Data.Sequence ((<|))
import qualified Data.Map as Map
import qualified Data.Map.Merge.Lazy as Merge
import qualified Data.Set as Set
import qualified Test.Tasty.HUnit as HUnit

import Raft.Handle (handleEvent)
import Raft.Monad
import Raft.Types

node0, node1, node2 :: NodeId
node0 = "node0"
node1 = "node1"
node2 = "node2"

client0 :: ClientId
client0 = ClientId "client0"

nodeIds :: NodeIds
nodeIds = Set.fromList [node0, node1, node2]

testConfigs :: [NodeConfig]
testConfigs = [testConfig0, testConfig1, testConfig2]

testConfig0, testConfig1, testConfig2 :: NodeConfig
testConfig0 = NodeConfig
  { configNodeId = node0
  , configNodeIds = nodeIds
  , configElectionTimeout = 150
  , configHeartbeatTimeout = 20
  }
testConfig1 = NodeConfig
  { configNodeId = node1
  , configNodeIds = nodeIds
  , configElectionTimeout = 150
  , configHeartbeatTimeout = 20
  }
testConfig2 = NodeConfig
  { configNodeId = node2
  , configNodeIds = nodeIds
  , configElectionTimeout = 150
  , configHeartbeatTimeout = 20
  }

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

-- | Zip maps using function. Throws away items left and right
zipMapWith :: Ord k => (a -> b -> c) -> Map k a -> Map k b -> Map k c
zipMapWith f = Merge.merge Merge.dropMissing Merge.dropMissing (Merge.zipWithMatched (const f))

-- | Perform an inner join on maps (hence throws away items left and right)
combine :: Ord a => Map a b -> Map a c -> Map a (b, c)
combine = zipMapWith (,)

testHandleActions :: NodeId -> [Action TestValue] -> Scenario ()
testHandleActions sender =
  mapM_ (testHandleAction sender)

testHandleAction :: NodeId -> Action TestValue -> Scenario ()
testHandleAction sender action = case action of
  SendMessage nId msg -> testHandleEvent nId (Message msg)
  Broadcast nIds msg -> mapM_ (`testHandleEvent` Message msg) nIds
  ApplyCommittedLogEntry entry -> modify (\testState -> do
    let nodeLogEntries = fromMaybe Seq.empty (Map.lookup sender (testSMEntries testState))
    testState { testSMEntries
      = Map.insert sender (entry <| nodeLogEntries) (testSMEntries testState) })
  _ -> do
    liftIO $ print $ "Action: " ++ show action
    pure ()

printIfNode :: NodeId -> NodeId -> [Char] -> Scenario ()
printIfNode nId nId' msg =
  when (nId == nId') $
    liftIO $ print $ show nId ++ " " ++ msg

printIfNodes :: [NodeId] -> NodeId -> [Char] -> Scenario ()
printIfNodes nIds nId' msg =
  when (nId' `elem` nIds) $
    liftIO $ print $ show nId' ++ " " ++ msg

testHandleEvent :: NodeId -> Event TestValue -> Scenario ()
testHandleEvent nodeId event = do
  printIfNodes [node0] nodeId ("Received event: " ++ show event)
  (nodeConfig, nodeMessages, raftState, persistentState) <- getNodeInfo nodeId
  let (newRaftState, newPersistentState, actions) = handleEvent nodeConfig raftState persistentState event
  testUpdateState nodeId event newRaftState newPersistentState nodeMessages
  printIfNodes [node0] nodeId ("New RaftState: " ++ show newRaftState)
  printIfNodes [node0] nodeId ("New PersistentState: " ++ show newPersistentState)
  printIfNodes [node0] nodeId ("Generated actions: " ++ show actions)
  testHandleActions nodeId actions

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

testInitLeader :: NodeId -> Scenario ()
testInitLeader nId =
  -- When a follower times out
  -- That follower becomes a leader
  -- Other nodes get to know who is the leader
  testHandleEvent nId (Timeout ElectionTimeout)

testClientRequest :: NodeId -> Scenario ()
testClientRequest nId = do
  testHandleEvent nId (ClientRequest (ClientReq client0 TestValue))

testHeartbeat :: NodeId -> Scenario ()
testHeartbeat sender = do
  nodeStates <- gets testNodeStates
  nIds <- gets testNodeIds
  -- sender must be a leader
  let Just (raftState, persistentState) = Map.lookup sender nodeStates
  unless (isLeader raftState) $ panic $ toS (show sender ++ " must a be a leader to heartbeat")
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

  -- Send to all nodes
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

  -- Test that node0 is a leader
  -- And the rest of the nodes are followers
  liftIO $ assertLeader raftStates [(node0, NoLeader), (node1, CurrentLeader (LeaderId node0)), (node2, CurrentLeader (LeaderId node0))]
  liftIO $ assertNodeState raftStates [(node0, isLeader), (node1, isFollower), (node2, isFollower)]

unit_append_entries_client_request :: IO ()
unit_append_entries_client_request = runScenario $ do
  testInitLeader node0
  testClientRequest node0

  persistentStates0 <- gets $ fmap snd . testNodeStates
  raftStates0 <- gets $ fmap fst . testNodeStates
  smEntries0 <- gets testSMEntries

  -- Test node persistent state logs are of the right length
  liftIO $ assertAppendedLogs persistentStates0 [(node0, 1), (node1, 1), (node2, 1)]

  -- Test node0 has committed their logs but the other nodes have not yet
  -- They will update their logs on the next heartbeat
  liftIO $ assertCommittedLogIndex raftStates0 [(node0, Index 1), (node1, Index 0), (node2, Index 0)]

  -- Test that node0 has applied the committed log, i.e. it has updated its
  -- state machine. Node1 and node2 haven't updated their state machines yet.

  liftIO $ assertSMEntries smEntries0 [(node0, 1), (node1, 0), (node2, 0)]

  -- -------------- HEARTBEAT 1 ---------------------
  -- Leader heartbeats after receiving client request
  testHeartbeat node0

  persistentStates1 <- gets $ fmap snd . testNodeStates
  raftStates1 <- gets $ fmap fst . testNodeStates
  smEntries1 <- gets testSMEntries

  -- Test all nodes have committed their logs after leader heartbeats
  -- Committed logs
  liftIO $ assertCommittedLogIndex raftStates1 [(node0, Index 1), (node1, Index 1), (node2, Index 1)]
  -- Applied committed logs
  liftIO $ assertAppliedLogIndex raftStates1 [(node0, Index 1), (node1, Index 0), (node2, Index 0)]

  -- Applied logs in nodes' state machines
  -- TODO: Fix this assertion.
  --liftIO $ assertSMEntries smEntries1 [(node0, 1), (node1, 1), (node2, 1)]

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
