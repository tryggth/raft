{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Examples.Raft.Socket.Client where

import Protolude

import Control.Concurrent.Classy
import qualified Data.Serialize as S
import qualified Network.Simple.TCP as N
import qualified Data.Set as Set
import qualified Data.List as L
import qualified Data.Maybe as Maybe
import System.Random

import Raft.Client
import Raft.Event
import Raft.Types
import Examples.Raft.Socket.Common

data ClientSocketEnv
  = ClientSocketEnv { clientPort :: N.ServiceName
                    , clientHost :: N.HostName
                    , clientSocket :: N.Socket
                    } deriving (Show)

newtype RaftSocketClientM a
  = RaftSocketClientM { unRaftSocketClientM :: ReaderT ClientSocketEnv IO a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader ClientSocketEnv, Alternative, MonadPlus)

runRaftSocketClientM :: ClientSocketEnv -> RaftSocketClientM a -> IO a
runRaftSocketClientM socketEnv = flip runReaderT socketEnv . unRaftSocketClientM

-- | Randomly select a node from a set of nodes a send a message to it
selectRndNode :: NodeIds -> IO NodeId
selectRndNode nids =
  (Set.toList nids L.!!) <$> randomRIO (0, length nids - 1)

-- | Randomly read the state of a random node
sendReadRndNode :: (S.Serialize sm, S.Serialize v) => Proxy v -> NodeIds -> RaftSocketClientM (Either [Char] (ClientResponse sm))
sendReadRndNode proxyV nids =
  liftIO (selectRndNode nids) >>= sendRead proxyV

-- | Randomly write to a random node
sendWriteRndNode :: (S.Serialize v, S.Serialize sm) => v -> NodeIds -> RaftSocketClientM (Either [Char] (ClientResponse sm))
sendWriteRndNode cmd nids =
  liftIO (selectRndNode nids) >>= sendWrite cmd

-- | Request the state of a node. It blocks until the node responds
sendRead :: forall v sm. (S.Serialize sm, S.Serialize v) => Proxy v -> NodeId -> RaftSocketClientM (Either [Char] (ClientResponse sm))
sendRead _  nid = do
  socketEnv@ClientSocketEnv{..} <- ask
  let (host, port) = nidToHostPort (toS nid)
      clientId = ClientId (hostPortToNid (clientHost, clientPort))
  liftIO $ fork $ N.connect host port $ \(sock, sockAddr) -> N.send sock
    (S.encode (ClientRequestEvent (ClientRequest clientId ClientReadReq :: ClientRequest v)))
  acceptClientConnections

-- | Write to a node. It blocks until the node responds
sendWrite :: (S.Serialize v, S.Serialize sm) => v -> NodeId -> RaftSocketClientM (Either [Char] (ClientResponse sm))
sendWrite cmd nid = do
  socketEnv@ClientSocketEnv{..} <- ask
  let (host, port) = nidToHostPort (toS nid)
      clientId = ClientId (hostPortToNid (clientHost, clientPort))
  liftIO $ fork $ N.connect host port $ \(sock, sockAddr) -> N.send sock
    (S.encode (ClientRequestEvent (ClientRequest clientId (ClientWriteReq cmd))))
  acceptClientConnections

-- | Accept a connection and return the client response synchronously
acceptClientConnections :: S.Serialize sm => RaftSocketClientM (Either [Char] (ClientResponse sm))
acceptClientConnections = do
  socketEnv@ClientSocketEnv{..} <- ask
  liftIO $ N.accept clientSocket $ \(sock', sockAddr') -> do
    recvSock <- N.recv sock' 4096
    pure $ Maybe.fromJust (S.decode <$> recvSock)

