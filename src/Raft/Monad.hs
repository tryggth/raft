{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GADTs #-}

module Raft.Monad where

import Protolude hiding (pass)
import Control.Monad.RWS
import qualified Data.Set as Set

import Raft.Action
import Raft.Client
import Raft.Config
import Raft.Event
import Raft.Log
import Raft.Persistent
import Raft.NodeState
import Raft.RPC
import Raft.Types
import Raft.Logging (RaftLogger, runRaftLoggerT, RaftLoggerT(..), LogMsg)
import qualified Raft.Logging as Logging

--------------------------------------------------------------------------------
-- State Machine
--------------------------------------------------------------------------------

-- | Interface to handle commands in the underlying state machine. Functional
--dependency permitting only a single state machine command to be defined to
--update the state machine.
class StateMachine sm v | sm -> v where
  applyCommittedLogEntry :: sm -> v -> sm

--------------------------------------------------------------------------------
-- Raft Monad
--------------------------------------------------------------------------------

tellAction :: Action sm v -> TransitionM sm v ()
tellAction a = tell [a]

tellActions :: [Action sm v] -> TransitionM sm v ()
tellActions as = tell as

data TransitionEnv sm = TransitionEnv
  { nodeConfig :: NodeConfig
  , stateMachine :: sm
  , nodeState :: RaftNodeState
  }

newtype TransitionM sm v a = TransitionM
  { unTransitionM :: RaftLoggerT (RWS (TransitionEnv sm) [Action sm v] PersistentState) a
  } deriving (Functor, Applicative, Monad)

instance MonadWriter [Action sm v] (TransitionM sm v) where
  tell = TransitionM . RaftLoggerT . tell
  listen = TransitionM . RaftLoggerT . listen . unRaftLoggerT . unTransitionM
  pass = TransitionM . RaftLoggerT . pass . unRaftLoggerT . unTransitionM

instance MonadReader (TransitionEnv sm) (TransitionM sm v) where
  ask = TransitionM . RaftLoggerT $ ask
  local f = TransitionM . RaftLoggerT . local f . unRaftLoggerT . unTransitionM

instance MonadState PersistentState (TransitionM sm v) where
  get = TransitionM . RaftLoggerT $ lift get
  put = TransitionM . RaftLoggerT . lift . put

instance RaftLogger (RWS (TransitionEnv sm) [Action sm v] PersistentState) where
  loggerNodeId = configNodeId <$> asks nodeConfig
  loggerNodeState = asks nodeState

runTransitionM
  :: TransitionEnv sm
  -> PersistentState
  -> TransitionM sm v a
  -> ((a, [LogMsg]), PersistentState, [Action sm v])
runTransitionM transEnv persistentState transitionM =
  runRWS (runRaftLoggerT (unTransitionM transitionM)) transEnv persistentState

askNodeId :: TransitionM sm v NodeId
askNodeId = asks (configNodeId . nodeConfig)

--------------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------------

type RPCHandler ns sm r v = RPCType r v => NodeState ns -> NodeId -> r -> TransitionM sm v (ResultState ns)
type TimeoutHandler ns sm v = NodeState ns -> Timeout -> TransitionM sm v (ResultState ns)
type ClientReqHandler ns sm v = NodeState ns -> ClientRequest v -> TransitionM sm v (ResultState ns)

--------------------------------------------------------------------------------
-- RWS Helpers
--------------------------------------------------------------------------------

broadcast :: SendRPCAction v -> TransitionM sm v ()
broadcast sendRPC = do
  selfNodeId <- askNodeId
  tellAction =<<
    flip BroadcastRPC sendRPC
      <$> asks (Set.filter (selfNodeId /=) . configNodeIds . nodeConfig)

send :: NodeId -> SendRPCAction v -> TransitionM sm v ()
send nodeId sendRPC = tellAction (SendRPC nodeId sendRPC)

-- | Resets the election timeout.
resetElectionTimeout :: TransitionM sm v ()
resetElectionTimeout = tellAction (ResetTimeoutTimer ElectionTimeout)

resetHeartbeatTimeout :: TransitionM sm v ()
resetHeartbeatTimeout = tellAction (ResetTimeoutTimer HeartbeatTimeout)

redirectClientToLeader :: ClientId -> CurrentLeader -> TransitionM sm v ()
redirectClientToLeader clientId currentLeader = do
  let clientRedirResp = ClientRedirectResponse (ClientRedirResp currentLeader)
  tellAction (RespondToClient clientId clientRedirResp)

respondClientRead :: ClientId -> TransitionM sm v ()
respondClientRead clientId = do
  clientReadResp <- ClientReadResponse . ClientReadResp <$> asks stateMachine
  tellAction (RespondToClient clientId clientReadResp)

appendLogEntries :: Show v => Seq (Entry v) -> TransitionM sm v ()
appendLogEntries = tellAction . AppendLogEntries

--------------------------------------------------------------------------------

startElection
  :: Index
  -> Index
  -> (Index, Term) -- ^ Last log entry data
  -> TransitionM sm v CandidateState
startElection commitIndex lastApplied lastLogEntryData = do
    incrementTerm
    voteForSelf
    resetElectionTimeout
    broadcast =<< requestVoteMessage
    selfNodeId <- askNodeId
    -- Return new candidate state
    pure CandidateState
      { csCommitIndex = commitIndex
      , csLastApplied = lastApplied
      , csVotes = Set.singleton selfNodeId
      , csLastLogEntryData = lastLogEntryData
      }
  where
    requestVoteMessage = do
      term <- currentTerm <$> get
      selfNodeId <- askNodeId
      pure $ SendRequestVoteRPC
        RequestVote
          { rvTerm = term
          , rvCandidateId = selfNodeId
          , rvLastLogIndex = fst lastLogEntryData
          , rvLastLogTerm = snd lastLogEntryData
          }

    incrementTerm = do
      psNextTerm <- incrTerm . currentTerm <$> get
      modify $ \pstate ->
        pstate { currentTerm = psNextTerm
               , votedFor = Nothing
               }

    voteForSelf = do
      selfNodeId <- askNodeId
      modify $ \pstate ->
        pstate { votedFor = Just selfNodeId }

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------

logInfo = TransitionM . Logging.logInfo
logDebug = TransitionM . Logging.logDebug
