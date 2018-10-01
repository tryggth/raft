{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}

module Raft.Monad where

import Protolude

import Control.Monad.RWS
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.Sequence as Seq

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

--------------------------------------------------------------------------------
-- Transitions
--------------------------------------------------------------------------------

data Mode
  = Follower
  | Candidate
  | Leader

-- | All valid state transitions of a Raft node
data Transition (init :: Mode) (res :: Mode) where
  StartElection :: Transition 'Follower 'Candidate
  RestartElection :: Transition 'Candidate 'Candidate
  DiscoverLeader :: Transition 'Candidate 'Follower
  BecomeLeader :: Transition 'Candidate 'Leader
  DiscoverNewLeader :: Transition 'Leader 'Follower
  Heartbeat :: Transition 'Leader 'Leader

  -- TODO Replace with specific transition names
  Noop :: Transition init init

-- | The volatile state of a Raft Node
data NodeState (a :: Mode) where
  NodeFollowerState :: FollowerState -> NodeState 'Follower
  NodeCandidateState :: CandidateState -> NodeState 'Candidate
  NodeLeaderState :: LeaderState -> NodeState 'Leader

-- | Existential type hiding the result type of a transition
data ResultState init v where
  ResultState :: Transition init res -> NodeState res -> ResultState init v

followerResultState
  :: Transition init 'Follower
  -> FollowerState
  -> ResultState init v
followerResultState transition fstate =
  ResultState transition (NodeFollowerState fstate)

candidateResultState
  :: Transition init 'Candidate
  -> CandidateState
  -> ResultState init v
candidateResultState transition cstate =
  ResultState transition (NodeCandidateState cstate)

leaderResultState
  :: Transition init 'Leader
  -> LeaderState
  -> ResultState init v
leaderResultState transition lstate =
  ResultState transition (NodeLeaderState lstate)

-- | Existential type hiding the internal node state
data RaftNodeState v where
  RaftNodeState :: NodeState s -> RaftNodeState v

--------------------------------------------------------------------------------
-- DSL (TODO move to src/Raft/Action.hs)
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

incrementTerm :: TransitionM v Term
incrementTerm = do
  psNextTerm <- gets (incrTerm . psCurrentTerm)
  modify $ \pstate ->
    pstate { psCurrentTerm = psNextTerm }
  pure psNextTerm

-- | Resets the election timeout.
resetElectionTimeout :: TransitionM a ()
resetElectionTimeout = do
    t <- asks configElectionTimeout
    tell [ResetElectionTimeout t]

resetHeartbeatTimeout :: TransitionM a ()
resetHeartbeatTimeout = do
    t <- asks configElectionHeartbeat
    tell [ResetElectionTimeout t]

hasMajority :: Set a -> Set b -> Bool
hasMajority totalNodeIds votes =
  Set.size votes >= Set.size totalNodeIds `div` 2 + 1

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

leaderStepUp :: forall v. Index -> Index -> TransitionM v LeaderState
leaderStepUp commitIndex lastApplied = do
  resetHeartbeatTimeout
  selfNodeId <- asks configNodeId
  currentTerm <- gets psCurrentTerm
  (logEntryIndex, logEntryTerm) <-
    lastLogEntryIndexAndTerm <$> gets psLog
  broadcast AppendEntries { aeTerm = currentTerm
                          , aeLeaderId = selfNodeId
                          , aePrevLogIndex = logEntryIndex
                          , aePrevLogTerm = logEntryTerm
                          , aeEntries = Seq.Empty :: Seq.Seq (Entry v)
                          , aeLeaderCommit = index0
                          }

  cNodeIds <- asks configNodeIds
  pure LeaderState
          { lsCommitIndex = commitIndex
          , lsLastApplied = lastApplied
          , lsNextIndex = Map.fromList $
              flip (,) (incrIndex logEntryIndex) <$> Set.toList cNodeIds
          , lsMatchIndex = Map.fromList $
              flip (,) index0 <$> Set.toList cNodeIds
          -- ^ We use index0 as the new leader doesn't know yet what
          -- the highest log has been seen by other nodes
          }
