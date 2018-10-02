{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}

module Raft.Handle where

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
  , handleClientRequest :: ClientReqHandler s v
  }

followerRaftHandler :: RaftHandler 'Follower v
followerRaftHandler = RaftHandler
  { handleAppendEntries = Follower.handleAppendEntries
  , handleAppendEntriesResponse = Follower.handleAppendEntriesResponse
  , handleRequestVote = Follower.handleRequestVote
  , handleRequestVoteResponse = Follower.handleRequestVoteResponse
  , handleTimeout = Follower.handleTimeout
  , handleClientRequest = Follower.handleClientRequest
  }

candidateRaftHandler :: RaftHandler 'Candidate v
candidateRaftHandler = RaftHandler
  { handleAppendEntries = Candidate.handleAppendEntries
  , handleAppendEntriesResponse = Candidate.handleAppendEntriesResponse
  , handleRequestVote = Candidate.handleRequestVote
  , handleRequestVoteResponse = Candidate.handleRequestVoteResponse
  , handleTimeout = Candidate.handleTimeout
  , handleClientRequest = Candidate.handleClientRequest
  }

leaderRaftHandler :: RaftHandler 'Leader v
leaderRaftHandler = RaftHandler
  { handleAppendEntries = Leader.handleAppendEntries
  , handleAppendEntriesResponse = Leader.handleAppendEntriesResponse
  , handleRequestVote = Leader.handleRequestVote
  , handleRequestVoteResponse = Leader.handleRequestVoteResponse
  , handleTimeout = Leader.handleTimeout
  , handleClientRequest = Leader.handleClientRequest
  }

handleEvent'
  :: forall s v. RaftHandler s v
  -> NodeConfig
  -> NodeState s
  -> PersistentState v
  -> Event v
  -> (ResultState s v, PersistentState v, [Action v])
handleEvent' RaftHandler{..} nodeConfig initNodeState persistentState event =
    runTransitionM nodeConfig persistentState $
      case event of
        Message msg -> handleMessage msg
        ClientRequest crq -> handleClientRequest initNodeState crq
        Timeout tout -> handleTimeout initNodeState tout
  where
    (lastApplied :: Index, commitIndex :: Index) =
      case initNodeState of
        NodeFollowerState fs -> (fsLastApplied fs, fsCommitIndex fs)
        NodeCandidateState cs -> (csLastApplied cs, csCommitIndex cs)
        NodeLeaderState ls -> (lsLastApplied ls, lsCommitIndex ls)

    handleMessage :: Message v -> TransitionM v (ResultState s v)
    handleMessage (RPC sender rpc) = do
      -- If commitIndex > lastApplied: increment lastApplied, apply
      -- log[lastApplied] to state machine (Section 5.3)
      newNodeState <-
        if (commitIndex > lastApplied)
          then incrLastApplied
          else pure initNodeState

      -- If RPC request or response contains term T > currentTerm: set
      -- currentTerm = T, convert to follower
      currentTerm <- gets psCurrentTerm
      if rpcTerm rpc > currentTerm
        then do
          updateTerm (rpcTerm rpc)
          convertToFollower newNodeState
        else
          -- Otherwise handle message normally
          case rpc of
            AppendEntriesRPC appendEntries ->
              handleAppendEntries newNodeState sender appendEntries
            AppendEntriesResponseRPC appendEntriesResp ->
              handleAppendEntriesResponse newNodeState sender appendEntriesResp
            RequestVoteRPC requestVote ->
              handleRequestVote newNodeState sender requestVote
            RequestVoteResponseRPC requestVoteResp ->
              handleRequestVoteResponse newNodeState sender requestVoteResp

    updateTerm :: Term -> TransitionM v ()
    updateTerm t =
      modify $ \pstate ->
        pstate { psCurrentTerm = t }

    convertToFollower :: NodeState s -> TransitionM v (ResultState s v)
    convertToFollower nodeState = do
      resetElectionTimeout
      case nodeState of
        NodeFollowerState _ ->
          pure $ ResultState HigherTermFoundFollower nodeState
        NodeCandidateState cs ->
          pure $ ResultState HigherTermFoundCandidate $
            NodeFollowerState FollowerState
              { fsCurrentLeader = NoLeader
              , fsCommitIndex = csCommitIndex cs
              , fsLastApplied = csLastApplied cs
              }
        NodeLeaderState ls ->
          pure $ ResultState HigherTermFoundLeader $
            NodeFollowerState FollowerState
              { fsCurrentLeader = NoLeader
              , fsCommitIndex = lsCommitIndex ls
              , fsLastApplied = lsLastApplied ls
              }

    incrLastApplied :: TransitionM v (NodeState s)
    incrLastApplied =
      case initNodeState of
        NodeFollowerState fs -> do
          let lastApplied = incrIndex (fsLastApplied fs)
          applyLogEntry lastApplied
          pure $ NodeFollowerState $
            fs { fsLastApplied = lastApplied }
        NodeCandidateState cs -> do
          let lastApplied = incrIndex (csLastApplied cs)
          applyLogEntry lastApplied
          pure $ NodeCandidateState $
            cs { csLastApplied = lastApplied }
        NodeLeaderState ls -> do
          let lastApplied = incrIndex (lsLastApplied ls)
          applyLogEntry lastApplied
          pure $ NodeLeaderState $
            ls { lsLastApplied = lastApplied }
