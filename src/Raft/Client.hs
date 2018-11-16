{-# LANGUAGE DeriveGeneric #-}

module Raft.Client where

import Protolude

import qualified Data.Serialize as S

import Raft.NodeState
import Raft.Types

-- | Representation of a client request coupled with the client id
data ClientRequest v
  = ClientRequest ClientId (ClientReq v)
  deriving (Show, Generic)

instance S.Serialize v => S.Serialize (ClientRequest v)

-- | Representation of a client request
data ClientReq v
  = ClientReadReq -- ^ Request the latest state of the state machine
  | ClientWriteReq v -- ^ Write a command
  deriving (Show, Generic)

instance S.Serialize v => S.Serialize (ClientReq v)

-- | Representation of a client response
data ClientResponse s
  = ClientReadResponse (ClientReadResp s)
    -- ^ Respond with the latest state of the state machine.
  | ClientWriteResponse ClientWriteResp
    -- ^ Respond with the index of the entry appended to the log
  | ClientRedirectResponse ClientRedirResp
    -- ^ Respond with the node id of the current leader
  deriving (Show, Generic)

instance S.Serialize s => S.Serialize (ClientResponse s)

-- | Representation of a read response to a client
-- The `s` stands for the "current" state of the state machine
newtype ClientReadResp s
  = ClientReadResp s
  deriving (Show, Generic)

instance S.Serialize s => S.Serialize (ClientReadResp s)

-- | Representation of a write response to a client
data ClientWriteResp
  = ClientWriteResp Index
  -- ^ Index of the entry appended to the log due to the previous client request
  deriving (Show, Generic)

instance S.Serialize ClientWriteResp

-- | Representation of a redirect response to a client
data ClientRedirResp
  = ClientRedirResp CurrentLeader
  deriving (Show, Generic)

instance S.Serialize ClientRedirResp
