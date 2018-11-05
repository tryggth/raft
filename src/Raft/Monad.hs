{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}

module Raft.Monad where

import Protolude
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

--------------------------------------------------------------------------------
-- State Machine
--------------------------------------------------------------------------------

--- | The underlying state machine. Functional dependency permitting only
--a single state machine command to be defined to update the state machine.
class StateMachine sm v | sm -> v where
  applyCommittedLogEntry :: sm -> v -> sm

--------------------------------------------------------------------------------
-- Raft Monad
--------------------------------------------------------------------------------

data LogMsg = LogMsg
  { twNodeId :: NodeId
  , twNodeState :: Maybe Text
  , twMsg :: Text
  } deriving Show

type LogMsgs = [LogMsg]

data TransitionWriter sm v = TransitionWriter
  { twActions :: [Action sm v]
  , twLogs :: LogMsgs
  }

instance Semigroup (TransitionWriter sm v) where
  t1 <> t2 = TransitionWriter (twActions t1 <> twActions t2) (twLogs t1 <> twLogs t2)

instance Monoid (TransitionWriter sm v) where
  mempty = TransitionWriter [] []

tellLog' :: Maybe (NodeState a) -> Text -> TransitionM sm v ()
tellLog' nsM s = do
  nid <- askNodeId
  tell (mempty { twLogs = [LogMsg nid (mode <$> nsM) s] })
  where
    mode :: NodeState a -> Text
    mode ns =
      case ns of
        NodeFollowerState _ -> "Follower"
        NodeCandidateState _ -> "Candidate"
        NodeLeaderState _ -> "Leader"

tellLogWithState :: NodeState a -> Text -> TransitionM sm v ()
tellLogWithState ns = tellLog' (Just ns)

tellLog :: Text -> TransitionM sm v ()
tellLog = tellLog' Nothing

tellAction :: Action sm v -> TransitionM sm v ()
tellAction a = tell (TransitionWriter [a] [])

tellActions :: [Action sm v] -> TransitionM sm v ()
tellActions as = tell (TransitionWriter as [])

data TransitionEnv sm = TransitionEnv
  { nodeConfig :: NodeConfig
  , stateMachine :: sm
  }

newtype TransitionM sm v a = TransitionM
  { unTransitionM :: RWS (TransitionEnv sm) (TransitionWriter sm v) PersistentState a
  } deriving (Functor, Applicative, Monad, MonadWriter (TransitionWriter sm v), MonadReader (TransitionEnv sm), MonadState PersistentState)

runTransitionM
  :: TransitionEnv sm
  -> PersistentState
  -> TransitionM sm v a
  -> (a, PersistentState, TransitionWriter sm v)
runTransitionM transEnv persistentState transition =
  runRWS (unTransitionM transition) transEnv persistentState

askNodeId :: TransitionM sm v NodeId
askNodeId = asks (configNodeId . nodeConfig)

--------------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------------

type RPCHandler ns sm r v = RPCType r v => NodeState ns -> NodeId -> r -> TransitionM sm v (ResultState ns v)
type TimeoutHandler ns sm v = NodeState ns -> Timeout -> TransitionM sm v (ResultState ns v)
type ClientReqHandler ns sm v = NodeState ns -> ClientRequest v -> TransitionM sm v (ResultState ns v)

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
