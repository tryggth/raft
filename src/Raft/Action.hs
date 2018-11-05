{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}

module Raft.Action where

import Protolude

import Raft.Client
import Raft.RPC
import Raft.Log
import Raft.Event
import Raft.Types

data Action sm v
  = SendRPC NodeId (SendRPCAction v) -- ^ Send a message to a specific node id
  | SendRPCs (Map NodeId (SendRPCAction v)) -- ^ Send a unique message to specific nodes in parallel
  | BroadcastRPC NodeIds (SendRPCAction v) -- ^ Broadcast the same message to all nodes
  | AppendLogEntries (Entries v) -- ^ Append entries to the replicated log
  | RespondToClient ClientId (ClientResponse sm) -- ^ Respond to client after a client request
  | ResetTimeoutTimer Timeout -- ^ Reset a timeout timer
  deriving (Show)

data SendRPCAction v
  = SendAppendEntriesRPC (AppendEntriesData v)
  | SendAppendEntriesResponseRPC AppendEntriesResponse
  | SendRequestVoteRPC RequestVote
  | SendRequestVoteResponseRPC RequestVoteResponse
  deriving (Show)
