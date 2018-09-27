{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE DataKinds #-}

module Raft.Follower where

import Protolude

import Raft.Monad
import Raft.Types

--------------------------------------------------------------------------------
-- Follower
--------------------------------------------------------------------------------

handleEvent :: EventHandler 'Follower v
handleEvent fs event =
  case event of
    Message msg -> handleMessage fs msg
    Timeout tout -> handleTimeout fs tout

handleMessage :: MessageHandler 'Follower v
handleMessage fs (RPC sender rpc) =
  case rpc of
    AppendEntriesRPC appendEntries ->
      handleAppendEntries fs sender appendEntries
    AppendEntriesResponseRPC appendEntriesResp ->
      handleAppendEntriesResponse fs sender appendEntriesResp
    RequestVoteRPC requestVote ->
      handleRequestVote fs sender requestVote
    RequestVoteResponseRPC requestVoteResp ->
      handleRequestVoteResponse fs sender requestVoteResp

handleAppendEntries :: RPCHandler 'Follower (AppendEntries v) v
handleAppendEntries = undefined

-- | Followers should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Follower AppendEntriesResponse v
handleAppendEntriesResponse = undefined

handleRequestVote :: RPCHandler 'Follower RequestVote v
handleRequestVote = undefined

-- | Followers should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Follower RequestVoteResponse v
handleRequestVoteResponse = undefined

handleTimeout :: TimeoutHandler 'Follower v
handleTimeout fs timeout =
  case timeout of
    ElectionTimeout -> undefined
