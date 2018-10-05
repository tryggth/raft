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
import Data.Sequence (Seq(..), (<|))
import qualified Data.Sequence as Seq
import Control.Monad.Reader
import Control.Monad.Catch
import Control.Concurrent.Classy hiding (check)
import Control.Concurrent.Classy.STM.TVar
import Data.Functor (void)
import Test.DejaFu hiding (MemType(..), check)
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

--data TestSM v = TestSM
  --{ testLogEntries :: Entries v
  --}

--data TestEnv v = TestEnv
  --{ testPS :: TVar (STM Identity) (PersistentState v)
  --, testSM :: Entries v
  --}

--initialTestEnvT :: TestEnvM Int ()
--initialTestEnvT = undefined

--newtype TestEnvT v a = TestEnvM { unTestEnvM :: ReaderT (TestEnv v) IO a }
  --deriving (Functor, Applicative, Monad, MonadReader (TestEnv v))

--instance RaftStateMachine (Entries Int) Int where
  --applyLogEntry sm v = appendLogEntry v sm

--instance RaftRPC (TestEnvT Int) Int where
  --sendRPC = undefined
  --receiveRPC = undefined
  --broadcastRPC = undefined

--instance RaftPersist (TestEnvT Int) Int where
  --savePersistentState ps = undefined
  --loadPersistentState = undefined
  --do
    -- <- ask
    --psTVar <- atomically $
      --newTVar (PersistentState term0 Nothing (Log (Seq.empty)))
    --ps <- atomically $ readTVar psTVar
    --pure ps

data StoreCmd = Set Text Natural | Incr Text

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
      Nothing -> panic "wtf bro"
      Just c -> lift $ writeChan c msg

instance MonadConc m => RaftRecvRPC (TestEnvT m) StoreCmd where
  recvRPC = do
    myNodeId <- asks nid
    nodeChanMap <- asks nodes
    case Map.lookup myNodeId nodeChanMap of
      Nothing -> panic "wtf bro"
      Just c -> lift $ readChan c

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

test_auto :: TestTree
test_auto = testAuto $ do

  nodeChans <- replicateM 2 newChan
  let nodeChanMap = Map.fromList $ zip [node0, node1] nodeChans

  testEnv0 <- mkNodeTestEnv node0 nodeChanMap
  -- testEnv1 <- mkNodeTestEnv node1 nodeChanMap

  runTestEnvT testEnv0 (runRaftNode testConfig0 initStore)
  -- runTestEnvT testEnv1 (runRaftNode testConfig1 initStore)


--------------------------------------------------------------------------------
--
-- data Logger m = Logger (MVar m LogCommand) (MVar m [[Char]])
--
-- data LogCommand = Message [Char] | Stop
--
-- -- | Create a new logger with no internal log.
-- initLogger :: MonadConc m => m (Logger m)
-- initLogger = do
--   cmd <- newEmptyMVar
--   logg <- newMVar []
--   let l = Logger cmd logg
--   void . fork $ logger l
--   pure l
--
-- logger :: MonadConc m => Logger m -> m ()
-- logger (Logger cmd logg) = loop where
--   loop = do
--     command <- takeMVar cmd
--     case command of
--       Message str -> do
--         strs <- takeMVar logg
--         putMVar logg (strs ++ [str])
--         loop
--       Stop -> pure ()
--
-- -- | Add a string to the log.
-- logMessage :: MonadConc m => Logger m -> [Char] -> m ()
-- logMessage (Logger cmd _) str = putMVar cmd $ Message str
--
-- -- | Stop the logger and return the contents of the log.
-- logStop :: MonadConc m => Logger m -> m [[Char]]
-- logStop (Logger cmd logg) = do
--   putMVar cmd Stop
--   readMVar logg
--
-- -- | Race condition! Can you see where?
-- raceyLogger :: MonadConc m => m [[Char]]
-- raceyLogger = do
--   l <- initLogger
--   logMessage l "Hello"
--   logMessage l "World"
--   logMessage l "Foo"
--   logMessage l "Bar"
--   logMessage l "Baz"
--   logStop l
--
-- -- | Test that the result is always in the set of allowed values, and
-- -- doesn't deadlock.
-- validResult :: Predicate [[Char]]
-- validResult = alwaysTrue check where
--   check (Right strs) = strs `elem` [ ["Hello", "World", "Foo", "Bar", "Baz"]
--                                    , ["Hello", "World", "Foo", "Bar"]
--                                    ]
--   check _ = False
--
-- -- | Test that the "proper" result occurs at least once.
-- isGood :: Predicate [[Char]]
-- isGood = somewhereTrue check where
--   check (Right a) = length a == 5
--   check _ = False
--
-- -- | Test that the erroneous result occurs at least once.
-- isBad :: Predicate [[Char]]
-- isBad = somewhereTrue check where
--   check (Right a) = length a == 4
-- check _ = False
