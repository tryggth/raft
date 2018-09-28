{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}

module Raft.Candidate where

import Protolude
import Control.Monad.RWS
import qualified Data.Set as Set

import Raft.Monad
import Raft.Types
import Raft.Follower

--------------------------------------------------------------------------------
-- Candidate
--------------------------------------------------------------------------------

instance RaftHandler Candidate v where
  handleAppendEntries = Raft.Candidate.handleAppendEntries
  handleAppendEntriesResponse = Raft.Candidate.handleAppendEntriesResponse
  handleRequestVote = Raft.Candidate.handleRequestVote
  handleRequestVoteResponse = Raft.Candidate.handleRequestVoteResponse
  handleTimeout = Raft.Candidate.handleTimeout

handleAppendEntries :: RPCHandler 'Candidate (AppendEntries v) v
handleAppendEntries (currentState@(NodeCandidateState CandidateState{..})) sender AppendEntries {..} = do
  currentTerm <- gets psCurrentTerm
  if currentTerm <= aeTerm
  then stepDown sender aeTerm csCommitIndex csLastApplied
  else pure $ ResultState Noop currentState

stepDown :: NodeId -> Term -> Index -> Index -> TransitionM a (ResultState 'Candidate v)
stepDown sender term commitIndex lastApplied = do
  resetElectionTimeout
  send sender (RequestVoteResponse term True)
  pure $ ResultState DiscoverLeader (NodeFollowerState (FollowerState commitIndex lastApplied))


-- | Candidates should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Candidate AppendEntriesResponse v
handleAppendEntriesResponse currentState sender appendEntriesResp =
  pure $ ResultState Noop currentState


handleRequestVote :: RPCHandler 'Candidate RequestVote v
handleRequestVote = undefined

-- | Candidates should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Candidate RequestVoteResponse v
handleRequestVoteResponse = undefined

handleTimeout :: TimeoutHandler 'Candidate v
handleTimeout fs timeout = undefined

