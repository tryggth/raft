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
import Data.Monoid

import qualified Raft.Follower as Follower
import qualified Raft.Candidate as Candidate
import qualified Raft.Leader as Leader

import Raft.Action
import Raft.Config
import Raft.Client
import Raft.Event
import Raft.Monad
import Raft.NodeState
import Raft.Persistent
import Raft.RPC
import Raft.Types

-- | Main entry point for handling events
handleEvent
  :: forall s sm v.
     (StateMachine sm v, Show v)
  => NodeConfig
  -> RaftNodeState s
  -> TransitionState sm v
  -> Event v
  -> (RaftNodeState s, TransitionState sm v, TransitionWriter sm v)
handleEvent nodeConfig raftNodeState@(RaftNodeState initNodeState) transitionState event =
    -- Rules for all servers:
    case handleNewerRPCTerm of
      (RaftNodeState resNodeState, transitionState', transitionW) ->
        case handleEvent' (raftHandler resNodeState) nodeConfig resNodeState transitionState' event of
          (ResultState _ resultState, transitionState'', transitionW') ->
            (RaftNodeState resultState, transitionState'', transitionW <> transitionW')
  where
    raftHandler :: forall ns sm. NodeState ns -> RaftHandler ns sm v
    raftHandler nodeState =
      case nodeState of
        NodeFollowerState _ -> followerRaftHandler
        NodeCandidateState _ -> candidateRaftHandler
        NodeLeaderState _ -> leaderRaftHandler

    handleNewerRPCTerm :: (RaftNodeState s, TransitionState sm v, TransitionWriter sm v)
    handleNewerRPCTerm =
      case event of
        MessageEvent (RPCMessageEvent (RPCMessage _ rpc)) ->
          runTransitionM nodeConfig transitionState $ do
            -- If RPC request or response contains term T > currentTerm: set
            -- currentTerm = T, convert to follower
            currentTerm <- psCurrentTerm <$> getPersistentState
            if rpcTerm rpc > currentTerm
              then
                case convertToFollower initNodeState of
                  ResultState _ nodeState -> do
                    modifyPersistentState $ \pstate ->
                      pstate { psCurrentTerm = rpcTerm rpc
                             , psVotedFor = Nothing
                             }
                    resetElectionTimeout
                    pure (RaftNodeState nodeState)
              else pure raftNodeState
        _ -> (raftNodeState, transitionState, mempty)

    convertToFollower :: forall s. NodeState s -> ResultState s v
    convertToFollower nodeState =
      case nodeState of
        NodeFollowerState _ ->
          ResultState HigherTermFoundFollower nodeState
        NodeCandidateState cs ->
          ResultState HigherTermFoundCandidate $
            NodeFollowerState FollowerState
              { fsCurrentLeader = NoLeader
              , fsCommitIndex = csCommitIndex cs
              , fsLastApplied = csLastApplied cs
              }
        NodeLeaderState ls ->
          ResultState HigherTermFoundLeader $
            NodeFollowerState FollowerState
              { fsCurrentLeader = NoLeader
              , fsCommitIndex = lsCommitIndex ls
              , fsLastApplied = lsLastApplied ls
              }


data RaftHandler ns sm v = RaftHandler
  { handleAppendEntries :: RPCHandler ns sm (AppendEntries v) v
  , handleAppendEntriesResponse :: RPCHandler ns sm AppendEntriesResponse v
  , handleRequestVote :: RPCHandler ns sm RequestVote v
  , handleRequestVoteResponse :: RPCHandler ns sm RequestVoteResponse v
  , handleTimeout :: TimeoutHandler ns sm v
  , handleClientRequest :: ClientReqHandler ns sm v
  }

followerRaftHandler :: Show v => RaftHandler 'Follower sm v
followerRaftHandler = RaftHandler
  { handleAppendEntries = Follower.handleAppendEntries
  , handleAppendEntriesResponse = Follower.handleAppendEntriesResponse
  , handleRequestVote = Follower.handleRequestVote
  , handleRequestVoteResponse = Follower.handleRequestVoteResponse
  , handleTimeout = Follower.handleTimeout
  , handleClientRequest = Follower.handleClientRequest
  }

candidateRaftHandler :: Show v => RaftHandler 'Candidate sm v
candidateRaftHandler = RaftHandler
  { handleAppendEntries = Candidate.handleAppendEntries
  , handleAppendEntriesResponse = Candidate.handleAppendEntriesResponse
  , handleRequestVote = Candidate.handleRequestVote
  , handleRequestVoteResponse = Candidate.handleRequestVoteResponse
  , handleTimeout = Candidate.handleTimeout
  , handleClientRequest = Candidate.handleClientRequest
  }

leaderRaftHandler :: Show v => RaftHandler 'Leader sm v
leaderRaftHandler = RaftHandler
  { handleAppendEntries = Leader.handleAppendEntries
  , handleAppendEntriesResponse = Leader.handleAppendEntriesResponse
  , handleRequestVote = Leader.handleRequestVote
  , handleRequestVoteResponse = Leader.handleRequestVoteResponse
  , handleTimeout = Leader.handleTimeout
  , handleClientRequest = Leader.handleClientRequest
  }

handleEvent'
  :: forall ns sm v.
     (StateMachine sm v, Show v)
  => RaftHandler ns sm v
  -> NodeConfig
  -> NodeState ns
  -> TransitionState sm v
  -> Event v
  -> (ResultState ns v, TransitionState sm v, TransitionWriter sm v)
handleEvent' raftHandler@RaftHandler{..} nodeConfig initNodeState transitionState event =
    runTransitionM nodeConfig transitionState $
      case event of
        MessageEvent mev ->
          case mev of
            RPCMessageEvent rpcMsg -> handleRPCMessage rpcMsg
            ClientRequestEvent cr -> do
              tellLogWithState initNodeState (show cr)
              handleClientRequest initNodeState cr
        TimeoutEvent tout -> do
          tellLogWithState initNodeState (show tout)
          handleTimeout initNodeState tout
  where
    handleRPCMessage :: RPCMessage v -> TransitionM sm v (ResultState ns v)
    handleRPCMessage (RPCMessage sender rpc) = do
      resState@(ResultState transition newNodeState) <- case rpc of
        AppendEntriesRPC appendEntries -> do
          tellLogWithState initNodeState (show appendEntries)
          handleAppendEntries initNodeState sender appendEntries
        AppendEntriesResponseRPC appendEntriesResp -> do
          tellLogWithState initNodeState (show appendEntriesResp)
          handleAppendEntriesResponse initNodeState sender appendEntriesResp
        RequestVoteRPC requestVote -> do
          tellLogWithState initNodeState (show requestVote)
          handleRequestVote initNodeState sender requestVote
        RequestVoteResponseRPC requestVoteResp -> do
          tellLogWithState initNodeState (show requestVoteResp)
          handleRequestVoteResponse initNodeState sender requestVoteResp

      -- If commitIndex > lastApplied: increment lastApplied, apply
      -- log[lastApplied] to state machine (Section 5.3)
      newestNodeState <-
        if commitIndex newNodeState > lastApplied newNodeState
          then incrLastApplied newNodeState
          else pure newNodeState

      pure $ ResultState transition newestNodeState

    incrLastApplied :: NodeState ns' -> TransitionM sm v (NodeState ns')
    incrLastApplied nodeState =
      case nodeState of
        NodeFollowerState fs -> do
          applyLogEntry (lastApplied nodeState)
          let lastApplied' = incrIndex (fsLastApplied fs)
          pure $ NodeFollowerState $
            fs { fsLastApplied = lastApplied' }
        NodeCandidateState cs -> do
          applyLogEntry (lastApplied nodeState)
          let lastApplied' = incrIndex (csLastApplied cs)
          pure $ NodeCandidateState $
            cs { csLastApplied = lastApplied' }
        NodeLeaderState ls -> do
          applyLogEntry (lastApplied nodeState)
          let lastApplied' = incrIndex (lsLastApplied ls)
          pure $ NodeLeaderState $
            ls { lsLastApplied = lastApplied' }

    getLastAppliedAndCommitIndex :: NodeState s' -> (Index, Index)
    getLastAppliedAndCommitIndex nodeState =
      case nodeState of
        NodeFollowerState fs -> (fsLastApplied fs, fsCommitIndex fs)
        NodeCandidateState cs -> (csLastApplied cs, csCommitIndex cs)
        NodeLeaderState ls -> (lsLastApplied ls, lsCommitIndex ls)

    lastApplied :: NodeState s' -> Index
    lastApplied = fst . getLastAppliedAndCommitIndex

    commitIndex :: NodeState s' -> Index
    commitIndex = snd . getLastAppliedAndCommitIndex
