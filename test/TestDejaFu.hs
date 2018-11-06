{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}

module TestDejaFu where

import Protolude hiding
  ( MVar, putMVar, takeMVar, newMVar, newEmptyMVar, readMVar
  , atomically, STM, Chan, readTVar, writeTVar
  , newChan, writeTChan, readTChan
  , threadDelay, killThread
  )

import System.Random
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Sequence (Seq(..), (<|))
import qualified Data.Sequence as Seq
import qualified Data.Serialize as S
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

import Raft

--type Var = ByteString

--data StoreCmd
  -- = Set Var Natural
  -- | Incr Var
  --deriving (Show, Generic)

--instance S.Serialize StoreCmd

--type Store = Map Var Natural

--instance StateMachine Store StoreCmd where
  --applyCommittedLogEntry store cmd =
    --case cmd of
      --Set x n -> Map.insert x n store
      --Incr x -> Map.adjust succ x store

--initStore :: Store
--initStore = mempty

---------------------

--type NodeChanMap m = Map NodeId (TChan (STM m) (RPCMessage StoreCmd))

--type ClientResponsesChan m = TChan (STM m) (ClientResponse Store)
--type ClientRequestsChan m = TChan (STM m) (ClientRequest StoreCmd)

--data TestEnv m = TestEnv
  --{ store :: TVar (STM m) Store
  --, pstate :: TVar (STM m) (PersistentState StoreCmd)
  --, nodes :: NodeChanMap m
  --, nid :: NodeId
  --, clientResps :: ClientResponsesChan m
  --, clientReqs :: ClientRequestsChan m
  --}

--newtype TestEnvT m a = TestEnvT { unTestEnvT :: ReaderT (TestEnv m) m a }
  --deriving (Functor, Applicative, Monad, MonadReader (TestEnv m), Alternative, MonadPlus)

--runTestEnvT :: TestEnv m -> TestEnvT m a -> m a
--runTestEnvT testEnv = flip runReaderT testEnv . unTestEnvT

--instance MonadTrans TestEnvT where
  --lift = TestEnvT . lift

--deriving instance MonadThrow m => MonadThrow (TestEnvT m)
--deriving instance MonadCatch m => MonadCatch (TestEnvT m)
--deriving instance MonadSTM m => MonadSTM (TestEnvT m)
--deriving instance MonadMask m => MonadMask (TestEnvT m)
--deriving instance MonadConc m => MonadConc (TestEnvT m)

--instance MonadConc m => RaftPersist (TestEnvT m) StoreCmd where
  --savePersistentState pstate' = asks pstate >>= atomically . flip writeTVar pstate'
  --loadPersistentState = asks pstate >>= atomically . readTVar

--instance MonadConc m => RaftSendRPC (TestEnvT m) StoreCmd where
  --sendRPC nid msg = do
    --nodeChanMap <- asks nodes
    --case Map.lookup nid nodeChanMap of
      --Nothing -> panic $ toS $ "SendRPC: " ++ show nid ++ " .Wtf bro"
      --Just c -> atomically $ writeTChan c msg

--instance MonadConc m => RaftRecvRPC (TestEnvT m) StoreCmd where
  --receiveRPC = do
    --myNodeId <- asks nid
    --nodeChanMap <- asks nodes
    --case Map.lookup myNodeId nodeChanMap of
      --Nothing -> panic $ toS $ "RecvRPC: " ++ show myNodeId ++ " .Wtf bro"
      --Just c -> atomically $ readTChan c

--instance MonadConc m => RaftSendClient (TestEnvT m) Store where
  --sendClient cid resp = do
    --clientRespsChan <- asks clientResps
    --lift $ atomically $ writeTChan clientRespsChan resp

--instance MonadConc m => RaftRecvClient (TestEnvT m) StoreCmd where
  --receiveClient = atomically . readTChan =<< asks clientReqs

--mkNodeTestEnv :: MonadConc m => NodeId -> NodeChanMap m -> m (TestEnv m)
--mkNodeTestEnv nid nodesChan = do
  --newStore <- atomically $ newTVar initStore
  --clientReqsChan <- atomically newTChan
  --clientRespsChan <- atomically newTChan
  --newPersistentState <- atomically $ newTVar initPersistentState
  --pure TestEnv
    --{ store = newStore
    --, pstate = newPersistentState
    --, nodes = nodesChan
    --, nid = nid
    --, clientResps = clientRespsChan
    --, clientReqs = clientReqsChan
    --}

--test_dejafu :: TestTree
--test_dejafu = testAuto $ do

  --electionTimerSeed <- liftIO randomIO
  --nodeChans <- replicateM 2 (atomically newTChan)
  --let nodeChanMap = Map.fromList $ zip [node0, node1] nodeChans

  --testEnv0 <- mkNodeTestEnv node0 nodeChanMap
  --testEnv1 <- mkNodeTestEnv node1 nodeChanMap
  --let testConfig0' = testConfig0 { configNodeIds = Set.fromList [node0, node1] }
  --let testConfig1' = testConfig1 { configNodeIds = Set.fromList [node0, node1] }

  --fork $ runTestEnvT testEnv0 (runRaftNode testConfig0' electionTimerSeed initStore (const $ pure ()))
  --fork $ runTestEnvT testEnv1 (runRaftNode testConfig1' electionTimerSeed initStore (const $ pure ()))

