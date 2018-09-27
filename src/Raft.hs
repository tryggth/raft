{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators #-}

module Raft where

import Protolude

import Control.Monad.Writer.Strict

import Data.Type.Bool

-- import Raft.Follower
-- import Raft.Candidate
-- import Raft.Leader
import Raft.Types


newtype TransitionM v a = TransitionM
  { unTransitionM :: ReaderT NodeConfig (Writer [Action v]) a
  } deriving (Functor, Applicative, Monad)


runTransitionM :: NodeConfig -> TransitionM v a -> (a, [Action v])
runTransitionM config transition =
  runWriter (flip runReaderT config (unTransitionM transition))

-- | The main transition function
handleEvent :: NodeConfig -> NodeState -> Event v -> (NodeState, [Action v])
handleEvent config (NodeState nodeState) event =
  runTransitionM config $
    case nodeState of
      NodeFollowerState fs -> undefined --  Follower.handleEventFollower fs event
      NodeCandidateState cs -> undefined -- handleEventCandidate cs event
      NodeLeaderState ls -> undefined -- handleEventLeader ls event

f
  :: (InternalState dst, ValidTransition src dst, src ~ FollowerState, dst ~ FollowerState)
  => TransitionM v FollowerState
f = pure $ FollowerState 0 0
