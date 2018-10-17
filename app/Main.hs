{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Protolude hiding
  ( MVar, putMVar, takeMVar, newMVar, newEmptyMVar, readMVar
  , atomically, STM(..), Chan, newTVar, readTVar, writeTVar
  , newChan, writeChan, readChan
  , threadDelay, killThread, TVar(..)
  , catch, handle
  )

import Control.Concurrent.Classy hiding (catch)
import Control.Monad.STM.Class

import Control.Monad.Catch
import qualified Data.ByteString as BS
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Serialize as S
import qualified Data.Word8 as W8
import Network.Simple.TCP
import qualified Network.Socket as N
import qualified Network.Socket.ByteString as NSB
import Numeric.Natural

import Raft
import Raft.Config
import Raft.Persistent
import Raft.Types
import Raft.Event
import Raft.RPC
import Raft.Client

--------------------------------------------------------------------------------
-- State Machine & Commands
--------------------------------------------------------------------------------

type Var = ByteString

data StoreCmd
  = Set Var Natural
  | Incr Var
  deriving (Show, Generic)

instance S.Serialize StoreCmd

type Store = Map Var Natural

instance RaftStateMachine Store StoreCmd where
  applyCommittedLogEntry store cmd =
    case cmd of
      Set x n -> Map.insert x n store
      Incr x -> Map.adjust succ x store

--------------------------------------------------------------------------------
-- Mock Network
--------------------------------------------------------------------------------

data NodeEnv m = NodeEnv
  { nodeEnvStore :: TVar (STM m) Store
  , nodeEnvPState :: TVar (STM m) (PersistentState StoreCmd)
  , nodeEnvPeers :: NodeIds
  , nodeEnvNodeId :: NodeId
  , nodeEnvSocket :: Socket
  , nodeEnvSocketPeers :: TVar (STM m) (Map NodeId Socket)
  , nodeEnvMsgQueue :: TChan (STM m) (Message StoreCmd)
  }

deriving instance MonadThrow m => MonadThrow (NodeEnvT m)
deriving instance MonadCatch m => MonadCatch (NodeEnvT m)
deriving instance MonadMask m => MonadMask (NodeEnvT m)
deriving instance MonadConc m => MonadConc (NodeEnvT m)

newtype NodeEnvT m a = NodeEnvT { unNodeEnvT :: ReaderT (NodeEnv m) m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader (NodeEnv m), Alternative, MonadPlus)

runNodeEnvT :: NodeEnv m -> NodeEnvT m a -> m a
runNodeEnvT testEnv = flip runReaderT testEnv . unNodeEnvT

instance MonadConc m => RaftPersist (NodeEnvT m) StoreCmd where
  savePersistentState pstate' =
    asks nodeEnvPState >>= atomically . flip writeTVar pstate'
  loadPersistentState =
    asks nodeEnvPState >>= atomically . readTVar

instance MonadIO m => RaftClientRPC (NodeEnvT m) Store where
  sendClientRPC (ClientId cid) msg = undefined

instance (MonadIO m, MonadConc m) => RaftSendRPC (NodeEnvT m) StoreCmd where
  sendRPC nid msg = do
    tPState <- asks nodeEnvPState
    pState <- atomically $ readTVar tPState
    liftIO $ print pState
    tNodeSocketPeers <- asks nodeEnvSocketPeers
    nodeSocketPeers <- atomically $ readTVar tNodeSocketPeers
    sockM <- case Map.lookup nid nodeSocketPeers of
      Nothing -> handle (handleFailure tNodeSocketPeers [nid] Nothing) $ liftIO $ do
        (sock, _) <- connectSock host port
        print $ "Nothing: Send message new sock: " ++ show msg
        send sock (S.encode $ SockMsg msg)
        pure $ Just sock
      Just sock -> handle (handleFailure' tNodeSocketPeers nid (Just sock) msg) $ liftIO $ do
        print $ show sock ++ ": Send message: " ++ show msg
        send sock (S.encode $ SockMsg msg)
        pure $ Just sock
    liftIO $ print $ show sockM ++ " " ++ (show nid)
    atomically $ case sockM of
      Nothing -> pure ()
      Just sock -> writeTVar tNodeSocketPeers (Map.insert nid sock nodeSocketPeers)

    where
      (host, port) = nidToHostPort nid

handleFailure' :: (MonadIO m, MonadConc m) => TVar (STM m) (Map NodeId Socket) -> NodeId -> Maybe Socket -> Message StoreCmd -> SomeException -> m (Maybe Socket)
handleFailure' tNodeSocketPeers nid sockM msg e =  case sockM of
  Nothing -> pure Nothing
  Just sock -> do
    print "Handling failure '"
    handle (handleFailure tNodeSocketPeers [nid] Nothing) $ liftIO $ do
      (sock, _) <- connectSock host port
      print $ "Send message new sock: " ++ show msg
      send sock (S.encode $ SockMsg msg)
      pure $ Just sock
  where
    (host, port) = nidToHostPort nid


handleFailure :: (MonadIO m, MonadConc m) => TVar (STM m) (Map NodeId Socket) -> [NodeId] -> Maybe Socket -> SomeException -> m (Maybe Socket)
handleFailure tNodeSocketPeers nids sockM e = case sockM of
  Nothing -> pure Nothing
  Just sock -> do
    liftIO $ print $ "Failed to send RPC: " ++ show e
    nodeSocketPeers <- atomically $ readTVar tNodeSocketPeers
    liftIO $ print $ "Nodes before: " ++ show nodeSocketPeers
    liftIO $ closeSock sock
    atomically $ mapM_ (\nid -> writeTVar tNodeSocketPeers (Map.delete nid nodeSocketPeers)) nids
    nodeSocketPeers' <- atomically $ readTVar tNodeSocketPeers
    liftIO $ print $ "Nodes after: " ++ show nodeSocketPeers'
    pure Nothing


instance (MonadIO m, MonadConc m) => RaftRecvRPC (NodeEnvT m) StoreCmd where
  receiveRPC = do
    msgQueue <- asks nodeEnvMsgQueue
    msg <- atomically $ readTChan msgQueue
    liftIO $ print $ "Msg: " ++ show msg
    pure msg


--------------------------------------------------------------------------------

nidToHostPort :: ByteString -> (HostName, ServiceName)
nidToHostPort bs =
  case BS.split W8._colon bs of
    [host,port] -> (toS host, toS port)
    _ -> panic "nidToHostPort: invalid node id"

-- | Recursively accept a connection.
-- It keeps trying to accept connections even when a node dies
recAcceptFork
  :: Socket
  -> NodeId
  -> TVar (STM IO) (Map NodeId Socket)
  -> TChan (STM IO) (Message StoreCmd)
  -> IO ()
recAcceptFork nodeSock selfNid tNodeSocketPeers msgQueue =
  void $ fork $ void $ acceptFork nodeSock $ \(sock', sockAddr') ->
    handle (notifyBeforeCrashing nodeSock selfNid tNodeSocketPeers msgQueue) $
      forever $ do
        recvSock <- NSB.recv sock' 4096
        print $ "Received sock. Before decoding: " ++ show recvSock
        let eMsgE = S.decode recvSock
        case eMsgE of
          Left err -> panic $ toS err
          Right (SockClose nid) -> do
            nodeSocketPeers <- atomically $ readTVar tNodeSocketPeers
            pure ()
            --case Map.lookup nid nodeSocketPeers of
              --Nothing -> pure ()
              --Just sock -> do
                --closeSock sock
                --atomically $ writeTVar tNodeSocketPeers (Map.delete nid nodeSocketPeers)
          Right (SockMsg msg) ->
            atomically $ writeTChan msgQueue msg
  where
    notifyBeforeCrashing
      :: Socket
      -> NodeId
      -> TVar (STM IO) (Map NodeId Socket)
      -> TChan (STM IO) (Message StoreCmd)
      -> SomeException
      -> IO ()
    notifyBeforeCrashing nodeSock selfNid tNodeSocketPeers msgQueue e = do
      print "I'M CRASHING!"
      --nodeSocketPeers <- atomically $ readTVar tNodeSocketPeers
      --mapM_ (\sock -> do
        --send sock (S.encode (SockClose selfNid :: SockMsg StoreCmd))
        --pure Nothing) nodeSocketPeers
      --threadDelay 10000000
      recAcceptFork nodeSock selfNid tNodeSocketPeers msgQueue
      --throw e


main :: IO ()
main = do
    (nid:nids) <- (toS <$>) <$> getArgs
    let (host, port) = nidToHostPort (toS nid)
    let peers = Set.fromList nids
    let nodeConfig = NodeConfig
          { configNodeId = toS nid
          , configNodeIds = peers
          , configElectionTimeout = (5000000, 15000000)
          , configHeartbeatTimeout = 1000000
          }
    nodeEnv <- initNodeEnv host port peers
    runNodeEnvT nodeEnv $ do
      nodeSock <- asks nodeEnvSocket
      selfNid <- asks nodeEnvNodeId
      msgQueue <- asks nodeEnvMsgQueue
      tNodeSocketPeers <- asks nodeEnvSocketPeers
      liftIO $ recAcceptFork nodeSock selfNid tNodeSocketPeers msgQueue
      runRaftNode nodeConfig (mempty :: Store) print
  where
    newSock host port = do
      (sock, _) <- bindSock (Host host) port
      listenSock sock 2048
      pure sock

    initNodeEnv :: HostName -> ServiceName -> NodeIds -> IO (NodeEnv IO)
    initNodeEnv host port nids = do
      nodeSocket <- newSock host port
      socketPeersTVar <- atomically (newTVar mempty)
      storeTVar <- atomically (newTVar mempty)
      pstateTVar <- atomically (newTVar initPersistentState)
      msgQueue <- atomically newTChan
      pure NodeEnv
        { nodeEnvStore = storeTVar
        , nodeEnvPState = pstateTVar
        , nodeEnvPeers = nids
        , nodeEnvNodeId = toS host <> ":" <> toS port
        , nodeEnvSocket = nodeSocket
        , nodeEnvSocketPeers = socketPeersTVar
        , nodeEnvMsgQueue = msgQueue
        }



