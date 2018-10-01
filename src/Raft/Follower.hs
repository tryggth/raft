{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}
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

-- | Handle AppendEntries RPC message from Leader
-- Sections 5.2 and 5.3 of Raft Paper
--
-- Note: see 'PersistentState' datatype for discussion about not keeping the
-- entire log in memory.
handleAppendEntries :: RPCHandler 'Follower (AppendEntries v) v
handleAppendEntries (NodeFollowerState fs) sender AppendEntries{..} = do
      PersistentState{..} <- get
      success <-
        case lookupLogEntry aePrevLogIndex psLog of
          Nothing -> pure False
          Just le
            | entryTerm le == aePrevLogTerm -> pure True
            | otherwise -> undefined
                -- removeLogsFromIndex aePrev
      pure (followerResultState Noop fs)
    where
      removeLogsFromIndex :: Index -> TransitionM v ()
      removeLogsFromIndex idx =
        modify $ \pstate ->
          let log = psLog pstate
           in pstate { psLog = dropLogEntriesUntil log idx }

-- | Followers should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Follower AppendEntriesResponse v
handleAppendEntriesResponse (NodeFollowerState fs) _ _ =
  pure (followerResultState Noop fs)

handleRequestVote :: RPCHandler 'Follower RequestVote v
handleRequestVote (NodeFollowerState fs) sender RequestVote{..} = do
    PersistentState{..} <- get
    let voteGranted = giveVote psCurrentTerm psVotedFor psLog
    send sender $ RequestVoteResponse
      { rvrTerm = psCurrentTerm
      , rvrVoteGranted = voteGranted
      }
    pure $ followerResultState Noop fs
  where
    giveVote term mVotedFor log =
      and [ term < rvTerm
          , validCandidateId mVotedFor
          , validCandidateLog log
          ]

    validCandidateId Nothing = True
    validCandidateId (Just cid) = cid == rvCandidateId

    -- Check if the requesting candidate's log is more up to date
    -- Section 5.4.1 in Raft Paper
    validCandidateLog log =
      let (idx, term) = lastLogEntryIndexAndTerm log
       in term < rvLastLogTerm && idx < rvLastLogIndex

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
      resetElectionTimeout
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
      (logEntryIndex, logEntryTerm) <-
        lastLogEntryIndexAndTerm <$> gets psLog
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
