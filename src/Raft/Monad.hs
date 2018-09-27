{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Raft.Monad where

import Protolude

import Control.Monad.Writer

import Raft.Types

newtype TransitionM v a = TransitionM
  { unTransitionM :: ReaderT NodeConfig (Writer [Action v]) a
  } deriving (Functor, Applicative, Monad)

runTransitionM :: NodeConfig -> TransitionM v a -> (a, [Action v])
runTransitionM config transition =
  runWriter (flip runReaderT config (unTransitionM transition))

type MessageHandler s v = NodeState s -> Message v -> TransitionM v (ResultState s)
type RPCHandler s r v = RPCType r v => NodeState s -> NodeId -> r -> TransitionM v (ResultState s)
type TimeoutHandler s v = NodeState s -> Timeout -> TransitionM v (ResultState s)
