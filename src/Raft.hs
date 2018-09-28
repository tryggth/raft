{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
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
    case handleEvent' raftHandler nodeConfig nodeState persistentState event of
      (ResultState _ resultState, persistentState, actions) ->
        (RaftNodeState resultState, persistentState, actions)
  where
    raftHandler =
      case nodeState of
        NodeFollowerState _ -> followerRaftHandler
        NodeCandidateState _ -> candidateRaftHandler
        NodeLeaderState _ -> leaderRaftHandler

data RaftHandler s v = RaftHandler
  { handleAppendEntries :: RPCHandler s (AppendEntries v) v
  , handleAppendEntriesResponse :: RPCHandler s AppendEntriesResponse v
  , handleRequestVote :: RPCHandler s RequestVote v
  , handleRequestVoteResponse :: RPCHandler s RequestVoteResponse v
  , handleTimeout :: TimeoutHandler s v
  }

followerRaftHandler :: RaftHandler 'Follower v
followerRaftHandler = RaftHandler
  { handleAppendEntries = Follower.handleAppendEntries
  , handleAppendEntriesResponse = Follower.handleAppendEntriesResponse
  , handleRequestVote = Follower.handleRequestVote
  , handleRequestVoteResponse = Follower.handleRequestVoteResponse
  , handleTimeout = Follower.handleTimeout
  }

candidateRaftHandler :: RaftHandler 'Candidate v
candidateRaftHandler = RaftHandler
  { handleAppendEntries = Candidate.handleAppendEntries
  , handleAppendEntriesResponse = Candidate.handleAppendEntriesResponse
  , handleRequestVote = Candidate.handleRequestVote
  , handleRequestVoteResponse = Candidate.handleRequestVoteResponse
  , handleTimeout = Candidate.handleTimeout
  }

leaderRaftHandler :: RaftHandler 'Leader v
leaderRaftHandler = RaftHandler
  { handleAppendEntries = Leader.handleAppendEntries
  , handleAppendEntriesResponse = Leader.handleAppendEntriesResponse
  , handleRequestVote = Leader.handleRequestVote
  , handleRequestVoteResponse = Leader.handleRequestVoteResponse
  , handleTimeout = Leader.handleTimeout
  }

handleEvent'
  :: RaftHandler s v
  -> NodeConfig
  -> NodeState s
  -> PersistentState v
  -> Event v
  -> (ResultState s v, PersistentState v, [Action v])
handleEvent' RaftHandler{..} nodeConfig nodeState persistentState event =
    runTransitionM nodeConfig persistentState $
      case event of
        Message msg -> handleMessage nodeState msg
        Timeout tout -> handleTimeout nodeState tout
  where
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
