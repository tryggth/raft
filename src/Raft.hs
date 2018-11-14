{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Raft
  ( RaftSendRPC(..)
  , RaftRecvRPC(..)
  , RaftSendClient(..)
  , RaftRecvClient(..)
  , RaftPersist(..)

  , EventChan

  , RaftEnv(..)
  , RaftNodeState(..)
  , runRaftNode
  , runRaftT

  -- Action
  , Action(..)
  , SendRPCAction(..)

  -- Client
  , ClientRequest(..)
  , ClientReq(..)
  , ClientResponse(..)
  , ClientReadResp(..)
  , ClientWriteResp(..)
  , ClientRedirResp(..)

  -- Config
  , NodeConfig(..)

  -- Event
  , Timeout(..)
  , MessageEvent(..)
  , Event(..)

  -- Handle
  , handleEventLoop
  , handleEvent

  -- Log
  , Entry(..)
  , Entries
  , RaftWriteLog(..)
  , DeleteSuccess(..)
  , RaftDeleteLog(..)
  , RaftReadLog (..)
  , RaftLog
  , RaftLogError(..)
  , RaftLogExceptions(..)
  , updateLog

  -- Logging
  , LogDest(..)
  , Severity(..)

  -- Monad
  , StateMachine(..)
  , LogMsg(..)
  , TransitionEnv(..)
  , TransitionM(..)

  -- NodeState
  , Mode(..)
  , initRaftNodeState
  , RaftNodeState(..)
  , NodeState(..)
  , CurrentLeader(..)
  , FollowerState(..)
  , CandidateState(..)
  , LeaderState(..)
  , isFollower
  , isCandidate
  , isLeader
  , setLastLogEntryData
  , getLastLogEntryData
  , getLastAppliedAndCommitIndex

  -- Persistent
  , PersistentState(..)
  , initPersistentState

  -- Types
  , NodeId
  , NodeIds
  , ClientId(..)
  , LeaderId(..)
  , Term(..)
  , term0
  , incrTerm
  , Index(..)
  , index0
  , incrIndex
  , decrIndex

  -- RPC
  , RPC(..)
  , RPCType(..)
  , RPCMessage(..)
  , AppendEntries(..)
  , AppendEntriesResponse(..)
  , RequestVote(..)
  , RequestVoteResponse(..)
  , EntriesSpec(..)
  , NoEntriesSpec(..)
  , AppendEntriesData(..)
  ) where

import Protolude hiding (STM, TChan, newTChan, readTChan, writeTChan, atomically)

import Control.Monad.Conc.Class
import Control.Concurrent.STM.Timer
import Control.Concurrent.Classy.STM.TChan
import Control.Concurrent.Classy.Async

import Control.Monad.Catch
import Control.Monad.Trans.Class

import qualified Data.Map as Map
import Data.Sequence (Seq(..), singleton)

import Raft.Action
import Raft.Client
import Raft.Config
import Raft.Event
import Raft.Handle
import Raft.Log
import Raft.Logging hiding (logInfo, logDebug)
import Raft.Monad hiding (logInfo, logDebug)
import Raft.NodeState
import Raft.Persistent
import Raft.RPC
import Raft.Types


-- | Provide an interface for nodes to send/receive messages to/from one
-- another. E.g. Control.Concurrent.Chan, Network.Socket, etc.
class RaftSendRPC m v where
  sendRPC :: NodeId -> RPCMessage v -> m ()

class RaftRecvRPC m v where
  receiveRPC :: m (RPCMessage v)


class RaftSendClient m sm where
  sendClient :: ClientId -> ClientResponse sm -> m ()

class RaftRecvClient m v where
  receiveClient :: m (ClientRequest v)

type EventChan m v = TChan (STM m) (Event v)

-- | The raft server environment composed of the concurrent variables used in
-- the effectful raft layer.
data RaftEnv v m = RaftEnv
  { eventChan :: EventChan m v
  , resetElectionTimer :: m ()
  , resetHeartbeatTimer :: m ()
  , raftNodeConfig :: NodeConfig
  , raftNodeLogDest :: LogDest
  }

newtype RaftT v m a = RaftT
  { unRaftT :: ReaderT (RaftEnv v m) (StateT RaftNodeState m) a
  } deriving (Functor, Applicative, Monad, MonadReader (RaftEnv v m), MonadState RaftNodeState, Alternative, MonadPlus)

instance MonadTrans (RaftT v) where
  lift = RaftT . lift . lift

deriving instance MonadIO m => MonadIO (RaftT v m)
deriving instance MonadThrow m => MonadThrow (RaftT v m)
deriving instance MonadCatch m => MonadCatch (RaftT v m)
deriving instance MonadMask m => MonadMask (RaftT v m)
deriving instance MonadConc m => MonadConc (RaftT v m)

instance Monad m => RaftLogger (RaftT v m) where
  loggerNodeId = asks (configNodeId . raftNodeConfig)
  loggerNodeState = get

runRaftT
  :: MonadConc m
  => RaftNodeState
  -> RaftEnv v m
  -> RaftT v m ()
  -> m ()
runRaftT raftNodeState raftEnv =
  flip evalStateT raftNodeState . flip runReaderT raftEnv . unRaftT

------------------------------------------------------------------------------

logDebug :: MonadIO m => Text -> RaftT v m ()
logDebug msg = flip logDebugIO msg =<< asks raftNodeLogDest

------------------------------------------------------------------------------

runRaftNode
  :: ( Show v, Show sm, Show (Action sm v)
     , MonadIO m, MonadConc m
     , StateMachine sm v
     , RaftSendRPC m v
     , RaftRecvRPC m v
     , RaftSendClient m sm
     , RaftRecvClient m v
     , RaftLog m v
     , RaftLogExceptions m
     , RaftPersist m
     , Exception (RaftPersistError m)
     )
   => NodeConfig
   -> LogDest
   -> Int
   -> sm
   -> m ()
runRaftNode nodeConfig@NodeConfig{..} logDest timerSeed initStateMachine = do
  eventChan <- atomically newTChan

  electionTimer <- newTimerRange timerSeed configElectionTimeout
  heartbeatTimer <- newTimer configHeartbeatTimeout

  -- Fork all event producers to run concurrently
  fork (electionTimeoutTimer electionTimer eventChan)
  fork (heartbeatTimeoutTimer heartbeatTimer eventChan)
  fork (rpcHandler eventChan)
  fork (clientReqHandler eventChan)

  let resetElectionTimer = resetTimer electionTimer
      resetHeartbeatTimer = resetTimer heartbeatTimer
      raftEnv = RaftEnv eventChan resetElectionTimer resetHeartbeatTimer nodeConfig logDest

  runRaftT initRaftNodeState raftEnv $
    handleEventLoop initStateMachine

handleEventLoop
  :: forall sm v m.
     ( Show v, Show sm, Show (Action sm v)
     , MonadIO m, MonadConc m
     , StateMachine sm v
     , RaftPersist m
     , RaftSendRPC m v
     , RaftSendClient m sm
     , RaftLog m v
     , RaftLogExceptions m
     , RaftPersist m
     , Exception (RaftPersistError m)
     )
  => sm
  -> RaftT v m ()
handleEventLoop initStateMachine = do
    ePersistentState <- lift readPersistentState
    case ePersistentState of
      Left err -> throw err
      Right pstate -> handleEventLoop' initStateMachine pstate
  where
    handleEventLoop' :: sm -> PersistentState -> RaftT v m ()
    handleEventLoop' stateMachine persistentState = do
      event <- atomically . readTChan =<< asks eventChan
      loadLogEntryTermAtAePrevLogIndex event
      raftNodeState <- get
      logDebug $ "[Event]: " <> show event
      logDebug $ "[NodeState]: " <> show raftNodeState
      Right log :: Either (RaftReadLogError m) (Entries v) <- lift $ readLogEntriesFrom index0
      logDebug $ "[Log]: " <> show log
      logDebug $ "[State Machine]: " <> show stateMachine
      logDebug $ "[Persistent State]: " <> show persistentState
      -- Perform core state machine transition, handling the current event
      nodeConfig <- asks raftNodeConfig
      let transitionEnv = TransitionEnv nodeConfig stateMachine raftNodeState
          (resRaftNodeState, resPersistentState, actions, logMsgs) =
            Raft.Handle.handleEvent raftNodeState transitionEnv persistentState event
      -- Write persistent state to disk
      eRes <- lift $ writePersistentState resPersistentState
      case eRes of
        Left err -> throw err
        Right _ -> pure ()
      -- Update raft node state with the resulting node state
      put resRaftNodeState
      -- Handle logs producek by core state machine
      handleLogs logMsgs
      -- Handle actions produced by core state machine
      handleActions nodeConfig actions
      -- Apply new log entries to the state machine
      resStateMachine <- applyLogEntries stateMachine
      handleEventLoop' resStateMachine resPersistentState

    -- In the case that a node is a follower receiving an AppendEntriesRPC
    -- Event, read the log at the aePrevLogIndex
    loadLogEntryTermAtAePrevLogIndex :: Event v -> RaftT v m ()
    loadLogEntryTermAtAePrevLogIndex event = do
      case event of
        MessageEvent (RPCMessageEvent (RPCMessage _ (AppendEntriesRPC ae))) -> do
          RaftNodeState rns <- get
          case rns of
            NodeFollowerState fs -> do
              eEntry <- lift $ readLogEntry (aePrevLogIndex ae)
              case eEntry of
                Left err -> throw err
                Right (mEntry :: Maybe (Entry v)) -> put $
                  RaftNodeState $ NodeFollowerState fs
                    { fsEntryTermAtAEIndex = entryTerm <$> mEntry }
        _ -> pure ()

handleActions
  :: ( Show v, Show sm, Show (Action sm v)
     , MonadIO m, MonadConc m
     , StateMachine sm v
     , RaftSendRPC m v
     , RaftSendClient m sm
     , RaftLog m v
     , RaftLogExceptions m
     )
  => NodeConfig
  -> [Action sm v]
  -> RaftT v m ()
handleActions = mapM_ . handleAction

handleAction
  :: forall sm v m.
     ( Show v, Show sm, Show (Action sm v)
     , MonadIO m, MonadConc m
     , StateMachine sm v
     , RaftSendRPC m v
     , RaftSendClient m sm
     , RaftLog m v
     , RaftLogExceptions m
     )
  => NodeConfig
  -> Action sm v
  -> RaftT v m ()
handleAction nodeConfig action = do
  logDebug $ "[Action]: " <> show action
  case action of
    SendRPC nid sendRpcAction -> do
      rpcMsg <- mkRPCfromSendRPCAction sendRpcAction
      lift (sendRPC nid rpcMsg)
    SendRPCs rpcMap ->
      forConcurrently_ (Map.toList rpcMap) $ \(nid, sendRpcAction) -> do
        rpcMsg <- mkRPCfromSendRPCAction sendRpcAction
        lift (sendRPC nid rpcMsg)
    BroadcastRPC nids sendRpcAction -> do
      rpcMsg <- mkRPCfromSendRPCAction sendRpcAction
      mapConcurrently_ (lift . flip sendRPC rpcMsg) nids
    RespondToClient cid cr -> lift $ sendClient cid cr
    ResetTimeoutTimer tout ->
      case tout of
        ElectionTimeout -> lift . resetElectionTimer =<< ask
        HeartbeatTimeout -> lift . resetHeartbeatTimer =<< ask
    AppendLogEntries entries -> do
      lift (updateLog entries)
      -- Update the last log entry data
      modify $ \(RaftNodeState ns) ->
        RaftNodeState (setLastLogEntryData ns entries)

  where
    mkRPCfromSendRPCAction :: SendRPCAction v -> RaftT v m (RPCMessage v)
    mkRPCfromSendRPCAction sendRPCAction = do
      RaftNodeState ns <- get
      RPCMessage (configNodeId nodeConfig) <$>
        case sendRPCAction of
          SendAppendEntriesRPC aeData -> do
            (entries, prevLogIndex, prevLogTerm) <-
              case aedEntriesSpec aeData of
                FromIndex idx -> do
                  eLogEntries <- lift (readLogEntriesFrom (decrIndex idx))
                  case eLogEntries of
                    Left err -> throw err
                    Right log ->
                      case log of
                        pe :<| entries@(e :<| _)
                          | idx == 1 -> pure (log, index0, term0)
                          | otherwise -> pure (entries, entryIndex pe, entryTerm pe)
                        _ -> pure (log, index0, term0)
                FromClientReq e -> do
                  if entryIndex e /= Index 1
                    then do
                      eLogEntry <- lift $ readLogEntry (decrIndex (entryIndex e))
                      case eLogEntry of
                        Left err -> throw err
                        Right Nothing -> pure (singleton e, index0, term0)
                        Right (Just (prevEntry :: Entry v)) ->
                          pure (singleton e, entryIndex prevEntry, entryTerm prevEntry)
                    else pure (singleton e, index0, term0)
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

    resetServerTimer f =
      lift . resetTimer =<< asks f

-- If commitIndex > lastApplied: increment lastApplied, apply
-- log[lastApplied] to state machine (Section 5.3) until the state machine
-- is up to date with all the committed log entries
applyLogEntries
  :: ( Show sm
     , MonadConc m
     , RaftReadLog m v
     , Exception (RaftReadLogError m)
     , StateMachine sm v )
  => sm
  -> RaftT v m sm
applyLogEntries stateMachine = do
    raftNodeState@(RaftNodeState nodeState) <- get
    let lastAppliedIndex = lastApplied nodeState
    if commitIndex nodeState > lastAppliedIndex
      then do
        let resNodeState = incrLastApplied nodeState
        put $ RaftNodeState resNodeState
        let newLastAppliedIndex = lastApplied resNodeState
        eLogEntry <- lift $ readLogEntry newLastAppliedIndex
        case eLogEntry of
          Left err -> throw err
          Right Nothing -> panic "No log entry at 'newLastAppliedIndex'"
          Right (Just logEntry) -> do
            let newStateMachine = applyCommittedLogEntry stateMachine (entryValue logEntry)
            applyLogEntries newStateMachine
      else pure stateMachine
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

handleLogs
  :: (MonadIO m, MonadConc m)
  => [LogMsg]
  -> RaftT v m ()
handleLogs logs = do
  logDest <- asks raftNodeLogDest
  mapM_ (logToDest logDest) logs

------------------------------------------------------------------------------
 --Event Producers
------------------------------------------------------------------------------

-- | Producer for rpc message events
rpcHandler
  :: (MonadConc m, Show v, RaftRecvRPC m v)
  => TChan (STM m) (Event v)
  -> m ()
rpcHandler eventChan =
  forever $
    receiveRPC >>= \rpcMsg -> do
      atomically $ writeTChan eventChan (MessageEvent (RPCMessageEvent rpcMsg))

-- | Producer for rpc message events
clientReqHandler
  :: (MonadConc m, RaftRecvClient m v)
  => TChan (STM m) (Event v)
  -> m ()
clientReqHandler eventChan =
  forever $
    receiveClient >>= \clientReq ->
      atomically $ writeTChan eventChan (MessageEvent (ClientRequestEvent clientReq))

-- | Producer for the election timeout event
electionTimeoutTimer :: MonadConc m => Timer m -> TChan (STM m) (Event v) -> m ()
electionTimeoutTimer timer eventChan =
  forever $ do
    startTimer timer >> waitTimer timer
    atomically $ writeTChan eventChan (TimeoutEvent ElectionTimeout)

-- | Producer for the heartbeat timeout event
heartbeatTimeoutTimer :: MonadConc m => Timer m -> TChan (STM m) (Event v) -> m ()
heartbeatTimeoutTimer timer eventChan =
  forever $ do
    startTimer timer >> waitTimer timer
    atomically $ writeTChan eventChan (TimeoutEvent HeartbeatTimeout)
