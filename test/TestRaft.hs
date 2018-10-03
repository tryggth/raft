{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}

module TestRaft where

import Protolude
import qualified Data.Sequence as Seq
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

testHandleActions :: [Action TestValue] -> Scenario ()
testHandleActions =
  mapM_ testHandleAction

testHandleAction :: Action TestValue -> Scenario ()
testHandleAction action = case action of
  SendMessage nId msg -> testHandleEvent nId (Message msg)
  Broadcast nIds msg -> mapM_ (`testHandleEvent` Message msg) nIds
  _ -> do
    liftIO $ print $ "Action: " ++ show action
    pure ()

printIfNode :: NodeId -> NodeId -> [Char] -> Scenario ()
printIfNode nId nId' msg = do
  when (nId == nId') $
    liftIO $ print $ show nId ++ " " ++ msg

testHandleEvent :: NodeId -> Event TestValue -> Scenario ()
testHandleEvent nodeId event = do
  printIfNode node1 nodeId ("Received event: " ++ show event)
  (nodeConfig, nodeMessages, raftState, persistentState) <- getNodeInfo nodeId
  let (newRaftState, newPersistentState, actions) = handleEvent nodeConfig raftState persistentState event
  testUpdateState nodeId event newRaftState newPersistentState nodeMessages
  printIfNode node1 nodeId ("New RaftState: " ++ show newRaftState)
  printIfNode node1 nodeId ("New PersistentState: " ++ show newPersistentState)
  printIfNode node1 nodeId ("Generated actions: " ++ show actions)
  testHandleActions actions

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
  when (not $ isLeader raftState) $ panic $ toS (show sender ++ " must a be a leader to heartbeat")
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

  mapM_ (flip testHandleEvent (Message (RPC sender (AppendEntriesRPC appendEntry)))) (Set.filter (sender /=) nIds)
  where
    getInnerLeaderState :: RaftNodeState v -> LeaderState
    getInnerLeaderState nodeState = case nodeState of
      (RaftNodeState (NodeLeaderState leaderState)) -> leaderState
      _ -> panic "Node must be a leader"
  -- Send to all nodes
  --testHandleEvent nId (Message (RPC sender (AppendEntriesRPC (AppendEntries appendEntries))))

-- When the protocol starts, every node is a follower
-- One of these followers must become a leader
unit_init_protocol :: IO ()
unit_init_protocol = runScenario $ do
  testInitLeader node0

  nodeStates <- gets testNodeStates

  --liftIO $ print nodeStates
  -- Test that node0 is a leader
  liftIO $ HUnit.assertBool "Node0 has not become leader"
    (fromMaybe False $ isLeader . fst <$> Map.lookup node0 nodeStates)
  -- And the rest of the nodes are followers
  liftIO $ HUnit.assertBool "Node1 has not remained follower"
    (fromMaybe False $ isFollower . fst <$> Map.lookup node1 nodeStates)
  liftIO $ HUnit.assertBool "Node1 has not recognized node0 as leader"
    (fromMaybe False $ (== CurrentLeader (LeaderId node0)) . checkCurrentLeader . fst <$> Map.lookup node1 nodeStates)
  liftIO $ HUnit.assertBool "Node2 has not remained follower"
    (fromMaybe False $ isFollower . fst <$> Map.lookup node2 nodeStates)
  liftIO $ HUnit.assertBool "Node2 has not recognized node0 as leader"
    (fromMaybe False $ (== CurrentLeader (LeaderId node0)) . checkCurrentLeader . fst <$> Map.lookup node2 nodeStates)

checkCurrentLeader :: RaftNodeState v -> CurrentLeader
checkCurrentLeader (RaftNodeState (NodeFollowerState FollowerState{..})) = fsCurrentLeader
checkCurrentLeader (RaftNodeState (NodeCandidateState _)) = NoLeader
checkCurrentLeader (RaftNodeState (NodeLeaderState _)) = NoLeader

getLastAppliedLog :: RaftNodeState v -> Index
getLastAppliedLog (RaftNodeState (NodeFollowerState FollowerState{..})) = fsLastApplied
getLastAppliedLog (RaftNodeState (NodeCandidateState CandidateState{..})) = csLastApplied
getLastAppliedLog (RaftNodeState (NodeLeaderState LeaderState{..})) = lsLastApplied

getCommittedLogIndex :: RaftNodeState v -> Index
getCommittedLogIndex (RaftNodeState (NodeFollowerState FollowerState{..})) = fsCommitIndex
getCommittedLogIndex (RaftNodeState (NodeCandidateState CandidateState{..})) = csCommitIndex
getCommittedLogIndex (RaftNodeState (NodeLeaderState LeaderState{..})) = lsCommitIndex

unit_append_entries_client_request :: IO ()
unit_append_entries_client_request = runScenario $ do
  testInitLeader node0
  testClientRequest node0
  nodeMessages <- gets testNodeMessages
  persistentStates0 <- gets $ fmap snd . testNodeStates
  raftStates0 <- gets $ fmap fst . testNodeStates
  -- Test node logs are of the right length
  liftIO $ HUnit.assertBool "Node0 has not appended logs"
    (fromMaybe False $ (/= 0) . Seq.length . unLog . psLog <$> Map.lookup node0 persistentStates0)
  liftIO $ HUnit.assertBool "Node1 has not appended logs"
    (fromMaybe False $ (/= 0) . Seq.length . unLog . psLog <$> Map.lookup node1 persistentStates0)
  liftIO $ HUnit.assertBool "Node2 has not appended logs"
    (fromMaybe False $ (/= 0) . Seq.length . unLog . psLog <$> Map.lookup node2 persistentStates0)

  -- Test node0 has committed their logs
  liftIO $ HUnit.assertBool "Node0 has not committed logs"
    (fromMaybe False $ (== 1) . getCommittedLogIndex <$> Map.lookup node0 raftStates0)
  liftIO $ HUnit.assertBool "Node1 has committed logs"
    (fromMaybe False $ (== 0) . getCommittedLogIndex <$> Map.lookup node1 raftStates0)
  liftIO $ HUnit.assertBool "Node2 has committed logs"
    (fromMaybe False $ (== 0) . getCommittedLogIndex <$> Map.lookup node2 raftStates0)

  testHeartbeat node0

