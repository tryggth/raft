{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}

module Raft.Action where

import Protolude

import Data.Serialize
import Numeric.Natural

import Raft.Client
import Raft.NodeState
import Raft.RPC
import Raft.Log
import Raft.Event
import Raft.Types

data Action sm v
  = SendRPCMessage NodeId (RPCMessage v) -- ^ Send a message to a specific node id
  | SendRPCMessages (Map NodeId (RPCMessage v)) -- ^ Send a unique message to specific nodes in parallel
  | BroadcastRPC NodeIds (RPCMessage v) -- ^ Broadcast the same message to all nodes

  | RespondToClient ClientId (ClientResponse sm) -- ^ Respond to client after a client request

  | ResetTimeoutTimer Timeout -- ^ Reset a timeout timer
  deriving (Show)
