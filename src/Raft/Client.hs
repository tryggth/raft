module Raft.Client where

import Protolude
import Raft.Types

data ClientWriteReq v
  = ClientWriteReq ClientId v
  deriving (Show)

newtype ClientReadReq = ClientReadReq ClientId
  deriving (Show)

newtype ClientReadRes s
  = ClientReadRes s
  deriving (Show)

newtype ClientWriteRes
  = ClientWriteRes Index
  deriving (Show)

