{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MonoLocalBinds #-}

module Raft.Leader where

import Protolude

import Raft.Monad
import Raft.Types

--------------------------------------------------------------------------------
-- Leader
--------------------------------------------------------------------------------

instance Raft.Monad.HandleRPC Leader v where
  handleAppendEntries = Raft.Leader.handleAppendEntries
  handleAppendEntriesResponse = Raft.Leader.handleAppendEntriesResponse
  handleRequestVote = Raft.Leader.handleRequestVote
  handleRequestVoteResponse = Raft.Leader.handleRequestVoteResponse

handleAppendEntries :: RPCHandler 'Leader (AppendEntries v) v
handleAppendEntries = undefined

-- | Leaders should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Leader AppendEntriesResponse v
handleAppendEntriesResponse = undefined

handleRequestVote :: RPCHandler 'Leader RequestVote v
handleRequestVote = undefined

-- | Leaders should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Leader RequestVoteResponse v
handleRequestVoteResponse = undefined

handleTimeout :: TimeoutHandler 'Leader v
handleTimeout fs timeout = undefined
