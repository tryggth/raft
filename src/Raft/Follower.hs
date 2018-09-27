{-# LANGUAGE TypeFamilies #-}

module Raft.Follower where

import Protolude

import Raft
import Raft.Types

--------------------------------------------------------------------------------
-- Follower
--------------------------------------------------------------------------------

handleEvent
  :: FollowerState
  -> Event v
  -> TransitionM v NodeState
handleEvent fs event =
    case event of
      RPC rpc -> toNodeState <$> handleRPC fs rpc

handleRPC
  :: (InternalState res, ValidTransition init res, init ~ FollowerState, res ~ FollowerState)
  => init
  -> RPC v
  -> TransitionM v res
handleRPC fs rpc =
  case rpc of
    AppendEntriesRPC appendEntries ->
      handleAppendEntries fs appendEntries
    AppendEntriesResponseRPC appendEntriesResp ->
      handleAppendEntriesResponse fs appendEntriesResp
    RequestVoteRPC requestVote ->
      handleRequestVote fs requestVote
    RequestVoteResponseRPC requestVoteResp ->
      handleRequestVoteResponse fs requestVoteResp
  where
    handleAppendEntries
      :: FollowerState
      -> AppendEntries v
      -> TransitionM v res
    handleAppendEntries = undefined

    -- | Followers should not respond to 'AppendEntriesResponse' messages.
    handleAppendEntriesResponse
      :: FollowerState
      -> AppendEntriesResponse
      -> TransitionM v res
    handleAppendEntriesResponse = undefined

    handleRequestVote
      :: FollowerState
      -> RequestVote
      -> TransitionM v res
    handleRequestVote = undefined

    handleRequestVoteResponse
      :: FollowerState
      -> RequestVoteResponse
      -> TransitionM v res
    handleRequestVoteResponse = undefined

handleTimeout
  :: (InternalState res, ValidTransition FollowerState res, res ~ CandidateState)
  => FollowerState
  -> Timeout
  -> TransitionM v res
handleTimeout fs timeout =
  case timeout of
    ElectionTimeout -> undefined
