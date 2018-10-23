{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
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
-- State Machine
--------------------------------------------------------------------------------

--- | The underlying state machine. Functional dependency permitting only
--a single state machine command to be defined to update the state machine.
class StateMachine sm v | sm -> v where
  applyCommittedLogEntry :: sm -> v -> sm

--------------------------------------------------------------------------------
-- Raft Monad
--------------------------------------------------------------------------------

data TWLog = TWLog
  { twNodeId :: NodeId
  , twNodeState :: Maybe Text
  , twMsg :: Text
  } deriving Show

type TWLogs = [TWLog]

data TransitionWriter sm v = TransitionWriter
  { twActions :: [Action sm v]
  , twLogs :: TWLogs
  } deriving (Show)

instance Semigroup (TransitionWriter sm v) where
  t1 <> t2 = TransitionWriter (twActions t1 <> twActions t2) (twLogs t1 <> twLogs t2)

instance Monoid (TransitionWriter sm v) where
  mempty = TransitionWriter [] []

tellLog' :: Maybe (NodeState a) -> Text -> TransitionM sm v ()
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

tellLogWithState :: NodeState a -> Text -> TransitionM sm v ()
tellLogWithState ns = tellLog' (Just ns)

tellLog :: Text -> TransitionM sm v ()
tellLog = tellLog' Nothing

tellAction :: Action sm v -> TransitionM sm v ()
tellAction a = tell (TransitionWriter [a] [])

tellActions :: [Action sm v] -> TransitionM sm v ()
tellActions as = tell (TransitionWriter as [])

data TransitionState s v = TransitionState
  { transPersistentState :: PersistentState v
  , transStateMachine :: s
  }

getPersistentState :: TransitionM sm v (PersistentState v)
getPersistentState = gets transPersistentState

getStateMachine :: TransitionM sm v sm
getStateMachine = gets transStateMachine

modifyPersistentState :: (PersistentState v -> PersistentState v) -> TransitionM sm v ()
modifyPersistentState f =
  modify $ \transState ->
    transState { transPersistentState = f (transPersistentState transState) }

modifyStateMachine :: (sm -> sm) -> TransitionM sm v ()
modifyStateMachine f =
  modify $ \transState ->
    transState { transStateMachine = f (transStateMachine transState) }

newtype TransitionM sm v a = TransitionM
  { unTransitionM :: RWS NodeConfig (TransitionWriter sm v) (TransitionState sm v) a
  } deriving (Functor, Applicative, Monad, MonadWriter (TransitionWriter sm v), MonadReader NodeConfig
             , MonadState (TransitionState sm v))

runTransitionM
  :: NodeConfig
  -> TransitionState sm v
  -> TransitionM sm v a
  -> (a, TransitionState sm v, TransitionWriter sm v)
runTransitionM nodeConfig transState transition =
  runRWS (unTransitionM transition) nodeConfig transState

--------------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------------

type RPCHandler ns sm r v = RPCType r v => NodeState ns -> NodeId -> r -> TransitionM sm v (ResultState ns v)
type TimeoutHandler ns sm v = NodeState ns -> Timeout -> TransitionM sm v (ResultState ns v)
type ClientReqHandler ns sm v = NodeState ns -> ClientRequest v -> TransitionM sm v (ResultState ns v)

--------------------------------------------------------------------------------
-- RWS Helpers
--------------------------------------------------------------------------------

-- | Helper for message actions
toRPCMessage :: RPCType r v => r -> TransitionM sm v (RPCMessage v)
toRPCMessage msg = flip RPCMessage (toRPC msg) <$> asks configNodeId

broadcast :: RPCType r v => r -> TransitionM sm v ()
broadcast msg = do
  selfNodeId <- asks configNodeId
  action <-
    BroadcastRPC
      <$> asks (Set.filter (selfNodeId /=) . configNodeIds)
      <*> toRPCMessage msg
  tellActions [action]

send :: RPCType r v => NodeId -> r -> TransitionM sm v ()
send nodeId msg = do
  action <- SendRPCMessage nodeId <$> toRPCMessage msg
  tellActions [action]

uniqueBroadcast :: RPCType r v => Map NodeId r -> TransitionM sm v ()
uniqueBroadcast msgs = do
  action <- SendRPCMessages <$> mapM toRPCMessage msgs
  tellActions [action]

-- | Resets the election timeout.
resetElectionTimeout :: TransitionM sm v ()
resetElectionTimeout = tellActions [ResetTimeoutTimer ElectionTimeout]

resetHeartbeatTimeout :: TransitionM sm v ()
resetHeartbeatTimeout = tellActions [ResetTimeoutTimer HeartbeatTimeout]

redirectClientToLeader :: ClientId -> CurrentLeader -> TransitionM sm v ()
redirectClientToLeader clientId currentLeader = do
  let clientRedirResp = ClientRedirectResponse (ClientRedirResp currentLeader)
  tellActions [RespondToClient clientId clientRedirResp]

respondClientRead :: ClientId -> TransitionM sm v ()
respondClientRead clientId = do
  clientReadResp <- ClientReadResponse . ClientReadResp <$> getStateMachine
  tellActions [RespondToClient clientId clientReadResp]

--------------------------------------------------------------------------------

-- | Apply a log entry at the given index to the state machine
applyLogEntry :: Show v => StateMachine sm v => Index -> TransitionM sm v ()
applyLogEntry idx = do
  mLogEntry <- lookupLogEntry idx . psLog <$> getPersistentState
  case mLogEntry of
    Nothing -> panic "Cannot apply non existent log entry to state machine"
    Just logEntry ->
      modify $ \transState -> do
        let stateMachine = transStateMachine transState
            v = entryValue logEntry
        transState { transStateMachine = applyCommittedLogEntry stateMachine v }

incrementTerm :: TransitionM sm v ()
incrementTerm = do
  psNextTerm <- incrTerm . psCurrentTerm <$> getPersistentState
  modifyPersistentState $ \pstate ->
    pstate { psCurrentTerm = psNextTerm
           , psVotedFor = Nothing
           }

appendNewLogEntries :: Show v => Seq (Entry v) -> TransitionM sm v ()
appendNewLogEntries newEntries =
  modifyPersistentState $ \pstate ->
    case appendLogEntries (psLog pstate) newEntries of
      Left err -> panic (show err)
      Right newLog -> pstate { psLog = newLog }

updateElectionTimeoutCandidateState :: Index -> Index -> TransitionM sm v CandidateState
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
    term <- psCurrentTerm <$> getPersistentState
    selfNodeId <- asks configNodeId
    (logEntryIndex, logEntryTerm) <-
      lastLogEntryIndexAndTerm . psLog <$> getPersistentState
    pure RequestVote
      { rvTerm = term
      , rvCandidateId = selfNodeId
      , rvLastLogIndex = logEntryIndex
      , rvLastLogTerm = logEntryTerm
      }

  voteForSelf = do
    selfNodeId <- asks configNodeId
    modifyPersistentState $ \pstate ->
      pstate { psVotedFor = Just selfNodeId }
