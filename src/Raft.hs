{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}

module Raft where

import Protolude

import Control.Monad.Writer.Strict

import Data.Type.Bool

import qualified Raft.Follower as Follower
import qualified Raft.Candidate as Candidate
import qualified Raft.Leader as Leader
import Raft.Monad
import Raft.Types

-- | Main entry point for handling events
handleEvent
  :: NodeConfig
  -> RaftNodeState v
  -> PersistentState v
  -> Event v
  -> (RaftNodeState v, PersistentState v, [Action v])
handleEvent nodeConfig (RaftNodeState nodeState) persistentState event =
  case handleEvent' nodeConfig nodeState persistentState event of
    (ResultState _ resultState, persistentState, actions) ->
      (RaftNodeState resultState, persistentState, actions)

handleEvent'
  :: forall s v. (RaftHandler s v)
  => NodeConfig
  -> NodeState s
  -> PersistentState v
  -> Event v
  -> (ResultState s v, PersistentState v, [Action v])
handleEvent' nodeConfig nodeState persistentState event =
    runTransitionM nodeConfig persistentState $
      case event of
        Message msg -> handleMessage nodeState msg
        Timeout tout -> handleTimeout nodeState tout
  where
    handleMessage :: MessageHandler s v
    handleMessage s (RPC sender rpc) =
      case rpc of
        AppendEntriesRPC appendEntries ->
          handleAppendEntries s sender appendEntries
        AppendEntriesResponseRPC appendEntriesResp ->
          handleAppendEntriesResponse s sender appendEntriesResp
        RequestVoteRPC requestVote ->
          handleRequestVote s sender requestVote
        RequestVoteResponseRPC requestVoteResp ->
          handleRequestVoteResponse s sender requestVoteResp
