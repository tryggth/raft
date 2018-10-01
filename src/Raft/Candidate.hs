{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiWayIf #-}

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

handleAppendEntries :: RPCHandler 'Candidate (AppendEntries v) v
handleAppendEntries (NodeCandidateState candidateState@CandidateState{..}) sender AppendEntries {..} = do
  currentTerm <- gets psCurrentTerm
  if currentTerm <= aeTerm
    then stepDown sender aeTerm csCommitIndex csLastApplied
    else pure $ candidateResultState Noop candidateState

stepDown :: NodeId -> Term -> Index -> Index -> TransitionM a (ResultState 'Candidate v)
stepDown sender term commitIndex lastApplied = do
  resetElectionTimeout
  send sender (RequestVoteResponse term True)
  pure $ ResultState DiscoverLeader (NodeFollowerState (FollowerState commitIndex lastApplied))

-- | Candidates should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Candidate AppendEntriesResponse v
handleAppendEntriesResponse (NodeCandidateState candidateState) _sender _appendEntriesResp =
  pure $ candidateResultState Noop candidateState


handleRequestVote :: RPCHandler 'Candidate RequestVote v
handleRequestVote ((NodeCandidateState candidateState@CandidateState{..})) sender requestVote@RequestVote{..} = do
  currentTerm <- gets psCurrentTerm
  if rvTerm > currentTerm
    then stepDown sender rvTerm csCommitIndex csLastApplied
    else do
      send sender (RequestVoteResponse currentTerm False)
      pure $ candidateResultState Noop candidateState

-- | Candidates should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Candidate RequestVoteResponse v
handleRequestVoteResponse (NodeCandidateState candidateState@CandidateState{..}) sender requestVoteResp@RequestVoteResponse{..} = do
  currentTerm <- gets psCurrentTerm
  cNodeIds <- asks configNodeIds
  if  | rvrTerm < currentTerm -> pure $ candidateResultState Noop candidateState
      | rvrTerm > currentTerm -> stepDown sender rvrTerm csCommitIndex csLastApplied
      | not rvrVoteGranted -> pure $ candidateResultState Noop candidateState
      | Set.member sender csVotes -> pure $ candidateResultState Noop candidateState
      | otherwise -> do
          let newCsVotes = Set.insert sender csVotes

          if not $ hasMajority cNodeIds newCsVotes
            then pure $ candidateResultState Noop candidateState
            else notImplemented -- TODO: Stepup


handleTimeout :: TimeoutHandler 'Candidate v
handleTimeout (NodeCandidateState candidateState@CandidateState{..}) timeout =
  case timeout of
    HearbeatTimeout -> pure $ candidateResultState Noop candidateState
    ElectionTimeout ->
      candidateResultState RestartElection <$>
        updateElectionTimeoutCandidateState csCommitIndex csLastApplied



