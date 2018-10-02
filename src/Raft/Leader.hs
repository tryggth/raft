{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MonoLocalBinds #-}

module Raft.Leader (
    handleAppendEntries
  , handleAppendEntriesResponse
  , handleRequestVote
  , handleRequestVoteResponse
  , handleTimeout
  , handleClientRequest
) where

import Protolude

import qualified Data.Map as Map
import Data.Sequence (Seq(Empty))

import Raft.Monad
import Raft.Types

--------------------------------------------------------------------------------
-- Leader
--------------------------------------------------------------------------------

-- | Leaders should not respond to 'AppendEntries' messages.
handleAppendEntries :: RPCHandler 'Leader (AppendEntries v) v
handleAppendEntries (NodeLeaderState ls)_ _  =
  pure (leaderResultState Noop ls)

handleAppendEntriesResponse :: RPCHandler 'Leader AppendEntriesResponse v
handleAppendEntriesResponse (NodeLeaderState ls) sender appendEntriesResp
  -- If AppendEntries fails (aerSuccess == False) because of log inconsistency,
  -- decrement nextIndex and retry
  | not (aerSuccess appendEntriesResp) = do
      let newNextIndices = Map.adjust decrIndex sender (lsNextIndex ls)
          newLeaderState = ls { lsNextIndex = newNextIndices }
      send sender =<< appendEntriesRPC Empty ls
      pure (leaderResultState Noop newLeaderState)
  | otherwise = do
      mLastLogEntryIndex <-
        fmap entryIndex . lastLogEntry <$> gets psLog
      newLeaderState <-
        case mLastLogEntryIndex of
          Nothing -> pure ls
          Just lastLogEntryIndex -> do
            let newNextIndices = Map.insert sender (lastLogEntryIndex + 1) (lsNextIndex ls)
                newMatchIndices = Map.insert sender lastLogEntryIndex (lsMatchIndex ls)
            pure ls { lsNextIndex = newNextIndices, lsMatchIndex = newMatchIndices }
      -- Increment leader commit index if now a majority of followers have
      -- replicated an entry at a given term.
      newestLeaderState <- incrCommitIndex newLeaderState
      pure (leaderResultState Noop newestLeaderState)

-- | Leaders should not respond to 'RequestVote' messages.
handleRequestVote :: RPCHandler 'Leader RequestVote v
handleRequestVote (NodeLeaderState ls) _ _ =
  pure (leaderResultState Noop ls)

-- | Leaders should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Leader RequestVoteResponse v
handleRequestVoteResponse (NodeLeaderState ls) _ _ =
  pure (leaderResultState Noop ls)

handleTimeout :: TimeoutHandler 'Leader v
handleTimeout (NodeLeaderState ls) timeout =
  case timeout of
    -- Leader does not handle election timeouts
    ElectionTimeout -> pure (leaderResultState Noop ls)
    -- On a heartbeat timeout, broadcast append entries RPC to all peers
    HeartbeatTimeout -> do
      uniqueBroadcast =<< appendEntriesRPCs ls
      pure (leaderResultState Heartbeat ls)

handleClientRequest :: ClientReqHandler 'Leader v
handleClientRequest = undefined

--------------------------------------------------------------------------------

-- | If there exists an N such that N > commitIndex, a majority of
-- matchIndex[i] >= N, and log[N].term == currentTerm: set commitIndex = N
incrCommitIndex :: LeaderState -> TransitionM v LeaderState
incrCommitIndex leaderState@LeaderState{..} = do
    mlatestEntry <- lastLogEntry <$> gets psLog
    currentTerm <- gets psCurrentTerm
    case mlatestEntry of
      Nothing -> pure leaderState
      Just latestEntry
        | majorityGreaterThan n && (entryTerm latestEntry == currentTerm) ->
            pure leaderState { lsCommitIndex = n }
        | otherwise -> pure leaderState
  where
    n = lsCommitIndex + 1

    majorityGreaterThan m =
      (>=) (Map.size (Map.filter (>= m) lsNextIndex))
           ((Map.size lsNextIndex) `div` 2 + 1)

-- | Construct bespoke AppendEntriesRPC values for each follower, with respect
-- to their current 'nextIndex' stored in the LeaderState.
appendEntriesRPCs :: LeaderState -> TransitionM v (Map NodeId (AppendEntries v))
appendEntriesRPCs leaderState@LeaderState{..} = do
  forM lsNextIndex $ \nextIndex -> do
    logEntries <- flip takeLogEntriesUntil nextIndex <$> gets psLog
    case logEntries of
      Empty -> appendEntriesRPC Empty leaderState
      entries -> appendEntriesRPC entries leaderState

-- | Construct an AppendEntriesRPC given log entries and a leader state.
appendEntriesRPC :: Entries v -> LeaderState -> TransitionM v (AppendEntries v)
appendEntriesRPC entries leaderState = do
  term <- gets psCurrentTerm
  leaderId <- asks configNodeId
  (prevLogIndex, prevLogTerm) <-
    lastLogEntryIndexAndTerm <$> gets psLog
  pure AppendEntries
    { aeTerm = term
    , aeLeaderId = LeaderId leaderId
    , aePrevLogIndex = prevLogIndex
    , aePrevLogTerm = prevLogTerm
    , aeEntries = entries
    , aeLeaderCommit = lsCommitIndex leaderState
    }
