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

import Data.Sequence (Seq(..))

import Raft.Action
import Raft.NodeState
import Raft.RPC
import Raft.Client
import Raft.Event
import Raft.Persistent
import Raft.Log (entryIndex)
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
handleAppendEntries :: forall v sm. Show v => RPCHandler 'Follower sm (AppendEntries v) v
handleAppendEntries ns@(NodeFollowerState fs) sender AppendEntries{..} = do
    PersistentState{..} <- get
    (success, newFollowerState) <-
      if aeTerm < currentTerm
        -- 1. Reply false if term < currentTerm
        then pure (False, fs)
        else
          case fsEntryTermAtAEIndex fs of
            Nothing
              | aePrevLogIndex == index0 -> do
                  appendLogEntries aeEntries
                  pure (True, updateFollowerState fs)
              | otherwise -> pure (False, fs)
            Just logEntryAtAePrevLogIndexTerm ->
              -- 2. Reply false if log doesn't contain an entry at
              -- prevLogIndex whose term matches prevLogTerm.
              if logEntryAtAePrevLogIndexTerm /= aePrevLogTerm
                then pure (False, fs)
                else do
                  -- 3. If an existing entry conflicts with a new one (same index
                  -- but different terms), delete the existing entry and all that
                  -- follow it.
                  --   &
                  -- 4. Append any new entries not already in the log
                  -- (emits an action that accomplishes 3 & 4
                  appendLogEntries aeEntries
                  -- 5. If leaderCommit > commitIndex, set commitIndex =
                  -- min(leaderCommit, index of last new entry)
                  pure (True, updateFollowerState fs)
    send (unLeaderId aeLeaderId) $
      SendAppendEntriesResponseRPC $
        AppendEntriesResponse
          { aerTerm = currentTerm
          , aerSuccess = success
          }
    resetElectionTimeout
    pure (followerResultState Noop newFollowerState)
  where
    updateFollowerState :: FollowerState -> FollowerState
    updateFollowerState fs =
      if aeLeaderCommit > fsCommitIndex fs
        then updateLeader (updateCommitIndex fs)
        else updateLeader fs

    updateCommitIndex :: FollowerState -> FollowerState
    updateCommitIndex followerState =
      case aeEntries of
        Empty ->
          -- TODO move to action, as this should update to _true_ last log entry
          -- that follower has written to disk, not supposed commit index
          -- assuming leader has replicated all logs to this follower
          followerState { fsCommitIndex = aeLeaderCommit }
        _ :|> e ->
          let newCommitIndex = min aeLeaderCommit (entryIndex e)
          in followerState { fsCommitIndex = newCommitIndex }

    updateLeader :: FollowerState -> FollowerState
    updateLeader followerState = followerState { fsCurrentLeader = CurrentLeader (LeaderId sender) }

-- | Followers should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Follower sm AppendEntriesResponse v
handleAppendEntriesResponse (NodeFollowerState fs) _ _ =
  pure (followerResultState Noop fs)

handleRequestVote :: RPCHandler 'Follower sm RequestVote v
handleRequestVote ns@(NodeFollowerState fs) sender RequestVote{..} = do
    PersistentState{..} <- get
    let voteGranted = giveVote currentTerm votedFor
    logDebug $ "Vote granted: " <> show voteGranted
    send sender $
      SendRequestVoteResponseRPC $
        RequestVoteResponse
          { rvrTerm = currentTerm
          , rvrVoteGranted = voteGranted
          }
    when voteGranted $
      modify $ \pstate ->
        pstate { votedFor = Just sender }
    pure $ followerResultState Noop fs
  where
    giveVote term mVotedFor =
      and [ term <= rvTerm
          , validCandidateId mVotedFor
          , validCandidateLog
          ]

    validCandidateId Nothing = True
    validCandidateId (Just cid) = cid == rvCandidateId

    -- Check if the requesting candidate's log is more up to date
    -- Section 5.4.1 in Raft Paper
    validCandidateLog =
      let (lastLogEntryIdx, lastLogEntryTerm) = fsLastLogEntryData fs
       in (rvLastLogTerm > lastLogEntryTerm)
       || (rvLastLogTerm == lastLogEntryTerm && rvLastLogIndex >= lastLogEntryIdx)

-- | Followers should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Follower sm RequestVoteResponse v
handleRequestVoteResponse (NodeFollowerState fs) _ _  =
  pure (followerResultState Noop fs)

-- | Follower converts to Candidate if handling ElectionTimeout
handleTimeout :: TimeoutHandler 'Follower sm v
handleTimeout ns@(NodeFollowerState fs) timeout =
  case timeout of
    ElectionTimeout -> do
      logDebug "Follower times out. Starts election. Becomes candidate"
      candidateResultState StartElection <$>
        startElection (fsCommitIndex fs) (fsLastApplied fs) (fsLastLogEntryData fs)
    -- Follower should ignore heartbeat timeout events
    HeartbeatTimeout -> pure (followerResultState Noop fs)

-- | When a client handles a client request, it redirects the client to the
-- current leader by responding with the current leader id, if it knows of one.
handleClientRequest :: ClientReqHandler 'Follower sm v
handleClientRequest (NodeFollowerState fs) (ClientRequest clientId _)= do
  redirectClientToLeader clientId (fsCurrentLeader fs)
  pure (followerResultState Noop fs)
