{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GADTs #-}

module Raft.Monad where

import Protolude
import Control.Monad.RWS
import Data.Monoid
import qualified Data.Set as Set
import qualified Data.Map as Map

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
-- Raft Monad
--------------------------------------------------------------------------------

data TWLog = TWLog
  { twNodeId :: NodeId
  , twNodeState :: Maybe Text
  , twMsg :: Text
  } deriving Show

type TWLogs = [TWLog]

data TransitionWriter v = TransitionWriter
  { twActions :: [Action v]
  , twLogs :: TWLogs
  } deriving (Show)

instance Semigroup (TransitionWriter v) where
  t1 <> t2 = TransitionWriter (twActions t1 <> twActions t2) (twLogs t1 <> twLogs t2)

instance Monoid (TransitionWriter v) where
  mempty = TransitionWriter [] []

tellLog' :: Maybe (NodeState a) -> Text -> TransitionM v ()
tellLog' nsM s = do
  nId <- asks configNodeId
  tell (mempty { twLogs = [TWLog nId (mode <$> nsM) s] })
  where
    mode :: NodeState a -> Text
    mode ns =
      case ns of
        NodeFollowerState _ -> "Follower"
        NodeCandidateState _ -> "Candidate"
        NodeLeaderState _ -> "Leader"


tellLogWithState :: NodeState a -> Text -> TransitionM v ()
tellLogWithState ns = tellLog' (Just ns)

tellLog :: Text -> TransitionM v ()
tellLog = tellLog' Nothing

tellAction :: Action v -> TransitionM v ()
tellAction a = tell (TransitionWriter [a] [])

tellActions :: [Action v] -> TransitionM v ()
tellActions as = tell (TransitionWriter as [])

newtype TransitionM v a = TransitionM
  { unTransitionM :: RWS NodeConfig (TransitionWriter v) (PersistentState v) a
  } deriving (Functor, Applicative, Monad, MonadWriter (TransitionWriter v), MonadReader NodeConfig
             , MonadState (PersistentState v))

runTransitionM
  :: NodeConfig
  -> PersistentState v
  -> TransitionM v a
  -> (a, PersistentState v, TransitionWriter v)
runTransitionM nodeConfig persistentState transition =
  runRWS (unTransitionM transition) nodeConfig persistentState

--------------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------------

type RPCHandler s r v = RPCType r v => NodeState s -> NodeId -> r -> TransitionM v (ResultState s v)
type TimeoutHandler s v = NodeState s -> Timeout -> TransitionM v (ResultState s v)
type ClientReqHandler s v = NodeState s -> ClientWriteReq v -> TransitionM v (ResultState s v)

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
  tellActions [action]

send :: RPCType r v => NodeId -> r -> TransitionM v ()
send nodeId msg = do
  action <- SendMessage nodeId <$> toRPCMessage msg
  tellActions [action]

uniqueBroadcast :: RPCType r v => Map NodeId r -> TransitionM v ()
uniqueBroadcast msgs = do
  action <- SendMessages <$> mapM toRPCMessage msgs
  tellActions [action]

-- | Resets the election timeout.
resetElectionTimeout :: TransitionM v ()
resetElectionTimeout = tellActions [ResetTimeoutTimer ElectionTimeout]

resetHeartbeatTimeout :: TransitionM v ()
resetHeartbeatTimeout = tellActions [ResetTimeoutTimer HeartbeatTimeout]

redirectClientToLeader :: ClientId -> CurrentLeader -> TransitionM v ()
redirectClientToLeader clientId currentLeader =
  tellActions [RedirectClient clientId currentLeader]

applyLogEntry :: Index -> TransitionM v ()
applyLogEntry idx = do
  mLogEntry <- lookupLogEntry idx <$> gets psLog
  case mLogEntry of
    Nothing -> panic "Cannot apply non existent log entry to state machine"
    Just logEntry -> tellActions [ApplyCommittedLogEntry logEntry]

incrementTerm :: TransitionM v ()
incrementTerm = do
  psNextTerm <- gets (incrTerm . psCurrentTerm)
  modify $ \pstate ->
    pstate { psCurrentTerm = psNextTerm
           , psVotedFor = Nothing
           }

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
