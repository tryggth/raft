{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module TestRaft where

import Protolude
import qualified Data.Sequence as Seq
import Data.Sequence (Seq(..), (|>))
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Serialize as S
import Numeric.Natural
import Control.Monad.Conc.Class (throw)

import qualified Test.Tasty.HUnit as HUnit

import TestUtils

import Raft hiding (sendClient)

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
  , testNodeLogs :: Map NodeId (Entries StoreCmd)
  , testNodeSMs :: Map NodeId Store
  , testNodeRaftStates :: Map NodeId RaftNodeState
  , testNodePersistentStates :: Map NodeId PersistentState
  , testNodeConfigs :: Map NodeId NodeConfig
  , testClientResps :: ClientResps
  } deriving (Show)

type Scenario v = StateT TestState IO v

-- | Run scenario monad with initial state
runScenario :: Scenario () -> IO ()
runScenario scenario = do
  let initPersistentState = PersistentState term0 Nothing
  let initTestState = TestState
                    { testNodeIds = nodeIds
                    , testNodeLogs = Map.fromList $ (, mempty) <$> Set.toList nodeIds
                    , testNodeSMs = Map.fromList $ (, mempty) <$> Set.toList nodeIds
                    , testNodeRaftStates = Map.fromList $ (, initRaftNodeState) <$> Set.toList nodeIds
                    , testNodePersistentStates = Map.fromList $ (, initPersistentState) <$> Set.toList nodeIds
                    , testNodeConfigs = Map.fromList $ zip (Set.toList nodeIds) testConfigs
                    , testClientResps = Map.fromList [(client0, mempty)]
                    }

  evalStateT scenario initTestState

updateStateMachine :: NodeId -> Store -> Scenario ()
updateStateMachine nodeId sm
  = modify $ \testState@TestState{..}
      -> testState
          { testNodeSMs = Map.insert nodeId sm testNodeSMs
          }

updatePersistentState :: NodeId -> PersistentState -> Scenario ()
updatePersistentState nodeId persistentState
  = modify $ \testState@TestState{..}
      -> testState
          { testNodePersistentStates = Map.insert nodeId persistentState testNodePersistentStates
          }

updateRaftNodeState :: NodeId -> RaftNodeState -> Scenario ()
updateRaftNodeState nodeId raftState
  = modify $ \testState@TestState{..}
      -> testState
          { testNodeRaftStates = Map.insert nodeId raftState testNodeRaftStates
          }

getNodeInfo :: NodeId -> Scenario (NodeConfig, Store, RaftNodeState, PersistentState)
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

sendClient :: ClientId -> ClientResponse Store -> Scenario ()
sendClient clientId resp = do
  cResps <- gets testClientResps
  let resps = lookupClientResps clientId cResps
  modify (\st -> st { testClientResps = Map.insert clientId (resps |> resp) (testClientResps st) })

-------------------
-- Log instances --
-------------------

newtype NodeEnvError = NodeEnvError Text
  deriving (Show)

instance Exception NodeEnvError

type RTLog = ReaderT NodeId (StateT TestState IO)

instance RaftWriteLog RTLog StoreCmd where
  type RaftWriteLogError RTLog = NodeEnvError
  writeLogEntries newEntries = do
    nid <- ask
    Just log <- Map.lookup nid <$> gets testNodeLogs
    modify $ \testState@TestState{..} ->
      testState { testNodeLogs = Map.insert nid (log Seq.>< newEntries) testNodeLogs }
    pure $ pure ()


instance RaftReadLog RTLog StoreCmd where
  type RaftReadLogError RTLog = NodeEnvError
  readLogEntry (Index idx) = do
    nid <- ask
    Just log <- Map.lookup nid <$> gets testNodeLogs
    case log Seq.!? fromIntegral (if idx == 0 then 0 else idx - 1) of
      Nothing -> pure (Right Nothing)
      Just e -> pure (Right (Just e))
  readLastLogEntry = do
    nid <- ask
    Just log <- Map.lookup nid <$> gets testNodeLogs
    case log of
      Seq.Empty -> pure (Right Nothing)
      (_ Seq.:|> e) -> pure (Right (Just e))

instance RaftDeleteLog RTLog where
  type RaftDeleteLogError RTLog = NodeEnvError
  deleteLogEntriesFrom idx = do
    nid <- ask
    Just log <- Map.lookup nid <$> gets testNodeLogs
    modify $ \testState@TestState{..} ->
      testState { testNodeLogs = Map.insert nid (Seq.dropWhileR ((>= idx) . entryIndex) log) testNodeLogs }
    pure $ pure ()

-------------------------------
-- Handle actions and events --
-------------------------------

testHandleLogs :: Maybe [NodeId] -> (LogMsg -> IO ()) -> LogMsgs -> Scenario ()
testHandleLogs nIdsM f logs = liftIO $
  case nIdsM of
    Nothing -> mapM_ f logs
    Just nIds -> mapM_ f (filter (\l -> twNodeId l `elem` nIds) logs)

testHandleActions :: NodeId -> [Action Store StoreCmd] -> Scenario ()
testHandleActions sender =
  mapM_ (testHandleAction sender)

testHandleAction :: NodeId -> Action Store StoreCmd -> Scenario ()
testHandleAction sender action =
  case action of
    SendRPC nId rpcAction -> do
      msg <- mkRPCfromSendRPCAction sender rpcAction
      testHandleEvent nId (MessageEvent (RPCMessageEvent msg))
    SendRPCs msgs -> notImplemented
    BroadcastRPC nIds rpcAction -> mapM_ (\nId -> do
      msg <- mkRPCfromSendRPCAction sender rpcAction
      testHandleEvent nId (MessageEvent (RPCMessageEvent msg))) nIds
    RespondToClient clientId resp -> sendClient clientId resp
    ResetTimeoutTimer _ -> noop
    AppendLogEntries entries -> do
      runReaderT (updateLog entries) sender
      modify $ \testState@TestState{..}
        -> case Map.lookup sender testNodeRaftStates of
            Nothing -> panic "No NodeState"
            Just (RaftNodeState ns) -> testState
              { testNodeRaftStates = Map.insert sender (RaftNodeState (setLastLogEntryData ns entries)) testNodeRaftStates
              }
    where
      noop = pure ()

      mkRPCfromSendRPCAction
        :: NodeId -> SendRPCAction StoreCmd -> Scenario (RPCMessage StoreCmd)
      mkRPCfromSendRPCAction nId sendRPCAction = do
        sc <- get
        (nodeConfig, _, raftState@(RaftNodeState ns), _) <- getNodeInfo nId
        RPCMessage (configNodeId nodeConfig) <$>
          case sendRPCAction of
            SendAppendEntriesRPC aeData -> do
              (entries, prevLogIndex, prevLogTerm) <-
                case aedEntriesSpec aeData of
                  FromIndex idx -> do
                    eLogEntries <- runReaderT (readLogEntriesFrom (decrIndex idx)) nId
                    case eLogEntries of
                      Left err -> throw err
                      Right log ->
                        case log of
                          pe :<| entries@(e :<| _)
                            | idx == 1 -> pure (log, index0, term0)
                            | otherwise -> pure (entries, entryIndex pe, entryTerm pe)
                          _ -> pure (log, index0, term0)
                  FromClientReq e ->
                    if entryIndex e /= Index 1
                      then do
                        eLogEntry <- runReaderT (readLogEntry (decrIndex (entryIndex e))) nId
                        case eLogEntry of
                          Left err -> throw err
                          Right Nothing -> pure (Seq.singleton e, index0, term0)
                          Right (Just (prevEntry :: Entry StoreCmd)) ->
                            pure (Seq.singleton e, entryIndex prevEntry, entryTerm prevEntry)
                      else pure (Seq.singleton e, index0, term0)
                  NoEntries _ -> do
                    let (lastLogIndex, lastLogTerm) = getLastLogEntryData ns
                    pure (Empty, lastLogIndex, lastLogTerm)
              let leaderId = LeaderId (configNodeId nodeConfig)
              pure . toRPC $
                AppendEntries
                  { aeTerm = aedTerm aeData
                  , aeLeaderId = leaderId
                  , aePrevLogIndex = prevLogIndex
                  , aePrevLogTerm = prevLogTerm
                  , aeEntries = entries
                  , aeLeaderCommit = aedLeaderCommit aeData
                  }
            SendAppendEntriesResponseRPC aer -> pure (toRPC aer)
            SendRequestVoteRPC rv -> pure (toRPC rv)
            SendRequestVoteResponseRPC rvr -> pure (toRPC rvr)

testHandleEvent :: NodeId -> Event StoreCmd -> Scenario ()
testHandleEvent nodeId event = do
  (nodeConfig, sm, raftState, persistentState) <- getNodeInfo nodeId
  let transitionEnv = TransitionEnv nodeConfig sm
  let (newRaftState, newPersistentState, transitionW) = handleEvent raftState transitionEnv persistentState event
  updatePersistentState nodeId newPersistentState
  updateRaftNodeState nodeId newRaftState
  testHandleActions nodeId (twActions transitionW)
  testHandleLogs Nothing (const $ pure ()) (twLogs transitionW)
  applyLogEntries nodeId sm
  where
    applyLogEntries
      :: NodeId
      -> Store
      -> Scenario ()
    applyLogEntries nId stateMachine  = do
        (_, _, raftNodeState@(RaftNodeState nodeState), _) <- getNodeInfo nId
        let lastAppliedIndex = lastApplied nodeState
        when (commitIndex nodeState > lastAppliedIndex) $ do
          let resNodeState = incrLastApplied nodeState
          modify $ \testState@TestState{..} -> testState {
              testNodeRaftStates = Map.insert nId (RaftNodeState resNodeState) testNodeRaftStates }
          let newLastAppliedIndex = lastApplied resNodeState
          eLogEntry <- runReaderT (readLogEntry newLastAppliedIndex) nId
          case eLogEntry of
            Left err -> throw err
            Right Nothing -> panic "No log entry at 'newLastAppliedIndex'"
            Right (Just logEntry) -> do
              let newStateMachine = applyCommittedLogEntry stateMachine (entryValue logEntry)
              updateStateMachine nId newStateMachine
              applyLogEntries nId newStateMachine

      where
        incrLastApplied :: NodeState ns -> NodeState ns
        incrLastApplied nodeState =
          case nodeState of
            NodeFollowerState fs ->
              let lastApplied' = incrIndex (fsLastApplied fs)
               in NodeFollowerState $ fs { fsLastApplied = lastApplied' }
            NodeCandidateState cs ->
              let lastApplied' = incrIndex (csLastApplied cs)
               in  NodeCandidateState $ cs { csLastApplied = lastApplied' }
            NodeLeaderState ls ->
              let lastApplied' = incrIndex (lsLastApplied ls)
               in NodeLeaderState $ ls { lsLastApplied = lastApplied' }

        lastApplied :: NodeState ns -> Index
        lastApplied = fst . getLastAppliedAndCommitIndex

        commitIndex :: NodeState ns -> Index
        commitIndex = snd . getLastAppliedAndCommitIndex


testHeartbeat :: NodeId -> Scenario ()
testHeartbeat sender = do
  nodeRaftStates <- gets testNodeRaftStates
  nodePersistentStates <- gets testNodePersistentStates
  nIds <- gets testNodeIds
  let Just raftState = Map.lookup sender nodeRaftStates
      Just persistentState = Map.lookup sender nodePersistentStates
  unless (isRaftLeader raftState) $ panic $ toS (show sender ++ " must a be a leader to heartbeat")
  let LeaderState{..} = getInnerLeaderState raftState
  let aeData = AppendEntriesData
                        { aedTerm = currentTerm persistentState
                        , aedEntriesSpec = NoEntries FromHeartbeat
                        , aedLeaderCommit = lsCommitIndex
                        }

  -- Broadcast AppendEntriesRPC
  testHandleAction sender
    (BroadcastRPC (Set.filter (sender /=) nIds) (SendAppendEntriesRPC aeData))
  where
    getInnerLeaderState :: RaftNodeState -> LeaderState
    getInnerLeaderState nodeState = case nodeState of
      (RaftNodeState (NodeLeaderState leaderState)) -> leaderState
      _ -> panic "Node must be a leader to access its leader state"


----------------------
-- Test raft events --
----------------------

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

----------------
-- Unit tests --
----------------

-- When the protocol starts, every node is a follower
unit_init_protocol :: IO ()
unit_init_protocol = runScenario $ do
  -- Node 0 becomes the leader
  testInitLeader node0

  raftStates <- gets testNodeRaftStates

  -- Node0 has become leader and other nodes are followers
  liftIO $ assertLeader raftStates [(node0, NoLeader), (node1, CurrentLeader (LeaderId node0)), (node2, CurrentLeader (LeaderId node0))]
  liftIO $ assertNodeState raftStates [(node0, isRaftLeader), (node1, isRaftFollower), (node2, isRaftFollower)]

unit_append_entries_client_request :: IO ()
unit_append_entries_client_request = runScenario $ do

  testInitLeader node0
  testClientWriteRequest testSetCmd node0

  raftStates0 <- gets testNodeRaftStates
  sms0 <- gets testNodeSMs
  logs0 <- gets testNodeLogs

  liftIO $ assertPersistedLogs logs0 [(node0, 1), (node1, 1), (node2, 1)]
  liftIO $ assertCommittedLogIndex raftStates0 [(node0, Index 1), (node1, Index 0), (node2, Index 0)]
  liftIO $ assertAppliedLogIndex raftStates0 [(node0, Index 1), (node1, Index 0), (node2, Index 0)]
  liftIO $ assertSMs sms0 [(node0, Map.fromList [(testVar, testInitVal)]), (node1, mempty), (node2, mempty)]

  ---------------------------- HEARTBEAT 1 ------------------------------
  -- After leader heartbeats, followers commit and apply leader's entries
  testHeartbeat node0
  raftStates1 <- gets testNodeRaftStates
  sms1 <- gets testNodeSMs
  logs1 <- gets testNodeLogs

  liftIO $ assertPersistedLogs logs1 [(node0, 1), (node1, 1), (node2, 1)]
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

------------------
-- Assert utils --
------------------

assertNodeState :: Map NodeId RaftNodeState -> [(NodeId, RaftNodeState -> Bool)] -> IO ()
assertNodeState raftNodeStates =
  mapM_ (\(nId, isNodeState) -> HUnit.assertBool (show nId ++ " should be in a different state")
    (maybe False isNodeState (Map.lookup nId raftNodeStates)))

assertLeader :: Map NodeId RaftNodeState -> [(NodeId, CurrentLeader)] -> IO ()
assertLeader raftNodeStates =
  mapM_ (\(nId, leader) -> HUnit.assertBool (show nId ++ " should recognize " ++ show leader ++ " as its leader")
    (maybe False ((== leader) . checkCurrentLeader) (Map.lookup nId raftNodeStates)))

assertCommittedLogIndex :: Map NodeId RaftNodeState -> [(NodeId, Index)] -> IO ()
assertCommittedLogIndex raftNodeStates =
  mapM_ (\(nId, idx) -> HUnit.assertBool (show nId ++ " should have " ++ show idx ++ " as its last committed index")
    (maybe False ((== idx) . getCommittedLogIndex) (Map.lookup nId raftNodeStates)))

assertAppliedLogIndex :: Map NodeId RaftNodeState -> [(NodeId, Index)] -> IO ()
assertAppliedLogIndex raftNodeStates =
  mapM_ (\(nId, idx) -> HUnit.assertBool (show nId ++ " should have " ++ show idx ++ " as its last applied index")
    (maybe False ((== idx) . getLastAppliedLog) (Map.lookup nId raftNodeStates)))

assertPersistedLogs :: Map NodeId (Entries v) -> [(NodeId, Int)] -> IO ()
assertPersistedLogs persistedLogs =
  mapM_ (\(nId, len) -> HUnit.assertBool (show nId ++ " should have appended " ++ show len ++ " logs")
    (maybe False ((== len) . Seq.length) (Map.lookup nId persistedLogs)))

assertSMs :: Map NodeId Store -> [(NodeId, Store)] -> IO ()
assertSMs sms =
  mapM_ (\(nId, sm) -> HUnit.assertBool (show nId ++ " state machine " ++ show sm ++ " is not valid")
    (maybe False (== sm) (Map.lookup nId sms)))
