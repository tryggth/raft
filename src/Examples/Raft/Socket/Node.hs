{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Examples.Raft.Socket.Node where

import Protolude hiding
  ( MVar, putMVar, takeMVar, newMVar, newEmptyMVar, readMVar
  , atomically, STM(..), Chan, newTVar, readTVar, writeTVar
  , newChan, writeChan, readChan
  , threadDelay, killThread, TVar(..)
  , catch, handle, takeWhile, takeWhile1, (<|>)
  )

import Control.Concurrent.Classy hiding (catch, ThreadId)
import Control.Monad.Catch
import Control.Monad.Trans.Class

import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Serialize as S
import qualified Network.Simple.TCP as NS
import Network.Simple.TCP

import Examples.Raft.Socket.Common

import Raft

--------------------------------------------------------------------------------
-- Network
--------------------------------------------------------------------------------

data NodeSocketEnv v = NodeSocketEnv
  { nsSocket :: Socket
  , nsPeers :: TVar (STM IO) (Map NodeId Socket)
  , nsMsgQueue :: TChan (STM IO) (RPCMessage v)
  , nsClientReqQueue :: TChan (STM IO) (ClientRequest v)
  }


newtype RaftSocketT v m a = RaftSocketT { unRaftSocketT :: ReaderT (NodeSocketEnv v) m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader (NodeSocketEnv v), Alternative, MonadPlus, MonadTrans)

deriving instance MonadConc m => MonadThrow (RaftSocketT v m)
deriving instance MonadConc m => MonadCatch (RaftSocketT v m)
deriving instance MonadConc m => MonadMask (RaftSocketT v m)
deriving instance MonadConc m => MonadConc (RaftSocketT v m)

--------------------
-- Raft Instances --
--------------------

instance (MonadIO m, MonadConc m, S.Serialize sm) => RaftSendClient (RaftSocketT v m) sm where
  sendClient clientId@(ClientId nid) msg = do
    let (cHost, cPort) = nidToHostPort (toS nid)
    connect cHost cPort $ \(cSock, _cSockAddr) ->
      send cSock (S.encode msg)

instance (MonadIO m, MonadConc m, S.Serialize v) => RaftRecvClient (RaftSocketT v m) v where
  receiveClient = do
    cReq <- asks nsClientReqQueue
    liftIO $ atomically $ readTChan cReq

instance (MonadIO m, MonadConc m, S.Serialize v, Show v) => RaftSendRPC (RaftSocketT v m) v where
  sendRPC nid msg = do
    tNodeSocketEnvPeers <- asks nsPeers
    nodeSocketPeers <- liftIO $ atomically $ readTVar tNodeSocketEnvPeers
    sockM <- liftIO $
        case Map.lookup nid nodeSocketPeers of
          Nothing -> handle (handleFailure tNodeSocketEnvPeers [nid] Nothing) $ do
            (sock, _) <- connectSock host port
            NS.send sock (S.encode $ RPCMessageEvent msg)
            pure $ Just sock
          Just sock -> handle (retryConnection tNodeSocketEnvPeers nid (Just sock) msg) $ do
            NS.send sock (S.encode $ RPCMessageEvent msg)
            pure $ Just sock
    liftIO $ atomically $ case sockM of
      Nothing -> pure ()
      Just sock -> writeTVar tNodeSocketEnvPeers (Map.insert nid sock nodeSocketPeers)
    where
      (host, port) = nidToHostPort nid

instance (MonadIO m, MonadConc m, Show v) => RaftRecvRPC (RaftSocketT v m) v where
  receiveRPC = do
    msgQueue <- asks nsMsgQueue
    liftIO $ atomically $ readTChan msgQueue


-----------
-- Utils --
-----------

-- | Handles connections failures by first trying to reconnect
retryConnection
  :: (S.Serialize v, MonadIO m, MonadConc m)
  => TVar (STM m) (Map NodeId Socket)
  -> NodeId
  -> Maybe Socket
  -> RPCMessage v
  -> SomeException
  -> m (Maybe Socket)
retryConnection tNodeSocketEnvPeers nid sockM msg e =  case sockM of
  Nothing -> pure Nothing
  Just sock ->
    handle (handleFailure tNodeSocketEnvPeers [nid] Nothing) $ do
      (sock, _) <- connectSock host port
      NS.send sock (S.encode $ RPCMessageEvent msg)
      pure $ Just sock
  where
    (host, port) = nidToHostPort nid

handleFailure
  :: (MonadIO m, MonadConc m)
  => TVar (STM m) (Map NodeId Socket)
  -> [NodeId]
  -> Maybe Socket
  -> SomeException
  -> m (Maybe Socket)
handleFailure tNodeSocketEnvPeers nids sockM e = case sockM of
  Nothing -> pure Nothing
  Just sock -> do
    nodeSocketPeers <- atomically $ readTVar tNodeSocketEnvPeers
    closeSock sock
    atomically $ mapM_ (\nid -> writeTVar tNodeSocketEnvPeers (Map.delete nid nodeSocketPeers)) nids
    pure Nothing


runRaftSocketT :: (MonadIO m, MonadConc m) => NodeSocketEnv v -> RaftSocketT v m a -> m a
runRaftSocketT nodeSocketEnv = flip runReaderT nodeSocketEnv . unRaftSocketT

-- | Recursively accept a connection.
-- It keeps trying to accept connections even when a node dies
acceptForkNode
  :: forall v m. (S.Serialize v, MonadIO m, MonadConc m)
  => RaftSocketT v m ()
acceptForkNode = do
  socketEnv@NodeSocketEnv{..} <- ask
  void $ fork $ void $ forever $ acceptFork nsSocket $ \(sock', sockAddr') ->
    forever $ do
      recvSock <- recv sock' 4096
      case Maybe.fromJust ((S.decode :: ByteString -> Either [Char] (MessageEvent v)) <$> recvSock) of
        Left err -> panic $ toS err
        Right (ClientRequestEvent req@(ClientRequest cid _)) ->
          atomically $ writeTChan nsClientReqQueue req
        Right (RPCMessageEvent msg) ->
          atomically $ writeTChan nsMsgQueue msg

newSock :: HostName -> ServiceName -> IO Socket
newSock host port = do
  (sock, _) <- bindSock (Host host) port
  listenSock sock 2048
  pure sock


