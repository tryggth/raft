{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MonoLocalBinds #-}

module Raft.Candidate where

import Protolude

import Raft.Monad
import Raft.Types

--------------------------------------------------------------------------------
-- Candidate
--------------------------------------------------------------------------------

handleAppendEntries :: RPCHandler 'Candidate (AppendEntries v) v
handleAppendEntries = undefined

-- | Candidates should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Candidate AppendEntriesResponse v
handleAppendEntriesResponse = undefined

handleRequestVote :: RPCHandler 'Candidate RequestVote v
handleRequestVote = undefined

-- | Candidates should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Candidate RequestVoteResponse v
handleRequestVoteResponse = undefined

handleTimeout :: TimeoutHandler 'Candidate v
handleTimeout fs timeout = undefined
