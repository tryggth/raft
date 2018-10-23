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
import Data.Sequence (Seq((:<|),Empty), (><))
import qualified Data.Sequence as Seq
import Control.Monad.RWS

import Raft.NodeState
import Raft.RPC
import Raft.Action
import Raft.Client
import Raft.Event
import Raft.Persistent
import Raft.Config
import Raft.Log
import Raft.Monad
import Raft.Types

--------------------------------------------------------------------------------
-- Leader
--------------------------------------------------------------------------------

-- | Leaders should not respond to 'AppendEntries' messages.
handleAppendEntries :: RPCHandler 'Leader sm (AppendEntries v) v
handleAppendEntries (NodeLeaderState ls)_ _  =
  pure (leaderResultState Noop ls)

handleAppendEntriesResponse :: Show v => RPCHandler 'Leader sm AppendEntriesResponse v
handleAppendEntriesResponse ns@(NodeLeaderState ls) sender appendEntriesResp
  -- If AppendEntries fails (aerSuccess == False) because of log inconsistency,
  -- decrement nextIndex and retry
  | not (aerSuccess appendEntriesResp) = do
      let newNextIndices = Map.adjust decrIndex sender (lsNextIndex ls)
          newLeaderState = ls { lsNextIndex = newNextIndices }
      send sender =<< appendEntriesRPC Empty ls
      pure (leaderResultState Noop newLeaderState)
  | otherwise = do
      mLastLogEntryIndex <-
        fmap entryIndex . lastLogEntry . psLog <$> getPersistentState
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
      when (lsCommitIndex newestLeaderState > lsCommitIndex newLeaderState) $ do
        Just clientId <- lastLogEntryClientId . psLog <$> getPersistentState
        tellActions [RespondToClient clientId (ClientWriteResponse (ClientWriteResp (lsCommitIndex newestLeaderState)))]
      tellLogWithState ns $ toS $ "HandleAppendEntriesResponse: " ++ show (aerSuccess appendEntriesResp)
      pure (leaderResultState Noop newestLeaderState)

-- | Leaders should not respond to 'RequestVote' messages.
handleRequestVote :: RPCHandler 'Leader sm RequestVote v
handleRequestVote (NodeLeaderState ls) _ _ =
  pure (leaderResultState Noop ls)

-- | Leaders should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Leader sm RequestVoteResponse v
handleRequestVoteResponse (NodeLeaderState ls) _ _ =
  pure (leaderResultState Noop ls)

handleTimeout :: Show v => TimeoutHandler 'Leader sm v
handleTimeout (NodeLeaderState ls) timeout =
  case timeout of
    -- Leader does not handle election timeouts
    ElectionTimeout -> pure (leaderResultState Noop ls)
    -- On a heartbeat timeout, broadcast append entries RPC to all peers
    HeartbeatTimeout -> do
      uniqueBroadcast =<< appendEntriesRPCs ls
      pure (leaderResultState SendHeartbeat ls)

-- | The leader handles all client requests, responding with the current state
-- machine on a client read, and appending an entry to the log on a valid client
-- write.
handleClientRequest :: Show v => ClientReqHandler 'Leader sm v
handleClientRequest (NodeLeaderState ls) (ClientRequest clientId cr) = do
    case cr of
      ClientReadReq -> respondClientRead clientId
      ClientWriteReq v -> do
        idx <- nextLogEntryIndex . psLog <$> getPersistentState
        broadcast =<< mkAppendEntriesRPC =<< mkNewLogEntry v idx
    pure (leaderResultState Noop ls)
  where
    mkAppendEntriesRPC entry =
      appendEntriesRPC (entry :<| Empty) ls

    mkNewLogEntry v idx = do
      currentTerm <- psCurrentTerm <$> getPersistentState
      pure $ Entry
        { entryIndex = idx
        , entryTerm = currentTerm
        , entryValue = v
        , entryClientId = clientId
        }

--------------------------------------------------------------------------------

-- | If there exists an N such that N > commitIndex, a majority of
-- matchIndex[i] >= N, and log[N].term == currentTerm: set commitIndex = N
incrCommitIndex :: Show v => LeaderState -> TransitionM sm v LeaderState
incrCommitIndex leaderState@LeaderState{..} = do
    mlatestEntry <- lastLogEntry . psLog <$> getPersistentState
    currentTerm <- psCurrentTerm <$> getPersistentState
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
appendEntriesRPCs :: Show v => LeaderState -> TransitionM sm v (Map NodeId (AppendEntries v))
appendEntriesRPCs leaderState@LeaderState{..} =
  forM lsNextIndex $ \nextIndex -> do
    logEntries <- flip takeLogEntriesUntil nextIndex . psLog <$> getPersistentState
    case logEntries of
      Empty -> appendEntriesRPC Empty leaderState
      entries -> appendEntriesRPC entries leaderState

-- | Construct an AppendEntriesRPC given log entries and a leader state.
appendEntriesRPC :: Show v => Entries v -> LeaderState -> TransitionM sm v (AppendEntries v)
appendEntriesRPC entries leaderState = do
  term <- psCurrentTerm <$> getPersistentState
  leaderId <- asks configNodeId
  (prevLogIndex, prevLogTerm) <-
    lastLogEntryIndexAndTerm . psLog <$> getPersistentState
  appendNewLogEntries entries
  pure AppendEntries
    { aeTerm = term
    , aeLeaderId = LeaderId leaderId
    , aePrevLogIndex = prevLogIndex
    , aePrevLogTerm = prevLogTerm
    , aeEntries = entries
    , aeLeaderCommit = lsCommitIndex leaderState
    }
