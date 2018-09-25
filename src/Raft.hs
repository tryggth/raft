{-# LANGUAGE TypeFamilies #-}

module Raft where

import Protolude

import Control.Monad.Writer.Strict

import Raft.Types

data Event
  = Message
  | HeartBeatTimeout
  | ElectionTimeout

data Action -- = ...

newtype TransitionM a =
  TransitionM { unTransitionM :: ReaderT NodeConfig (Writer [Action]) a }

runTransitionM :: IsValidTransition src dst => NodeConfig -> src -> TransitionM dst -> (dst, [Action])
runTransitionM config currState transition =
  runWriter (flip runReaderT config (unTransitionM transition))

-- | The main transition function
handleEvent :: IsValidTransition src dst => src -> Event -> TransitionM (dst, [Action])
handleEvent = undefined

--------------------------------------------------------------------------------
-- Follower
--------------------------------------------------------------------------------

handleEventFollower
  :: (IsValidTransition src dst, src ~ FollowerState)
  => src
  -> Event
  -> TransitionM (dst, [Action])
handleEventFollower = undefined

--------------------------------------------------------------------------------
-- Candidate
--------------------------------------------------------------------------------

handleEventCandidate
  :: (IsValidTransition src dst, src ~ CandidateState)
  => src
  -> Event
  -> TransitionM (dst, [Action])
handleEventCandidate = undefined

--------------------------------------------------------------------------------
-- Leader
--------------------------------------------------------------------------------

handleEventLeader
  :: (IsValidTransition src dst, src ~ LeaderState)
  => src
  -> Event
  -> TransitionM (dst, [Action])
handleEventLeader = undefined
