{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}

module Raft where

import Protolude

import Control.Monad.Writer.Strict

import Data.Type.Bool

import qualified Raft.Follower as Follower
import qualified Raft.Candidate as Candidate
import qualified Raft.Leader as Leader
import Raft.Monad
import Raft.Types

class HandleRPC s v where
  handleAppendEntries :: RPCHandler s (AppendEntries v) v
  handleAppendEntriesResponse :: RPCHandler s AppendEntriesResponse v
  handleRequestVote :: RPCHandler s RequestVote v
  handleRequestVoteResponse :: RPCHandler s RequestVoteResponse v

class HandleTimeout s v where
  handleTimeout :: TimeoutHandler s v

instance HandleRPC Follower v where
  handleAppendEntries = Follower.handleAppendEntries
  handleAppendEntriesResponse = Follower.handleAppendEntriesResponse
  handleRequestVote = Follower.handleRequestVote
  handleRequestVoteResponse = Follower.handleRequestVoteResponse

instance HandleRPC Candidate v where
  handleAppendEntries = Candidate.handleAppendEntries
  handleAppendEntriesResponse = Candidate.handleAppendEntriesResponse
  handleRequestVote = Candidate.handleRequestVote
  handleRequestVoteResponse = Candidate.handleRequestVoteResponse

instance HandleRPC Leader v where
  handleAppendEntries = Leader.handleAppendEntries
  handleAppendEntriesResponse = Leader.handleAppendEntriesResponse
  handleRequestVote = Leader.handleRequestVote
  handleRequestVoteResponse = Leader.handleRequestVoteResponse

-- | Main entry point for handling events
handleEvent
  :: forall s v. (HandleRPC s v, HandleTimeout s v)
  => NodeConfig
  -> NodeState s
  -> Event v
  -> (ResultState s, [Action v])
handleEvent nodeConfig nodeState event =
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
