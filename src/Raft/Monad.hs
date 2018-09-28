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

class RaftHandler s v where
  handleAppendEntries :: RPCHandler s (AppendEntries v) v
  handleAppendEntriesResponse :: RPCHandler s AppendEntriesResponse v
  handleRequestVote :: RPCHandler s RequestVote v
  handleRequestVoteResponse :: RPCHandler s RequestVoteResponse v
  handleTimeout :: TimeoutHandler s v

type MessageHandler s v = NodeState s -> Message v -> TransitionM v (ResultState s v)
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

  -- TODO Replace with specific transition names
  Noop :: Transition init init

-- | The volatile state of a Raft Node
data NodeState (a :: Mode) where
  NodeFollowerState :: FollowerState -> NodeState 'Follower
  NodeCandidateState :: CandidateState -> NodeState 'Candidate
  NodeLeaderState :: LeaderState -> NodeState 'Leader

-- | Existential type hiding the result type of a transition
data ResultState init v where
  ResultState
    :: forall v init res. (RaftHandler res v)
    => Transition init res -> NodeState res -> ResultState init v

-- | Existential type hiding the internal node state
data RaftNodeState v where
  RaftNodeState :: (RaftHandler s v) => NodeState s -> RaftNodeState v

--------------------------------------------------------------------------------
-- DSL (TODO move to src/Raft/Action.hs)
--------------------------------------------------------------------------------

-- | Helper for message actions
toRPCMessage :: RPCType r v => r -> TransitionM v (Message v)
toRPCMessage msg = flip RPC (toRPC msg) <$> asks configNodeId

broadcast :: RPCType r v => r -> TransitionM v ()
broadcast msg = do
  action <-
    Broadcast
      <$> asks configNodeIds
      <*> toRPCMessage msg
  tell [action]

send :: RPCType r v => NodeId -> r -> TransitionM v ()
send nodeId msg = do
  action <- SendMessage nodeId <$> toRPCMessage msg
  tell [action]

incrementTerm :: TransitionM v ()
incrementTerm = do
  modify $ \pstate ->
    pstate { psCurrentTerm = incrTerm (psCurrentTerm pstate) }

-- | Resets the election timeout.
resetElectionTimeout :: TransitionM a ()
resetElectionTimeout = do
    t <- asks configElectionTimeout
    tell [ResetElectionTimeout t]
