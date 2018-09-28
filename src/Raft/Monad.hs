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

import Control.Monad.Writer

import Raft.Types

--------------------------------------------------------------------------------
-- Raft Monad
--------------------------------------------------------------------------------

newtype TransitionM v a = TransitionM
  { unTransitionM :: ReaderT NodeConfig (Writer [Action v]) a
  } deriving (Functor, Applicative, Monad)

runTransitionM :: NodeConfig -> TransitionM v a -> (a, [Action v])
runTransitionM config transition =
  runWriter (flip runReaderT config (unTransitionM transition))

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

-- | The state of a Raft Node
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
