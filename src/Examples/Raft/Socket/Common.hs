module Examples.Raft.Socket.Common where

import Protolude

import qualified Data.ByteString as BS
import qualified Network.Simple.TCP as N
import qualified Data.Word8 as W8

import Raft.Types

-- | Convert a host and a port to a valid NodeId
hostPortToNid :: (N.HostName, N.ServiceName) -> NodeId
hostPortToNid (host, port) = toS $ host ++ ":" ++ toS port

-- | Retrieve the host and port from a valid NodeId
nidToHostPort :: NodeId -> (N.HostName, N.ServiceName)
nidToHostPort bs =
  case BS.split W8._colon bs of
    [host,port] -> (toS host, toS port)
    _ -> panic "nidToHostPort: invalid node id"
