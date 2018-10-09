{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}

module TestDejaFu where

import Protolude hiding
  ( MVar, putMVar, takeMVar, newMVar, newEmptyMVar, readMVar
  , atomically, STM, Chan, readTVar, writeTVar
  , newChan, writeChan, readChan
  , threadDelay, killThread
  )

import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Sequence (Seq(..), (<|))
import qualified Data.Sequence as Seq
import Control.Monad.Reader
import Control.Monad.Catch
import Control.Concurrent.Classy hiding (check)
import Control.Concurrent.Classy.STM.TVar
import Data.Functor (void)
import Test.DejaFu hiding (MemType(..), check)
import Test.DejaFu.SCT
import Test.DejaFu.Conc hiding (Stop)
import Test.Tasty.DejaFu
import Test.Tasty
import TestUtils

import Numeric.Natural

import Raft.Action
import Raft.Config
import Raft.Event hiding (Message)
import Raft.Handle (handleEvent)
import Raft.Log
import Raft.Monad
import Raft.NodeState
import Raft.Persistent
import Raft.RPC
import Raft.Types
import Raft

data StoreCmd = Set Text Natural | Incr Text
  deriving (Show)

type Store = Map Text Natural

initStore :: Store
initStore = mempty

instance RaftStateMachine Store StoreCmd where
  applyCommittedLogEntry store cmd =
    case cmd of
      Set x n -> Map.insert x n store
      Incr x -> Map.adjust succ x store

type NodeChanMap m = Map NodeId (Chan m (Message StoreCmd))

data TestEnv m = TestEnv
  { store :: TVar (STM m) Store
  , pstate :: TVar (STM m) (PersistentState StoreCmd)
  , nodes :: NodeChanMap m
  , nid :: NodeId
  }

newtype TestEnvT m a = TestEnvT { unTestEnvT :: ReaderT (TestEnv m) m a }
  deriving (Functor, Applicative, Monad, MonadReader (TestEnv m), Alternative, MonadPlus)

runTestEnvT :: TestEnv m -> TestEnvT m a -> m a
runTestEnvT testEnv = flip runReaderT testEnv . unTestEnvT

instance MonadTrans TestEnvT where
  lift = TestEnvT . lift

deriving instance MonadThrow m => MonadThrow (TestEnvT m)
deriving instance MonadCatch m => MonadCatch (TestEnvT m)
deriving instance MonadSTM m => MonadSTM (TestEnvT m)
deriving instance MonadMask m => MonadMask (TestEnvT m)
deriving instance MonadConc m => MonadConc (TestEnvT m)

instance MonadConc m => RaftPersist (TestEnvT m) StoreCmd where
  savePersistentState pstate' = asks pstate >>= atomically . flip writeTVar pstate'
  loadPersistentState = asks pstate >>= atomically . readTVar

instance MonadConc m => RaftSendRPC (TestEnvT m) StoreCmd where
  sendRPC nid msg = do
    nodeChanMap <- asks nodes
    case Map.lookup nid nodeChanMap of
      Nothing -> panic $ toS $ "SendRPC: " ++ show nid ++ " .Wtf bro"
      Just c -> lift $ writeChan c msg

instance MonadConc m => RaftRecvRPC (TestEnvT m) StoreCmd where
  receiveRPC = do
    myNodeId <- asks nid
    nodeChanMap <- asks nodes
    cmd <- case Map.lookup myNodeId nodeChanMap of
      Nothing -> panic $ toS $ "RecvRPC: " ++ show myNodeId ++ " .Wtf bro"
      Just c -> lift $ readChan c
    pure cmd

mkNodeTestEnv :: MonadConc m => NodeId -> NodeChanMap m -> m (TestEnv m)
mkNodeTestEnv nid chanMap = do
  newStore <- atomically $ newTVar initStore
  newPersistentState <- atomically $ newTVar initPersistentState
  pure TestEnv
    { store = newStore
    , pstate = newPersistentState
    , nodes = chanMap
    , nid = nid
    }

--test_auto :: TestTree
--test_auto = testAuto $ do

--testauto :: IO [(Either Failure (), Trace)]
--testauto =
  --runSCT defaultWay defaultMemType $ do

  --nodeChans <- replicateM 2 newChan
  --let nodeChanMap = Map.fromList $ zip [node0, node1] nodeChans

  --testEnv0 <- mkNodeTestEnv node0 nodeChanMap
  --testEnv1 <- mkNodeTestEnv node1 nodeChanMap
  --let testConfig0' = testConfig0 { configNodeIds = Set.fromList [node0, node1] }
  --let testConfig1' = testConfig1 { configNodeIds = Set.fromList [node0, node1] }

  --fork $ runTestEnvT (DT.trace "TEST 0" testEnv0) (runRaftNode testConfig0' initStore)
  --runTestEnvT testEnv1 (runRaftNode testConfig1' initStore)

