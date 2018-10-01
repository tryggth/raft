{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MonoLocalBinds #-}

module Raft.Follower (
    handleAppendEntries
  , handleAppendEntriesResponse
  , handleRequestVote
  , handleRequestVoteResponse
  , handleTimeout
) where

import Protolude

import Data.Set (singleton)

import Raft.Monad
import Raft.Types

--------------------------------------------------------------------------------
-- Follower
--------------------------------------------------------------------------------

handleAppendEntries :: RPCHandler 'Follower (AppendEntries v) v
handleAppendEntries = undefined

-- | Followers should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Follower AppendEntriesResponse v
handleAppendEntriesResponse (NodeFollowerState fs) _ _ =
  pure (followerResultState Noop fs)

handleRequestVote :: RPCHandler 'Follower RequestVote v
handleRequestVote = undefined

-- | Followers should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Follower RequestVoteResponse v
handleRequestVoteResponse (NodeFollowerState fs) _ _  =
  pure (followerResultState Noop fs)

-- | Follower converts to Candidate if handling ElectionTimeout
handleTimeout :: TimeoutHandler 'Follower v
handleTimeout (NodeFollowerState fs) timeout =
  case timeout of
    ElectionTimeout -> do
      -- State modifications
      incrementTerm
      voteForSelf
      -- Actions to perform
      resetElectionTimer
      broadcast =<< requestVoteMessage
      selfNodeId <- asks configNodeId
      -- Return new candidate state
      pure $ candidateResultState StartElection $
        CandidateState
          { csCommitIndex = fsCommitIndex fs
          , csLastApplied = fsLastApplied fs
          , csVotes = singleton selfNodeId
          }
  where
    requestVoteMessage = do
      term <- gets psCurrentTerm
      candidateId <- asks configNodeId
      mLastLogEntry <- lastLogEntry <$> gets psLog
      let (logEntryIndex, logEntryTerm) =
            case mLastLogEntry of
              Nothing -> (index0, term0)
              Just le -> second entryTerm le
      pure RequestVote
        { rvTerm = term
        , rvCandidateId = candidateId
        , rvLastLogIndex = logEntryIndex
        , rvLastLogTerm = logEntryTerm
        }

    voteForSelf = do
      selfNodeId <- asks configNodeId
      modify $ \pstate ->
        pstate { psVotedFor = Just selfNodeId }
