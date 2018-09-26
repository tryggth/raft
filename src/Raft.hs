{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Raft where

import Protolude

import Control.Monad.Writer.Strict

import Raft.Types

data Event
  = Message -- Message
  | HeartBeatTimeout
  | ElectionTimeout

data Action
  = SendMessage NodeId -- Message
  | Broadcast -- Message

newtype TransitionM a = TransitionM
  { unTransitionM :: ReaderT NodeConfig (Writer [Action]) a
  } deriving (Functor, Applicative, Monad)

runTransitionM :: NodeConfig -> TransitionM a -> (a, [Action])
runTransitionM config transition =
  runWriter (flip runReaderT config (unTransitionM transition))

-- | The main transition function
handleEvent :: NodeConfig -> NodeState -> Event -> (NodeState, [Action])
handleEvent config nodeState =
  runTransitionM config . handleEvent' nodeState

handleEvent' :: NodeState -> Event -> TransitionM NodeState
handleEvent' nodeState event =
  case nodeState of
    NodeFollowerState fs -> NodeFollowerState <$> handleEventFollower fs event
    NodeCandidateState cs -> NodeCandidateState <$> handleEventCandidate cs event
    NodeLeaderState ls -> NodeLeaderState <$> handleEventLeader ls event

--------------------------------------------------------------------------------
-- Follower
--------------------------------------------------------------------------------

handleEventFollower
  :: (ValidTransition src dst, src ~ FollowerState)
  => src
  -> Event
  -> TransitionM dst
handleEventFollower = undefined

--------------------------------------------------------------------------------
-- Candidate
--------------------------------------------------------------------------------

handleEventCandidate
  :: (ValidTransition src dst, src ~ CandidateState)
  => src
  -> Event
  -> TransitionM dst
handleEventCandidate = undefined

--------------------------------------------------------------------------------
-- Leader
--------------------------------------------------------------------------------

handleEventLeader
  :: (ValidTransition src dst, src ~ LeaderState)
  => src
  -> Event
  -> TransitionM dst
handleEventLeader = undefined

handleEventLeader'
  :: (ValidTransition LeaderState dst)
  => LeaderState
  -> Event
  -> TransitionM dst
handleEventLeader' = undefined
