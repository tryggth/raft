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
  , handleClientRequest
) where

import Protolude

import Data.Sequence (Seq, takeWhileL)
import Data.Set (singleton)

import Raft.NodeState
import Raft.RPC
import Raft.Client
import Raft.Event
import Raft.Persistent
import Raft.Config
import Raft.Log
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
handleAppendEntries ns@(NodeFollowerState fs) sender AppendEntries{..} = do
      PersistentState{..} <- get
      (success, newFollowerState) <-
        if aeTerm < psCurrentTerm
          -- 1. Reply false if term < currentTerm
          then pure (False, fs)
          else
            case lookupLogEntry aePrevLogIndex psLog of
              Nothing
                | aePrevLogIndex == index0 -> do
                    appendNewLogEntries aeEntries
                    pure (True, updateLeader fs)
                | otherwise -> pure (False, fs)
              Just logEntry ->
                -- 2. Reply false if log doesn't contain an entry at
                -- prevLogIndex
                -- whose term matches prevLogTerm.
                if entryTerm logEntry /= aePrevLogTerm
                  then pure (False, fs)
                  else do
                    -- 3. If an existing entry conflicts with a new one (same index
                    -- but different terms), delete the existing entry and all that
                    -- follow it.
                    when (entryTerm logEntry /= aePrevLogTerm) $
                      removeLogsFromIndex aePrevLogIndex
                    -- 4. Append any new entries not already in the log
                    appendNewLogEntries aeEntries
                    -- 5. If leaderCommit > commitIndex, set commitIndex =
                    -- min(leaderCommit, index of last new entry)
                    if aeLeaderCommit > fsCommitIndex fs
                      then pure (True, (updateLeader . updateCommitIndex) fs)
                      else pure (True, updateLeader fs)
      send (unLeaderId aeLeaderId)
        AppendEntriesResponse
          { aerTerm = psCurrentTerm
          , aerSuccess = success
          }
      resetElectionTimeout
      pure (followerResultState Noop newFollowerState)
    where
      removeLogsFromIndex :: Index -> TransitionM v ()
      removeLogsFromIndex idx =
        modify $ \pstate ->
          let log = psLog pstate
           in pstate { psLog = dropLogEntriesUntil log idx }

      updateCommitIndex :: FollowerState -> FollowerState
      updateCommitIndex followerState =
        case lastEntry aeEntries of
          Nothing ->
            followerState { fsCommitIndex = aeLeaderCommit }
          Just e ->
            let newCommitIndex = min aeLeaderCommit (entryIndex e)
            in followerState { fsCommitIndex = newCommitIndex }

      updateLeader :: FollowerState -> FollowerState
      updateLeader followerState = followerState { fsCurrentLeader = CurrentLeader (LeaderId sender) }

-- | Followers should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Follower AppendEntriesResponse v
handleAppendEntriesResponse (NodeFollowerState fs) _ _ =
  pure (followerResultState Noop fs)

handleRequestVote :: RPCHandler 'Follower RequestVote v
handleRequestVote ns@(NodeFollowerState fs) sender RequestVote{..} = do
    PersistentState{..} <- get
    let voteGranted = giveVote psCurrentTerm psVotedFor psLog
    tellLogWithState ns (toS $ "Vote granted: " ++ show voteGranted)
    send sender RequestVoteResponse
      { rvrTerm = psCurrentTerm
      , rvrVoteGranted = voteGranted
      }
    modify $ \ps -> ps { psVotedFor = Just sender }
    pure $ followerResultState Noop fs
  where
    giveVote term mVotedFor log =
      and [ term <= rvTerm
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
        Just (Entry idx term _ _) ->
          term < rvLastLogTerm && idx < rvLastLogIndex

-- | Followers should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Follower RequestVoteResponse v
handleRequestVoteResponse (NodeFollowerState fs) _ _  =
  pure (followerResultState Noop fs)

-- | Follower converts to Candidate if handling ElectionTimeout
handleTimeout :: TimeoutHandler 'Follower v
handleTimeout ns@(NodeFollowerState fs) timeout =
  case timeout of
    ElectionTimeout -> do
      tellLogWithState ns "Follower times out. Starts election. Becomes candidate"
      candidateResultState StartElection <$>
        updateElectionTimeoutCandidateState (fsCommitIndex fs) (fsLastApplied fs)
    -- Follower should ignore heartbeat timeout events
    HeartbeatTimeout -> pure (followerResultState Noop fs)

-- | When a client handles a client request, it redirects the client to the
-- current leader by responding with the current leader id, if it knows of one.
handleClientRequest :: ClientReqHandler 'Follower v
handleClientRequest (NodeFollowerState fs) (ClientWriteReq clientId _)= do
  redirectClientToLeader clientId (fsCurrentLeader fs)
  pure (followerResultState Noop fs)

