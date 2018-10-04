{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Raft.Monad where

import Protolude
import qualified Debug.Trace as DT
import Control.Monad.RWS
import qualified Data.Set as Set
import qualified Data.Map as Map

import Raft.Action
import Raft.Config
import Raft.Event
import Raft.Log
import Raft.Persistent
import Raft.NodeState
import Raft.RPC
import Raft.Types

--------------------------------------------------------------------------------
-- Raft Monad
--------------------------------------------------------------------------------

newtype TransitionM v a = TransitionM
  { unTransitionM :: RWS NodeConfig [Action v] (PersistentState v) a
  } deriving (Functor, Applicative, Monad, MonadWriter [Action v], MonadReader NodeConfig, MonadState (PersistentState v))

runTransitionM
  :: NodeConfig
  -> PersistentState v
  -> TransitionM v a
  -> (a, PersistentState v, [Action v])
runTransitionM nodeConfig persistentState transition =
  runRWS (unTransitionM transition) nodeConfig persistentState

--------------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------------

type RPCHandler s r v = RPCType r v => NodeState s -> NodeId -> r -> TransitionM v (ResultState s v)
type TimeoutHandler s v = NodeState s -> Timeout -> TransitionM v (ResultState s v)
type ClientReqHandler s v = NodeState s -> ClientReq v -> TransitionM v (ResultState s v)

--------------------------------------------------------------------------------
-- RWS Helpers
--------------------------------------------------------------------------------

-- | Helper for message actions
toRPCMessage :: RPCType r v => r -> TransitionM v (Message v)
toRPCMessage msg = flip RPC (toRPC msg) <$> asks configNodeId

broadcast :: RPCType r v => r -> TransitionM v ()
broadcast msg = do
  selfNodeId <- asks configNodeId
  action <-
    Broadcast
      <$> asks (Set.filter (selfNodeId /=) . configNodeIds)
      <*> toRPCMessage msg
  tell [action]

send :: RPCType r v => NodeId -> r -> TransitionM v ()
send nodeId msg = do
  action <- SendMessage nodeId <$> toRPCMessage msg
  tell [action]

uniqueBroadcast :: RPCType r v => Map NodeId r -> TransitionM v ()
uniqueBroadcast msgs = do
  action <- SendMessages <$> mapM toRPCMessage msgs
  tell [action]

-- | Resets the election timeout.
resetElectionTimeout :: TransitionM v ()
resetElectionTimeout = do
  t <- fromIntegral <$> asks configElectionTimeout
  tell [ResetTimeoutTimer ElectionTimeout t]

resetHeartbeatTimeout :: TransitionM v ()
resetHeartbeatTimeout = do
  t <- fromIntegral <$> asks configHeartbeatTimeout
  tell [ResetTimeoutTimer HeartbeatTimeout t]

redirectClientToLeader :: ClientId -> CurrentLeader -> TransitionM v ()
redirectClientToLeader clientId currentLeader =
  tell [RedirectClient clientId currentLeader]

applyLogEntry :: Index -> TransitionM v ()
applyLogEntry idx = do
  mLogEntry <- lookupLogEntry idx <$> gets psLog
  case mLogEntry of
    Nothing -> panic "Cannot apply non existent log entry to state machine"
    Just logEntry -> tell [ApplyCommittedLogEntry logEntry]

incrementTerm :: TransitionM v ()
incrementTerm = do
  psNextTerm <- gets (incrTerm . psCurrentTerm)
  modify $ \pstate ->
    pstate { psCurrentTerm = psNextTerm }

appendNewLogEntries :: Seq (Entry v) -> TransitionM v ()
appendNewLogEntries newEntries =
  modify $ \pstate ->
    case appendLogEntries (psLog pstate) newEntries of
      Left err -> panic (show err)
      Right newLog -> pstate { psLog = newLog }

updateElectionTimeoutCandidateState :: Index -> Index -> TransitionM v CandidateState
updateElectionTimeoutCandidateState commitIndex lastApplied = do
  -- State modifications
  incrementTerm
  voteForSelf
  -- Actions to perform
  resetElectionTimeout
  broadcast =<< requestVoteMessage
  selfNodeId <- asks configNodeId

  -- Return new candidate state
  pure CandidateState
    { csCommitIndex = commitIndex
    , csLastApplied = lastApplied
    , csVotes = Set.singleton selfNodeId
    }
  where
  requestVoteMessage = do
    term <- gets psCurrentTerm
    selfNodeId <- asks configNodeId
    (logEntryIndex, logEntryTerm) <-
      lastLogEntryIndexAndTerm <$> gets psLog
    pure RequestVote
      { rvTerm = term
      , rvCandidateId = selfNodeId
      , rvLastLogIndex = logEntryIndex
      , rvLastLogTerm = logEntryTerm
      }

  voteForSelf = do
    selfNodeId <- asks configNodeId
    modify $ \pstate ->
      pstate { psVotedFor = Just selfNodeId }
