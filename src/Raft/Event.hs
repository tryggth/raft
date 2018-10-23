{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module Raft.Event where

import Protolude

import qualified Data.Serialize as S

import Raft.Client
import Raft.RPC
import Raft.Types

data Timeout
  = ElectionTimeout
    -- ^ Timeout in which a follower will become candidate
  | HeartbeatTimeout
    -- ^ Timeout in which a leader will send AppendEntries RPC to all followers
  deriving (Show)

data MessageEvent v
  = RPCMessageEvent (RPCMessage v)
  | ClientRequestEvent (ClientRequest v)
  deriving (Show, Generic)

instance S.Serialize v => S.Serialize (MessageEvent v)

data Event v
  = MessageEvent (MessageEvent v)
  | TimeoutEvent Timeout
  deriving (Show)
