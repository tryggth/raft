

module Raft.Action where

import Protolude

import Numeric.Natural

import Raft.NodeState
import Raft.RPC
import Raft.Log
import Raft.Event
import Raft.Types

data Action v
  = SendMessage NodeId (Message v) -- ^ Send a message to a specific node id
  | SendMessages (Map NodeId (Message v)) -- ^ Send a unique message to specific nodes in parallel
  | Broadcast NodeIds (Message v) -- ^ Broadcast the same message to all nodes

  | RedirectClient ClientId CurrentLeader -- ^ Redirect a client to the current leader
  | RespondToClient ClientId -- ^ Respond to client after successful command application

  | ApplyCommittedLogEntry (Entry v) -- ^ Apply a replicated log entry to state machine
  | ResetTimeoutTimer Timeout Natural -- ^ Reset a timeout timer
  deriving (Show)
