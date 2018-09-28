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
  -> Event v
  -> (RaftNodeState v, [Action v])
handleEvent nodeConfig (RaftNodeState nodeState) event =
  case handleEvent' nodeConfig nodeState event of
    (ResultState _ resultState, actions) ->
      (RaftNodeState resultState, actions)

handleEvent'
  :: forall s v. (RaftHandler s v)
  => NodeConfig
  -> NodeState s
  -> Event v
  -> (ResultState s v, [Action v])
handleEvent' nodeConfig nodeState event =
    runTransitionM nodeConfig $
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
