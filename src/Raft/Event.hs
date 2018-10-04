

module Raft.Event where

import Protolude

import Raft.RPC
import Raft.Types

data Timeout
  = ElectionTimeout
    -- ^ Timeout in which a follower will become candidate
  | HeartbeatTimeout
    -- ^ Timeout in which a leader will send AppendEntries RPC to all followers
  deriving (Show)

data ClientReq v
  = ClientReq ClientId v
  deriving (Show)

data Event v
  = Message (Message v)
  | ClientRequest (ClientReq v)
  | Timeout Timeout
  deriving (Show)
