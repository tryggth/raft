{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module Raft.Client where

import Protolude

import qualified Data.Serialize as S

import Raft.NodeState
import Raft.Types

data ClientRequest v
  = ClientRequest ClientId (ClientReq v)
  deriving (Show, Generic)

instance S.Serialize v => S.Serialize (ClientRequest v)

data ClientReq v
  = ClientReadReq
  | ClientWriteReq v
  deriving (Show, Generic)

instance S.Serialize v => S.Serialize (ClientReq v)

data ClientResponse s
  = ClientReadResponse (ClientReadResp s)
  | ClientWriteResponse ClientWriteResp
  | ClientRedirectResponse ClientRedirResp
  deriving (Show, Generic)

instance S.Serialize s => S.Serialize (ClientResponse s)

newtype ClientReadResp s
  = ClientReadResp s
  deriving (Show, Generic)

instance S.Serialize s => S.Serialize (ClientReadResp s)

data ClientWriteResp
  = ClientWriteResp Index
  deriving (Show, Generic)

instance S.Serialize ClientWriteResp

data ClientRedirResp
  = ClientRedirResp CurrentLeader
  deriving (Show, Generic)

instance S.Serialize ClientRedirResp

