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
import Numeric.Natural

import Raft
import Raft.Config
import Raft.Persistent
import Raft.Types

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

instance MonadIO m => RaftSendRPC (NodeEnvT m) StoreCmd where
  sendRPC nid msg =
      liftIO $ handle handleFailure $
        connect host port $ \(sock,_) ->
          send sock (S.encode msg)
    where
      (host,port) = nidToHostPort nid

      handleFailure :: SomeException -> IO ()
      handleFailure e = putStrLn $ "Failed to send RPC: " ++ show e


instance MonadIO m => RaftRecvRPC (NodeEnvT m) StoreCmd where
  receiveRPC = do
    nodeSock <- asks nodeEnvSocket
    liftIO $
      accept nodeSock $ \(sock,sockAddr) -> do
        eMsg <- fmap S.decode <$> recv sock 4096
        case eMsg of
          Nothing -> panic ("Socket closed on " <> show sockAddr)
          Just (Left err) -> panic ("Failed to decode msg: " <> toS err)
          Just (Right msg) -> pure msg

--------------------------------------------------------------------------------

nidToHostPort :: ByteString -> (HostName, ServiceName)
nidToHostPort bs =
  case BS.split W8._colon bs of
    [host,port] -> (toS host, toS port)
    _ -> panic "nidToHostPort: invalid node id"

main :: IO ()
main = do
    (nid:nids) <- map toS <$> getArgs
    let (host, port) = nidToHostPort (toS nid)
    let peers = Set.fromList nids
    let nodeConfig = NodeConfig
          { configNodeId = toS nid
          , configNodeIds = peers
          , configElectionTimeout = (1500000, 3000000)
          , configHeartbeatTimeout = 200000
          }
    nodeEnv <- initNodeEnv host port peers
    runNodeEnvT nodeEnv $
      runRaftNode nodeConfig (mempty :: Store) print
    pure ()
  where
    newSock host port = do
      (sock, _) <- bindSock (Host host) port
      listenSock sock 2048
      pure sock

    initNodeEnv :: HostName -> ServiceName -> NodeIds -> IO (NodeEnv IO)
    initNodeEnv host port nids = do
      nodeSocket <- newSock host port
      storeTVar <- atomically (newTVar mempty)
      pstateTVar <- atomically (newTVar initPersistentState)
      pure NodeEnv
        { nodeEnvStore = storeTVar
        , nodeEnvPState = pstateTVar
        , nodeEnvPeers = nids
        , nodeEnvNodeId = toS host <> ":" <> toS port
        , nodeEnvSocket = nodeSocket
        }
