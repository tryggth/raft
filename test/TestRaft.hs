{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ViewPatterns #-}

module TestRaft where

import Protolude
import qualified Data.Sequence as Seq
import Data.Sequence (Seq(..), (<|), (|>))
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Serialize as S
import Numeric.Natural

import qualified Test.Tasty.HUnit as HUnit

import TestUtils

import Raft.Action
import Raft.Client
import Raft.Config
import Raft.Event
import Raft.Handle (handleEvent)
import Raft.Log
import Raft.Monad
import Raft.NodeState
import Raft.Persistent
import Raft.RPC
import Raft.Types

--------------------------------------------------------------------------------
-- State Machine & Commands
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


testVar :: Var
testVar = "test"

testInitVal :: Natural
testInitVal = 1

testSetCmd :: StoreCmd
testSetCmd = Set testVar testInitVal

testIncrCmd :: StoreCmd
testIncrCmd = Incr testVar

------------------------------------
-- Scenario Monad
------------------------------------
type ClientResps = Map ClientId (Seq (ClientResponse Store))
data TestState = TestState
  { testNodeIds :: NodeIds
  , testNodeSMs :: Map NodeId Store
  , testNodeRaftStates :: Map NodeId (RaftNodeState StoreCmd)
  , testNodePersistentStates :: Map NodeId (PersistentState StoreCmd)
  , testNodeConfigs :: Map NodeId NodeConfig
  , testClientResps :: ClientResps
  -- ^ Entries in each of the nodes' state machines
  } deriving (Show)

type Scenario v = StateT TestState IO v

-- | Run scenario monad with initial state
runScenario :: Scenario () -> IO ()
runScenario scenario = do
  let initPersistentState = PersistentState term0 Nothing (Log Seq.empty)
  let initRaftState = RaftNodeState (NodeFollowerState (FollowerState NoLeader index0 index0))
  let initTestState = TestState
                    { testNodeIds = nodeIds
                    , testNodeSMs = Map.fromList $ (, mempty) <$> Set.toList nodeIds
                    , testNodeRaftStates = Map.fromList $ (, initRaftState) <$> Set.toList nodeIds
                    , testNodePersistentStates = Map.fromList $ (, initPersistentState) <$> Set.toList nodeIds
                    , testNodeConfigs = Map.fromList $ zip (Set.toList nodeIds) testConfigs
                    , testClientResps = Map.fromList [(client0, mempty)]
                    }

  evalStateT scenario initTestState

testUpdateState
  :: NodeId
  -> RaftNodeState StoreCmd
  -> PersistentState StoreCmd
  -> Store
  -> Scenario ()
testUpdateState nodeId raftState persistentState sm
  = modify $ \testState@TestState{..}
      -> testState
          { testNodeSMs = Map.insert nodeId sm testNodeSMs
          , testNodeRaftStates = Map.insert nodeId raftState testNodeRaftStates
          , testNodePersistentStates = Map.insert nodeId persistentState testNodePersistentStates
          }

getNodeInfo :: NodeId -> Scenario (NodeConfig, Store, RaftNodeState StoreCmd, PersistentState StoreCmd)
getNodeInfo nId = do
  nodeConfigs <- gets testNodeConfigs
  nodeSMs <- gets testNodeSMs
  nodeRaftStates <- gets testNodeRaftStates
  nodePersistentStates <- gets testNodePersistentStates
  let Just nodeInfo = Map.lookup nId nodeConfigs >>= \config ->
                  Map.lookup nId nodeSMs >>= \store ->
                  Map.lookup nId nodeRaftStates >>= \raftState ->
                  Map.lookup nId nodePersistentStates >>= \persistentState ->
                  pure (config, store, raftState, persistentState)
  pure nodeInfo


lookupClientResps :: ClientId -> ClientResps -> Seq (ClientResponse Store)
lookupClientResps clientId cResps =
  case Map.lookup clientId cResps of
    Nothing -> panic "Client id not found"
    Just resps -> resps

lookupLastClientResp :: ClientId -> ClientResps -> ClientResponse Store
lookupLastClientResp clientId cResps = r
  where
    (_ :|> r) = lookupClientResps clientId cResps

--instance RaftSendClient (StateT TestState IO) Store where
sendClient :: ClientId -> ClientResponse Store -> Scenario ()
sendClient clientId resp = do
  cResps <- gets testClientResps
  let resps = lookupClientResps clientId cResps
  modify (\st -> st { testClientResps = Map.insert clientId (resps |> resp) (testClientResps st) })

----------------------------------------
-- Handle actions and events
----------------------------------------

testHandleLogs :: Maybe [NodeId] -> (TWLog -> IO ()) -> TWLogs -> Scenario ()
testHandleLogs nIdsM f logs = liftIO $
  case nIdsM of
    Nothing -> mapM_ f logs
    Just nIds -> mapM_ f (filter (\l -> twNodeId l `elem` nIds) logs)

testHandleActions :: NodeId -> [Action Store StoreCmd] -> Scenario ()
testHandleActions sender =
  mapM_ (testHandleAction sender)

testHandleAction :: NodeId -> Action Store StoreCmd -> Scenario ()
testHandleAction sender action = do
  case action of
    SendRPCMessage nId msg -> testHandleEvent nId (MessageEvent (RPCMessageEvent msg))
    SendRPCMessages msgs -> notImplemented
    BroadcastRPC nIds msg -> mapM_ (\nId ->
      testHandleEvent nId (MessageEvent (RPCMessageEvent msg))) nIds
    RespondToClient clientId resp -> sendClient clientId resp
    ResetTimeoutTimer _ -> noop
    where
      noop = pure ()
      --liftIO $ print $ "Action: " ++ show action

testHandleEvent :: NodeId -> Event StoreCmd -> Scenario ()
testHandleEvent nodeId event = do
  sms <- gets testNodeSMs
  case Map.lookup nodeId sms of
    Nothing -> panic $ toS $ "Error accessing state machine of node: " ++ show nodeId
    Just sm -> do
      --liftIO $ printIfNodes [node0] nodeId ("Received event: " ++ show event)
      (nodeConfig, store, raftState, persistentState) <- getNodeInfo nodeId
      let transitionSt = TransitionState persistentState store
      let (newRaftState, newTS, transitionW) = handleEvent nodeConfig raftState transitionSt event
      testUpdateState nodeId newRaftState (transPersistentState newTS) (transStateMachine newTS)
      testHandleActions nodeId (twActions transitionW)
      testHandleLogs (Just [node0]) print (twLogs transitionW)

----------------------------
-- Test raft events
----------------------------

testInitLeader :: NodeId -> Scenario ()
testInitLeader nId =
  testHandleEvent nId (TimeoutEvent ElectionTimeout)

testClientReadRequest :: NodeId -> Scenario ()
testClientReadRequest nId =
  testHandleEvent nId (MessageEvent
        (ClientRequestEvent
          (ClientRequest client0 ClientReadReq)))

testClientWriteRequest :: StoreCmd -> NodeId -> Scenario ()
testClientWriteRequest cmd nId =
  testHandleEvent nId (MessageEvent
        (ClientRequestEvent
          (ClientRequest client0 (ClientWriteReq cmd))))

testHeartbeat :: NodeId -> Scenario ()
testHeartbeat sender = do
  nodeRaftStates <- gets testNodeRaftStates
  nodePersistentStates <- gets testNodePersistentStates
  nIds <- gets testNodeIds
  let Just raftState = Map.lookup sender nodeRaftStates
  let Just persistentState = Map.lookup sender nodePersistentStates
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
  mapM_ (\nid -> testHandleEvent nid
    (MessageEvent (RPCMessageEvent (RPCMessage nid (AppendEntriesRPC appendEntry)))))
    (Set.filter (sender /=) nIds)
  where
    getInnerLeaderState :: RaftNodeState v -> LeaderState
    getInnerLeaderState nodeState = case nodeState of
      (RaftNodeState (NodeLeaderState leaderState)) -> leaderState
      _ -> panic "Node must be a leader to access its leader state"

-----------------------------------------
-- Unit tests
-----------------------------------------

-- When the protocol starts, every node is a follower
-- One of these followers must become a leader
unit_init_protocol :: IO ()
unit_init_protocol = runScenario $ do
  -- Node 0 becomes the leader
  testInitLeader node0

  raftStates <- gets testNodeRaftStates

  -- Test that node0 is a leader and the other nodes are followers
  liftIO $ assertLeader raftStates [(node0, NoLeader), (node1, CurrentLeader (LeaderId node0)), (node2, CurrentLeader (LeaderId node0))]
  liftIO $ assertNodeState raftStates [(node0, isRaftLeader), (node1, isRaftFollower), (node2, isRaftFollower)]

unit_append_entries_client_request :: IO ()
unit_append_entries_client_request = runScenario $ do
  ---------------------------------
  testInitLeader node0
  testClientWriteRequest testSetCmd node0
  ---------------------------------

  persistentStates0 <- gets testNodePersistentStates
  raftStates0 <- gets testNodeRaftStates
  sms0 <- gets testNodeSMs

  liftIO $ assertAppendedLogs persistentStates0 [(node0, 1), (node1, 1), (node2, 1)]
  liftIO $ assertCommittedLogIndex raftStates0 [(node0, Index 1), (node1, Index 0), (node2, Index 0)]
  liftIO $ assertAppliedLogIndex raftStates0 [(node0, Index 1), (node1, Index 0), (node2, Index 0)]
  liftIO $ assertSMs sms0 [(node0, Map.fromList [(testVar, testInitVal)]), (node1, mempty), (node2, mempty)]

  -- -------------- HEARTBEAT 1 ---------------------
  testHeartbeat node0
  ---------------------------------------------------

  persistentStates1 <- gets testNodePersistentStates
  raftStates1 <- gets testNodeRaftStates
  sms1 <- gets testNodeSMs

  -- Test all nodes have appended, committed and applied their logs
  liftIO $ assertAppendedLogs persistentStates1 [(node0, 1), (node1, 1),(node2, 1)]
  liftIO $ assertCommittedLogIndex raftStates1 [(node0, Index 1), (node1, Index 1), (node2, Index 1)]
  liftIO $ assertAppliedLogIndex raftStates1 [(node0, Index 1), (node1, Index 1), (node2, Index 1)]
  liftIO $ assertSMs sms1 [(node0, Map.fromList [(testVar, testInitVal)]), (node1, Map.fromList [(testVar, testInitVal)]), (node2, Map.fromList [(testVar, testInitVal)])]

unit_incr_value :: IO ()
unit_incr_value = runScenario $ do
  testInitLeader node0
  testClientWriteRequest testSetCmd node0
  testClientWriteRequest testIncrCmd node0

  testHeartbeat node0

  sms <- gets testNodeSMs
  liftIO $ assertSMs sms [(node0, Map.fromList [(testVar, succ testInitVal)]), (node1, Map.fromList [(testVar, succ testInitVal)]), (node2, Map.fromList [(testVar, succ testInitVal)])]

unit_mult_incr_value :: IO ()
unit_mult_incr_value = runScenario $ do
  testInitLeader node0
  testClientWriteRequest testSetCmd node0
  let reps = 10
  replicateM_ (fromIntegral 10) (testClientWriteRequest testIncrCmd node0)
  testHeartbeat node0

  sms <- gets testNodeSMs
  liftIO $ assertSMs sms [(node0, Map.fromList [(testVar, testInitVal + reps)]), (node1, Map.fromList [(testVar, testInitVal + reps)]), (node2, Map.fromList [(testVar, testInitVal + reps)])]

unit_client_req_no_leader :: IO ()
unit_client_req_no_leader = runScenario $ do
  testClientWriteRequest testSetCmd node1
  cResps <- gets testClientResps
  let ClientRedirectResponse (ClientRedirResp lResp) = lookupLastClientResp client0 cResps
  liftIO $ HUnit.assertBool "A follower should return a NoLeader response" (lResp == NoLeader)

unit_redirect_leader :: IO ()
unit_redirect_leader = runScenario $ do
  testInitLeader node0
  testClientWriteRequest testSetCmd node1
  cResps <- gets testClientResps
  let ClientRedirectResponse (ClientRedirResp (CurrentLeader (LeaderId lResp))) = lookupLastClientResp client0 cResps
  liftIO $ HUnit.assertBool "A follower should point to the current leader" (lResp == node0)

unit_client_read_response :: IO ()
unit_client_read_response = runScenario $ do
  testInitLeader node0
  testClientWriteRequest testSetCmd node0
  testClientReadRequest node0
  cResps <- gets testClientResps
  let ClientReadResponse (ClientReadResp store) = lookupLastClientResp client0 cResps
  liftIO $ HUnit.assertBool "A client should receive the current state of the store"
    (store == Map.fromList [(testVar, testInitVal)])

unit_client_write_response :: IO ()
unit_client_write_response = runScenario $ do
  testInitLeader node0
  testClientReadRequest node0
  testClientWriteRequest testSetCmd node0
  cResps <- gets testClientResps
  let ClientWriteResponse (ClientWriteResp idx) = lookupLastClientResp client0 cResps
  liftIO $ HUnit.assertBool "A client should receive an aknowledgement of a writing request"
    (idx == Index 1)

unit_new_leader :: IO ()
unit_new_leader = runScenario $ do
  testInitLeader node0
  testHandleEvent node1 (TimeoutEvent ElectionTimeout)
  raftStates <- gets testNodeRaftStates

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

assertSMs :: Map NodeId Store -> [(NodeId, Store)] -> IO ()
assertSMs sms =
  mapM_ (\(nId, sm) -> HUnit.assertBool (show nId ++ " state machine " ++ show sm ++ " is not valid")
    (maybe False (== sm) (Map.lookup nId sms)))
