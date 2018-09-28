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
handleAppendEntries
  (NodeCandidateState candidateState@CandidateState{..})
  sender
  (appendEntries@AppendEntries {..}) = do
  currentTerm <- gets psCurrentTerm
  if currentTerm <= aeTerm
  then stepDown sender currentTerm csCommitIndex
  else notImplemented

stepDown :: NodeId -> Term -> Index -> TransitionM a (ResultState 'Candidate v)
stepDown sender term commitIndex = do
  resetElectionTimeout
  send sender (RequestVoteResponse term True)
  pure $ ResultState DiscoverLeader (NodeFollowerState (FollowerState commitIndex (Index 0))) -- TODO: fsLastApplied


-- | Candidates should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Candidate AppendEntriesResponse v
handleAppendEntriesResponse = undefined

handleRequestVote :: RPCHandler 'Candidate RequestVote v
handleRequestVote = undefined

-- | Candidates should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Candidate RequestVoteResponse v
handleRequestVoteResponse = undefined

handleTimeout :: TimeoutHandler 'Candidate v
handleTimeout fs timeout = undefined

