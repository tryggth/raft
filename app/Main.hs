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
  , lift
  )

import Control.Concurrent.Classy hiding (catch)
import Control.Monad.Catch
import Control.Monad.Trans.Class

import Data.Sequence ((><))
import qualified Data.Map as Map
import qualified Data.List as L
import qualified Data.Set as Set
import qualified Data.Sequence as Seq
import qualified Data.Serialize as S
import qualified Network.Simple.TCP as NS
import Network.Simple.TCP
import qualified Network.Socket as N
import qualified Network.Socket.ByteString as NSB
import Numeric.Natural
import System.Console.Repline
import System.Console.Haskeline.MonadException hiding (handle)
import Text.Read hiding (lift)
import System.Random
import qualified System.Directory as Directory

import qualified Examples.Raft.Socket.Client as RS
import qualified Examples.Raft.Socket.Node as RS
import Examples.Raft.Socket.Node
import qualified Examples.Raft.Socket.Common as RS

import Examples.Raft.FileStore
import Raft

------------------------------
-- State Machine & Commands --
------------------------------

-- State machine with two basic operations: set a variable to a value and
-- increment value

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

--------------------
-- Raft instances --
--------------------

data NodeEnv sm v = NodeEnv
  { nEnvStore :: TVar (STM IO) sm
  , nEnvNodeId :: NodeId
  }

newtype RaftExampleM sm v a = RaftExampleM { unRaftExampleM :: ReaderT (NodeEnv sm v) (RaftSocketT v (RaftFileStoreT IO)) a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader (NodeEnv sm v), Alternative, MonadPlus)

deriving instance MonadThrow (RaftExampleM sm v)
deriving instance MonadCatch (RaftExampleM sm v)
deriving instance MonadMask (RaftExampleM sm v)
deriving instance MonadConc (RaftExampleM sm v)

runRaftExampleM :: NodeEnv sm v -> NodeSocketEnv v -> NodeFileStoreEnv -> RaftExampleM sm v a -> IO a
runRaftExampleM nodeEnv nodeSocketEnv nodeFileStoreEnv raftExampleM =
  runReaderT (unRaftFileStoreT $
    runReaderT (unRaftSocketT $
      runReaderT (unRaftExampleM raftExampleM) nodeEnv) nodeSocketEnv)
        nodeFileStoreEnv

instance RaftSendClient (RaftExampleM Store StoreCmd) Store where
  sendClient cid msg = (RaftExampleM . lift) $ sendClient cid msg

instance RaftRecvClient (RaftExampleM Store StoreCmd) StoreCmd where
  receiveClient = RaftExampleM $ lift receiveClient

instance RaftSendRPC (RaftExampleM Store StoreCmd) StoreCmd where
  sendRPC nid msg = (RaftExampleM . lift) $ sendRPC nid msg

instance RaftRecvRPC (RaftExampleM Store StoreCmd) StoreCmd where
  receiveRPC = RaftExampleM $ lift receiveRPC

instance RaftWriteLog (RaftExampleM Store StoreCmd) StoreCmd where
  type RaftWriteLogError (RaftExampleM Store StoreCmd) = NodeEnvError
  writeLogEntries entries = RaftExampleM $ lift $ RaftSocketT (lift $ writeLogEntries entries)

instance RaftPersist (RaftExampleM Store StoreCmd) where
  type RaftPersistError (RaftExampleM Store StoreCmd) = NodeEnvError
  writePersistentState ps = RaftExampleM $ lift $ RaftSocketT (lift $ writePersistentState ps)
  readPersistentState = RaftExampleM $ lift $ RaftSocketT (lift $ readPersistentState)

instance RaftReadLog (RaftExampleM Store StoreCmd) StoreCmd where
  type RaftReadLogError (RaftExampleM Store StoreCmd) = NodeEnvError
  readLogEntry idx = RaftExampleM $ lift $ RaftSocketT (lift $ readLogEntry idx)
  readLastLogEntry = RaftExampleM $ lift $ RaftSocketT (lift readLastLogEntry)

instance RaftDeleteLog (RaftExampleM Store StoreCmd) StoreCmd where
  type RaftDeleteLogError (RaftExampleM Store StoreCmd) = NodeEnvError
  deleteLogEntriesFrom idx = RaftExampleM $ lift $ RaftSocketT (lift $ deleteLogEntriesFrom idx)

--------------------
-- Client console --
--------------------

-- Clients interact with the nodes from a terminal:
-- Accepted operations are:
-- - addNode <host:port>
--      Add nodeId to the set of nodeIds that the client will communicate with
-- - getNodes
--      Return the node ids that the client is aware of
-- - read
--      Return the state of the leader
-- - set <var> <val>
--      Set variable to a specific value
-- - incr <var>
--      Increment the value of a variable

data ConsoleState = ConsoleState
  { csNodeIds :: NodeIds -- ^ Set of node ids that the client is aware of
  , csSocket :: Socket -- ^ Client's socket
  , csHost :: HostName -- ^ Client's host
  , csPort :: ServiceName -- ^ Client's port
  , csLeaderId :: TVar (STM IO) (Maybe LeaderId) -- ^ Node id of the leader in the Raft network
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

-- | Evaluate and handle each line user inputs
handleConsoleCmd :: [Char] -> ConsoleM ()
handleConsoleCmd input = do
  nids <- gets csNodeIds
  clientSocket <- gets csSocket
  clientHost <- gets csHost
  clientPort <- gets csPort
  leaderIdT <-  gets csLeaderId
  leaderIdM <- liftIO $ atomically $ readTVar leaderIdT
  let clientSocketEnv = RS.ClientSocketEnv clientPort clientHost clientSocket
  case L.words input of
    ["addNode", nid] -> modify (\st -> st { csNodeIds = Set.insert (toS nid) (csNodeIds st) })
    ["getNodes"] -> print nids
    ["read"] -> if nids == Set.empty
      then putText "Please add some nodes to query first. Eg. `addNode localhost:3001`"
      else do
        respE <- liftIO $ RS.runRaftSocketClientM clientSocketEnv $ case leaderIdM of
          Nothing -> RS.sendReadRndNode (Proxy :: Proxy StoreCmd) nids
          Just (LeaderId nid) -> RS.sendRead (Proxy :: Proxy StoreCmd) nid
        handleClientResponseE input respE leaderIdT
    ["incr", cmd] -> do
      respE <- liftIO $ RS.runRaftSocketClientM clientSocketEnv $ case leaderIdM of
        Nothing -> RS.sendWriteRndNode (Incr (toS cmd)) nids
        Just (LeaderId nid) -> RS.sendWrite (Incr (toS cmd)) nid
      handleClientResponseE input respE leaderIdT
    ["set", var, val] -> do
      respE <- liftIO $ RS.runRaftSocketClientM clientSocketEnv $ case leaderIdM of
        Nothing -> RS.sendWriteRndNode (Set (toS var) (read val)) nids
        Just (LeaderId nid) -> RS.sendWrite (Set (toS var) (read val)) nid
      handleClientResponseE input respE leaderIdT
    _ -> print "Invalid command. Press <TAB> to see valid commands"

  where
    handleClientResponseE :: [Char] -> Either [Char] (ClientResponse Store) -> TVar (STM IO) (Maybe LeaderId) -> ConsoleM ()
    handleClientResponseE input eMsgE leaderIdT =
      case eMsgE of
        Left err -> panic $ toS err
        Right (ClientRedirectResponse (ClientRedirResp leader)) ->
          case leader of
            NoLeader -> do
              putText "Sorry, the system doesn't have a leader at the moment"
              liftIO $ atomically $ writeTVar leaderIdT Nothing
            -- If the message was not sent to the leader, that node will
            -- point to the current leader
            CurrentLeader lid -> do
              putText $ "New leader found: " <> show lid
              liftIO $ atomically $ writeTVar leaderIdT (Just lid)
              handleConsoleCmd input
        Right (ClientReadResponse (ClientReadResp sm)) -> putText $ "Received sm: " <> show sm
        Right (ClientWriteResponse writeResp) -> print writeResp


main :: IO ()
main = do
    args <- (toS <$>) <$> getArgs
    case args of
      ["client"] -> clientMainHandler
      (nid:nids) -> do
        removeExampleFiles nid
        createExampleFiles nid

        nSocketEnv <- initSocketEnv nid
        nPersistentEnv <- initRaftFileStoreEnv nid
        nEnv <- initNodeEnv nid
        runRaftExampleM nEnv nSocketEnv nPersistentEnv $ do
          let allNodeIds = Set.fromList (nid : nids)
          let nodeConfig = NodeConfig
                            { configNodeId = toS nid
                            , configNodeIds = allNodeIds
                            , configElectionTimeout = (5000000, 15000000)
                            , configHeartbeatTimeout = 1000000
                            }
          RaftExampleM $ lift acceptForkNode :: RaftExampleM Store StoreCmd ()
          electionTimerSeed <- liftIO randomIO
          runRaftNode nodeConfig LogStdout electionTimerSeed (mempty :: Store)
  where
    initPersistentFile :: NodeId -> IO ()
    initPersistentFile nid = do
      psPath <- persistentFile nid
      writeFile psPath (toS $ S.encode initPersistentState)

    persistentFile :: NodeId -> IO FilePath
    persistentFile nid = do
      tmpDir <- Directory.getTemporaryDirectory
      pure $ tmpDir ++ "/" ++ toS nid ++ "/" ++ "persistent"

    initLogsFile :: NodeId -> IO ()
    initLogsFile nid = do
      logsPath <- logsFile nid
      writeFile logsPath (toS $ S.encode (mempty :: Entries StoreCmd))

    logsFile :: NodeId -> IO FilePath
    logsFile nid = do
      tmpDir <- Directory.getTemporaryDirectory
      pure (tmpDir ++ "/" ++ toS nid ++ "/" ++ "logs")

    createExampleFiles :: NodeId -> IO ()
    createExampleFiles nid = void $ do
      tmpDir <- Directory.getTemporaryDirectory
      Directory.createDirectory (tmpDir ++ "/" ++ toS nid)
      initPersistentFile nid
      initLogsFile nid

    removeExampleFiles :: NodeId -> IO ()
    removeExampleFiles nid = handle (const (pure ()) :: SomeException -> IO ()) $ do
      tmpDir <- Directory.getTemporaryDirectory
      Directory.removeDirectoryRecursive (tmpDir ++ "/" ++ toS nid)


    initNodeEnv :: NodeId -> IO (NodeEnv Store StoreCmd)
    initNodeEnv nid = do
      let (host, port) = RS.nidToHostPort (toS nid)
      storeTVar <- atomically (newTVar mempty)
      pure NodeEnv
        { nEnvStore = storeTVar
        , nEnvNodeId = toS host <> ":" <> toS port
        }

    initRaftFileStoreEnv :: NodeId -> IO NodeFileStoreEnv
    initRaftFileStoreEnv nid = do
      psPath <- persistentFile nid
      psLogs <- logsFile nid
      pure NodeFileStoreEnv
            { nfsPersistentState = psPath
            , nfsLogEntries = psLogs
            }

    initSocketEnv :: NodeId -> IO (NodeSocketEnv v)
    initSocketEnv nid = do
      let (host, port) = RS.nidToHostPort (toS nid)
      nodeSocket <- newSock host port
      socketPeersTVar <- atomically (newTVar mempty)
      msgQueue <- atomically newTChan
      clientReqQueue <- atomically newTChan
      pure NodeSocketEnv
            { nsPeers = socketPeersTVar
            , nsSocket = nodeSocket
            , nsMsgQueue = msgQueue
            , nsClientReqQueue = clientReqQueue
            }

    clientMainHandler :: IO ()
    clientMainHandler = do
      clientPort <- getFreePort
      clientSocket <- RS.newSock "localhost" clientPort
      leaderIdT <- atomically (newTVar Nothing)
      let initClientState = ConsoleState
                                  { csNodeIds = mempty
                                  , csSocket = clientSocket
                                  , csHost = "localhost"
                                  , csPort = clientPort
                                  , csLeaderId = leaderIdT
                                  }
      runConsoleT initClientState $
        evalRepl (pure ">>> ") (unConsoleM . handleConsoleCmd) [] Nothing (Word completer) (pure ())

    runConsoleT :: Monad m => ConsoleState -> ConsoleT m a -> m a
    runConsoleT consoleState = flip evalStateT consoleState . unConsoleT

    -- | Get a free port number.
    getFreePort :: IO ServiceName
    getFreePort = do
      sock <- N.socket N.AF_INET N.Stream N.defaultProtocol
      N.bind sock (N.SockAddrInet N.aNY_PORT N.iNADDR_ANY)
      port <- N.socketPort sock
      N.close sock
      pure $ show port

    -- Tab Completion: return a completion for partial words entered
    completer :: Monad m => WordCompleter m
    completer n = do
      let cmds = ["addNode <host:port>", "getNodes", "incr <var>", "set <var> <val>"]
      return $ filter (isPrefixOf n) cmds
