{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module Raft.Event where

import Protolude

import qualified Data.Serialize as S

import Raft.Client
import Raft.RPC

-- | Representation of events a raft node can send and receive
data Event v
  = MessageEvent (MessageEvent v)
  | TimeoutEvent Timeout
  deriving (Show)

-- | Representation of timeouts
data Timeout
  = ElectionTimeout
    -- ^ Timeout after which a follower will become candidate
  | HeartbeatTimeout
    -- ^ Timeout after which a leader will send AppendEntries RPC to all peers
  deriving (Show)

-- | Representation of message events to a node
data MessageEvent v
  = RPCMessageEvent (RPCMessage v) -- ^ Incoming event from a peer
  | ClientRequestEvent (ClientRequest v) -- ^ Incoming event from a client
  deriving (Show, Generic)

instance S.Serialize v => S.Serialize (MessageEvent v)


