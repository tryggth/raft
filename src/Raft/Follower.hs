{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MonoLocalBinds #-}

module Raft.Follower where

import Protolude

import Raft.Monad
import Raft.Types

--------------------------------------------------------------------------------
-- Follower
--------------------------------------------------------------------------------

instance Raft.Monad.HandleRPC Follower v where
  handleAppendEntries = Raft.Follower.handleAppendEntries
  handleAppendEntriesResponse = Raft.Follower.handleAppendEntriesResponse
  handleRequestVote = Raft.Follower.handleRequestVote
  handleRequestVoteResponse = Raft.Follower.handleRequestVoteResponse

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
handleTimeout fs timeout = undefined
