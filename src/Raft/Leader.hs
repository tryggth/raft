{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MonoLocalBinds #-}

module Raft.Leader where

import Protolude

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
handleAppendEntriesResponse = undefined

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
    HeartbeatTimeout -> do
      broadcast =<< appendEntriesRPC Empty ls
      pure (leaderResultState Heartbeat ls)

appendEntriesRPC :: Entries v -> LeaderState -> TransitionM v (AppendEntries v)
appendEntriesRPC entries leaderState = do
  term <- gets psCurrentTerm
  leaderId <- asks configNodeId
  (prevLogIndex, prevLogTerm) <-
    lastLogEntryIndexAndTerm <$> gets psLog
  pure AppendEntries
    { aeTerm = term
    , aeLeaderId = leaderId
    , aePrevLogIndex = prevLogIndex
    , aePrevLogTerm = prevLogTerm
    , aeEntries = entries
    , aeLeaderCommit = lsCommitIndex leaderState
    }
