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
  , catch, handle, takeWhile, takeWhile1, (<|>)
  )

import Control.Concurrent.Classy hiding (catch)
import Control.Monad.STM.Class

import Control.Monad.Catch
import qualified Data.ByteString as BS
import qualified Data.Map as Map
import qualified Data.List as L
import qualified Data.Set as Set
import qualified Data.Sequence as Seq
import qualified Data.Serialize as S
import qualified Data.Word8 as W8
import qualified Network.Simple.TCP as NS
import qualified Data.Text as T
import Network.Simple.TCP
import qualified Network.Socket as N
import qualified Network.Socket.ByteString as NSB
import Numeric.Natural
import System.Random
import System.Console.Repline
import System.Console.Haskeline.MonadException hiding (handle)
import Text.Read

import Raft
import Raft.Config
import Raft.Persistent
import Raft.Types
import Raft.Event
import Raft.RPC
import Raft.Client
import Raft.Monad hiding (send)
import Raft.NodeState

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

instance StateMachine Store StoreCmd where
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
  , nodeEnvMsgQueue :: TChan (STM m) (RPCMessage StoreCmd)
  , nodeEnvClientSockets :: TVar (STM m) (Map ClientId Socket)
  , nodeEnvClientReqQueue :: TChan (STM m) (ClientRequest StoreCmd)
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


instance (MonadIO m, MonadConc m) => RaftSendClient (NodeEnvT m) Store where
  sendClient clientId@(ClientId nid) msg = do
    liftIO $ print clientId
    liftIO $ print msg
    selfNid <- asks nodeEnvNodeId
    let (cHost, cPort) = nidToHostPort (toS nid)
    connect cHost cPort $ \(cSock, _cSockAddr) -> do
      print ("Sending client read response from node: " ++ show selfNid ++ " to client: "++ show (cHost, cPort))
      send cSock (S.encode msg)

instance (MonadConc m, MonadIO m) => RaftRecvClient (NodeEnvT m) StoreCmd where
  receiveClient = do
    cReq <- atomically . readTChan =<< asks nodeEnvClientReqQueue
    selfNid <- asks nodeEnvNodeId
    liftIO $ print $ "Received Client msg: " ++ show cReq ++ " on nodeId: " ++ show selfNid
    pure cReq

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
          NS.send sock (S.encode $ RPCMessageEvent msg)
          pure $ Just sock
        Just sock -> handle (retryConnection tNodeSocketPeers nid (Just sock) msg) $ liftIO $ do
          NS.send sock (S.encode $ RPCMessageEvent msg)
          pure $ Just sock
      atomically $ case sockM of
        Nothing -> pure ()
        Just sock -> writeTVar tNodeSocketPeers (Map.insert nid sock nodeSocketPeers)
    where
      (host, port) = nidToHostPort nid

-- | Handles connections failures by first trying to reconnect
retryConnection :: (MonadIO m, MonadConc m) => TVar (STM m) (Map NodeId Socket) -> NodeId -> Maybe Socket -> RPCMessage StoreCmd -> SomeException -> m (Maybe Socket)
retryConnection tNodeSocketPeers nid sockM msg e =  case sockM of
  Nothing -> pure Nothing
  Just sock ->
    handle (handleFailure tNodeSocketPeers [nid] Nothing) $ liftIO $ do
      print $ "Retrying connection to" ++ show nid
      (sock, _) <- connectSock host port
      print $ "Successful retry. New connection. Send RPC: " ++ show msg
      NS.send sock (S.encode $ RPCMessageEvent msg)
      pure $ Just sock
  where
    (host, port) = nidToHostPort nid


handleFailure :: (MonadIO m, MonadConc m) => TVar (STM m) (Map NodeId Socket) -> [NodeId] -> Maybe Socket -> SomeException -> m (Maybe Socket)
handleFailure tNodeSocketPeers nids sockM e = case sockM of
  Nothing -> pure Nothing
  Just sock -> do
    liftIO $ print $ "Failed to send RPC: " ++ show e
    nodeSocketPeers <- atomically $ readTVar tNodeSocketPeers
    liftIO $ closeSock sock
    atomically $ mapM_ (\nid -> writeTVar tNodeSocketPeers (Map.delete nid nodeSocketPeers)) nids
    pure Nothing

instance (MonadIO m, MonadConc m) => RaftRecvRPC (NodeEnvT m) StoreCmd where
  receiveRPC = do
    msgQueue <- asks nodeEnvMsgQueue
    selfNid <- asks nodeEnvNodeId
    msg <- atomically $ readTChan msgQueue
    pure msg

--------------------------------------------------------------------------------

nidToHostPort :: ByteString -> (HostName, ServiceName)
nidToHostPort bs =
  case BS.split W8._colon bs of
    [host,port] -> (toS host, toS port)
    _ -> panic "nidToHostPort: invalid node id"


-- Randomly select a node from a set of nodes a send a message to it
selectRndNode :: NodeIds -> IO NodeId
selectRndNode nids =
  (Set.toList nids L.!!) <$> randomRIO (0, length nids - 1)

sendReadRndNode :: ServiceName -> NodeIds -> IO ()
sendReadRndNode clientPort nids =
  selectRndNode nids >>= sendRead clientPort

sendWriteRndNode :: StoreCmd -> ServiceName -> NodeIds -> IO ()
sendWriteRndNode cmd clientPort nids =
  selectRndNode nids >>= sendWrite cmd clientPort

sendRead :: ServiceName -> NodeId -> IO ()
sendRead clientPort nid = do
  let (host, port) = nidToHostPort (toS nid)
  connect host port $ \(sock, sockAddr) -> do
    print ("Sending client read request from clientPort: " ++ toS clientPort ++ " to node: "++ show (host, port))
    send sock (S.encode (ClientRequestEvent (ClientRequest (ClientId (toS $ "localhost:" ++ toS clientPort)) ClientReadReq :: ClientRequest StoreCmd)))

sendWrite :: StoreCmd -> ServiceName -> NodeId -> IO ()
sendWrite cmd clientPort nid = do
  let (host, port) = nidToHostPort (toS nid)
  connect host port $ \(sock, sockAddr) -> do
    print ("Sending client write request from clientPort: " ++ toS clientPort ++ " to node: "++ show (host, port))
    send sock (S.encode
      (ClientRequestEvent (ClientRequest (ClientId (toS $ "localhost:" ++ toS clientPort)) (ClientWriteReq cmd))))

--------------------------------------------------------------------------------

data ConsoleState = ConsoleState
  { csNodeIds :: NodeIds
  , csSocket :: Socket
  , csPort :: ServiceName
  , csLeaderId :: TVar (STM IO) (Maybe LeaderId)
  }

newtype ConsoleT m a = ConsoleT
  { unConsoleT :: StateT ConsoleState m a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadState ConsoleState)

newtype ConsoleM a = ConsoleM
  { unConsoleM :: HaskelineT (ConsoleT IO) a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadState ConsoleState)

instance MonadException m => MonadException (ConsoleT m) where
  controlIO f =
    ConsoleT $ StateT $ \s ->
      controlIO $ \(RunIO run) ->
        let run' = RunIO (fmap (ConsoleT . StateT . const) . run . flip runStateT s . unConsoleT)
        in flip runStateT s . unConsoleT <$> f run'

-- Evaluation : handle each line user inputs
handleConsoleCmd :: [Char] -> ConsoleM ()
handleConsoleCmd input = do
  nids <- gets csNodeIds
  clientSocket <- gets csSocket
  clientPort <- gets csPort
  leaderIdT <-  gets csLeaderId
  leaderIdM <- liftIO $ atomically $ readTVar leaderIdT
  case L.words input of
    ["addNode", nid] -> modify (\st -> st { csNodeIds = Set.insert (toS nid) (csNodeIds st) })
    ["getNodes"] -> liftIO $ print nids
    ["read"] ->
      if nids == Set.empty
        then liftIO $ print "Please add some nodes to query first. Eg. `addNode localhost:3001`"
        else do
          liftIO $ case leaderIdM of
            Nothing -> sendReadRndNode clientPort nids
            Just (LeaderId nid) -> sendRead clientPort nid
          liftIO $ acceptClientConnections clientPort clientSocket nids leaderIdT
    ["incr", cmd] -> do
      liftIO $ case leaderIdM of
        Nothing -> sendWriteRndNode (Incr (toS cmd)) clientPort nids
        Just (LeaderId nid) -> sendWrite (Incr (toS cmd)) clientPort nid
      liftIO $ acceptClientConnections clientPort clientSocket nids leaderIdT
    ["set", var, val] -> do
      liftIO $ case leaderIdM of
        Nothing -> sendWriteRndNode (Set (toS var) (read val)) clientPort nids
        Just (LeaderId nid) -> sendWrite (Set (toS var) (read val)) clientPort nid
      liftIO $ acceptClientConnections clientPort clientSocket nids leaderIdT
    _ -> print "Invalid command. Press <TAB> to see valid commands"

acceptClientConnections :: HostName -> Socket -> NodeIds -> TVar (STM IO) (Maybe LeaderId) -> IO ()
acceptClientConnections clientPort clientSocket nodes leaderIdT =
  void $ fork $ void $ accept clientSocket $ \(sock', sockAddr') -> do
      recvSock <- recv sock' 4096
      print $ "Client received message on server sock: " ++ show sock'
      let Just eMsgE = (S.decode <$> recvSock) :: Maybe (Either [Char] (ClientResponse Store))
      case eMsgE of
        Left err -> panic $ toS err
        Right (ClientRedirectResponse (ClientRedirResp leader)) ->
          case leader of
            -- If there is no leader, we give up
            NoLeader -> do
              print $ "Sorry, the system doesn't have a leader at the moment"
              atomically $ writeTVar leaderIdT Nothing
            -- If the message was not sent to the leader, that node will
            -- point to the current leader
            CurrentLeader lid -> do
              print $ "New leader found. Please, resend request to leader: " ++ show lid
              atomically $ writeTVar leaderIdT (Just lid)
        Right (ClientReadResponse (ClientReadResp sm)) ->  print $ "Received sm: " ++ show sm
        Right (ClientWriteResponse writeResp) -> print writeResp

-- Tab Completion: return a completion for partial words entered
completer :: Monad m => WordCompleter m
completer n = do
  let cmds = ["addNode <host:port>", "getNodes", "incr <var>", "set <var> <val>"]
  return $ filter (isPrefixOf n) cmds

runConsoleT :: Monad m => ConsoleState -> ConsoleT m a -> m a
runConsoleT consoleState = flip evalStateT consoleState . unConsoleT

main :: IO ()
main = do
    args <- (toS <$>) <$> getArgs
    case args of
      ["client"] -> do
        clientPort <- getFreePort
        clientSocket <- newSock "localhost" clientPort
        leaderIdT <- atomically (newTVar Nothing)
        let initClientState = ConsoleState {
            csNodeIds = mempty, csSocket = clientSocket, csPort = clientPort, csLeaderId = leaderIdT }
        runConsoleT initClientState $
          evalRepl ">>> " (unConsoleM . handleConsoleCmd) [] (Word completer) (pure ())
      (nid:nids) -> do
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
          clientSockets <- asks nodeEnvClientSockets
          clientReqQueue <- asks nodeEnvClientReqQueue
          tNodeSocketPeers <- asks nodeEnvSocketPeers
          liftIO $ acceptForkNode nodeSock selfNid tNodeSocketPeers msgQueue clientSockets clientReqQueue
          electionTimerSeed <- liftIO randomIO
          runRaftNode nodeConfig electionTimerSeed (mempty :: Store) print
  where
    -- | Recursively accept a connection.
    -- It keeps trying to accept connections even when a node dies
    acceptForkNode
      :: Socket
      -> NodeId
      -> TVar (STM IO) (Map NodeId Socket)
      -> TChan (STM IO) (RPCMessage StoreCmd)
      -> TVar (STM IO) (Map ClientId Socket)
      -> TChan (STM IO) (ClientRequest StoreCmd)
      -> IO ()
    acceptForkNode nodeSock selfNid tNodeSocketPeers msgQueue clientSockets clientReqQueue =
      void $ fork $ void $ forever $ acceptFork nodeSock $ \(sock', sockAddr') ->
        handle (handleRecAcceptFork nodeSock selfNid) $
          forever $ do
            recvSock <- NSB.recv sock' 4096
            case S.decode recvSock of
              Left err -> panic $ toS err
              Right (ClientRequestEvent req@(ClientRequest cid _)) -> do
                print $ "Client request!" ++ show req
                atomically $ writeTChan clientReqQueue req
              Right (RPCMessageEvent msg) ->
                atomically $ writeTChan msgQueue msg

        where
          handleRecAcceptFork
            :: Socket
            -> NodeId
            -> SomeException
            -> IO ()
          handleRecAcceptFork nodeSock selfNid e
            = print $ "HandleRecAcceptFork error: " ++ show e

    newSock :: HostName -> ServiceName -> IO Socket
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
      clientSocketsTVar <- atomically (newTVar mempty)
      clientReqQueue <- atomically newTChan
      pure NodeEnv
        { nodeEnvStore = storeTVar
        , nodeEnvPState = pstateTVar
        , nodeEnvPeers = nids
        , nodeEnvNodeId = toS host <> ":" <> toS port
        , nodeEnvSocket = nodeSocket
        , nodeEnvSocketPeers = socketPeersTVar
        , nodeEnvMsgQueue = msgQueue
        , nodeEnvClientSockets = clientSocketsTVar
        , nodeEnvClientReqQueue = clientReqQueue
        }

    -- | Get a free port number.
    getFreePort :: IO ServiceName
    getFreePort = do
      sock <- N.socket N.AF_INET N.Stream N.defaultProtocol
      N.bind sock (N.SockAddrInet N.aNY_PORT N.iNADDR_ANY)
      port <- N.socketPort sock
      N.close sock
      pure $ show port
