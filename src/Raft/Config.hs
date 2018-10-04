

module Raft.Config where

import Protolude

import Numeric.Natural (Natural)

import Raft.Types

data NodeConfig = NodeConfig
  { configNodeId :: NodeId
  , configNodeIds :: NodeIds
  , configElectionTimeout :: Natural
  , configHeartbeatTimeout :: Natural
  } deriving (Show)

-- TODO Config file utils
