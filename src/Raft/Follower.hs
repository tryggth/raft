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

import Data.Sequence (Seq, takeWhileL)
import Data.Set (singleton)

import Raft.Monad
import Raft.Types

--------------------------------------------------------------------------------
-- Follower
--------------------------------------------------------------------------------

-- | Handle AppendEntries RPC message from Leader
-- Sections 5.2 and 5.3 of Raft Paper & Figure 2: Receiver Implementation
--
-- Note: see 'PersistentState' datatype for discussion about not keeping the
-- entire log in memory.
handleAppendEntries :: forall v. RPCHandler 'Follower (AppendEntries v) v
handleAppendEntries (NodeFollowerState fs) sender AppendEntries{..} = do
      PersistentState{..} <- get
      (success, newFollowerState) <-
        if psCurrentTerm < aeTerm
          -- 1. Reply false if term < currentTerm
          then pure (False, fs)
          else
            case lookupLogEntry aePrevLogIndex psLog of
              -- 2. Reply false if log doesn't contain an entry at prevLogIndex
              -- whose term matches prevLogTerm
              Nothing -> pure (False, fs)
              Just logEntry -> do
                -- 3. If an existing entry conflicts with a new one (same index
                -- but different terms), delete the existing entry and all that
                -- follow it.
                when (entryTerm logEntry /= aePrevLogTerm) $
                  removeLogsFromIndex aePrevLogIndex
                -- 4. Append any new entries not already in the log
                appendNewLogEntries (newLogEntries logEntry)
                -- 5. If leaderCommit > commitIndex, set commitIndex =
                -- min(leaderCommit, index of last new entry)
                if (aeLeaderCommit > fsCommitIndex fs)
                  then pure (True, updateCommitIndex fs)
                  else pure (True, fs)
      send aeLeaderId $ AppendEntriesResponse
        { aerTerm = psCurrentTerm
        , aerSuccess = success
        }
      pure (followerResultState Noop newFollowerState)
    where
      removeLogsFromIndex :: Index -> TransitionM v ()
      removeLogsFromIndex idx =
        modify $ \pstate ->
          let log = psLog pstate
           in pstate { psLog = dropLogEntriesUntil log idx }

      appendNewLogEntries :: Seq (Entry v) -> TransitionM v ()
      appendNewLogEntries newEntries =
        modify $ \pstate ->
          case appendLogEntries (psLog pstate) newEntries of
            Left err -> panic (show err)
            Right newLog -> pstate { psLog = newLog }

      newLogEntries :: Entry v -> Seq (Entry v)
      newLogEntries lastLogEntry =
        takeWhileL ((<) (entryIndex lastLogEntry) . entryIndex) aeEntries

      updateCommitIndex :: FollowerState -> FollowerState
      updateCommitIndex followerState =
        case lastEntry aeEntries of
          Nothing -> followerState
          Just e ->
            let newCommitIndex = min aeLeaderCommit (entryIndex e)
             in followerState { fsCommitIndex = newCommitIndex }

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
      case lastLogEntry log of
        Nothing -> True
        Just (Entry idx term _) ->
          term < rvLastLogTerm && idx < rvLastLogIndex

-- | Followers should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Follower RequestVoteResponse v
handleRequestVoteResponse (NodeFollowerState fs) _ _  =
  pure (followerResultState Noop fs)

-- | Follower converts to Candidate if handling ElectionTimeout
handleTimeout :: TimeoutHandler 'Follower v
handleTimeout (NodeFollowerState fs) timeout =
  case timeout of
    ElectionTimeout ->
      candidateResultState StartElection <$>
        updateElectionTimeoutCandidateState (fsCommitIndex fs) (fsLastApplied fs)
