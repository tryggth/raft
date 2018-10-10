{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Raft where

import Protolude hiding (Chan, newChan, readChan, writeChan, STM)

import Control.Concurrent.Classy
import Control.Concurrent.Classy.Async
import Control.Concurrent.Classy.STM
import Control.Monad.Catch
import Control.Concurrent.STM.Timer

import Control.Monad.Trans.Class

import qualified Data.Map as Map

import Numeric.Natural
import System.Random (StdGen, randomR, RandomGen, mkStdGen)

import Raft.Action
import Raft.Client
import Raft.Config
import Raft.Event
import Raft.Handle
import Raft.Log
import Raft.Monad
import Raft.NodeState
import Raft.Persistent
import Raft.RPC
import Raft.Types


-- | Provide an interface for nodes to send/receive messages to/from one
-- another. E.g. Control.Concurrent.Chan, Network.Socket, etc.
class RaftSendRPC m v where
  sendRPC :: NodeId -> Message v -> m ()

class RaftRecvRPC m v where
  receiveRPC :: m (Message v)

class RaftClientRPC m s where
  sendClientRPC :: ClientId -> ClientReadRes s -> m ()

--- | The underlying raft state machine. Functional dependency permitting only
--a single state machine command to be defined to update the state machine.
class RaftStateMachine sm cmd | sm -> cmd where
  applyCommittedLogEntry :: sm -> cmd -> sm

-- | A typeclass providing an interface to save and load the persistent state of
-- a raft node.
--
-- TODO: It is infeasible to keep the persistent state in memory, as it contains
-- all of the logs in their entirety. Perhaps there is a better solution... see
-- the Raft.PersistentState module.
class RaftPersist m v where
  savePersistentState :: PersistentState v -> m ()
  loadPersistentState :: m (PersistentState v)

-- | The pure state of the raft node
--
-- TODO: Will probably have to store the state machine in a [write only (?)]
-- concurrent variable, as the client program using this raft implementation
-- will need the ability to read the current state of the state machine at
-- arbitrary times.
data RaftState s v = RaftState
  { serverNodeState :: RaftNodeState v
  , serverStateMachine :: s
  }

-- | The raft server environment composed of the concurrent variables used in
-- the effectful raft layer.
data RaftEnv m v = RaftEnv
  { serverEventChan :: Chan m (Event v)
  , serverElectionTimer :: Timer m
  , serverHeartbeatTimer :: Timer m
  }

newtype RaftT s v m a = RaftT
  { unRaftT :: ReaderT (RaftEnv m v) (StateT (RaftState s v) m) a
  } deriving (Functor, Applicative, Monad, MonadReader (RaftEnv m v), MonadState (RaftState s v), Alternative, MonadPlus)

instance MonadTrans (RaftT s m) where
  lift = RaftT . lift . lift

deriving instance MonadThrow m => MonadThrow (RaftT s v m)
deriving instance MonadCatch m => MonadCatch (RaftT s v m)
deriving instance MonadSTM m => MonadSTM (RaftT s v m)
deriving instance MonadMask m => MonadMask (RaftT s v m)
deriving instance MonadConc m => MonadConc (RaftT s v m)

runRaftT
  :: MonadConc m
  => RaftState s v
  -> RaftEnv m v
  -> RaftT s v m ()
  -> m ()
runRaftT raftState raftEnv =
  flip evalStateT raftState . flip runReaderT raftEnv . unRaftT

------------------------------------------------------------------------------

runRaftNode
   :: (Show v, MonadConc m, RaftStateMachine s v, RaftSendRPC m v, RaftRecvRPC m v, RaftPersist m v, RaftClientRPC m s)
   => NodeConfig
   -> s
   -> (TWLog -> m())
   -> m ()
runRaftNode nodeConfig@NodeConfig{..} initStateMachine logWriter = do
  eventChan <- newChan
  electionTimer <- newTimer configElectionTimeout
  heartbeatTimer <- newTimer (configHeartbeatTimeout, configHeartbeatTimeout)

  fork (electionTimeoutTimer electionTimer eventChan)
  fork (heartbeatTimeoutTimer electionTimer eventChan)
  fork (rpcHandler eventChan)

  let raftState = RaftState initRaftNodeState initStateMachine
      raftEnv = RaftEnv eventChan electionTimer heartbeatTimer
  runRaftT raftState raftEnv (handleEventLoop nodeConfig logWriter)


handleEventLoop
   :: forall v m s. (Show v, MonadConc m, RaftStateMachine s v, RaftPersist m v, RaftSendRPC m v, RaftClientRPC m s)
   => NodeConfig
   -> (TWLog -> m ())
   -> RaftT s v m ()
handleEventLoop nodeConfig logWriter =
    handleEventLoop' =<< lift loadPersistentState
  where
    handleEventLoop' :: PersistentState v -> RaftT s v m ()
    handleEventLoop' persistentState = do
      event <- lift . readChan =<< asks serverEventChan
      case event of
        ClientReadRequest (ClientReadReq cid) -> do
          sm <- gets serverStateMachine
          lift $ sendClientRPC cid (ClientReadRes sm)
        _ -> do
          let (resRaftNodeState, resPersistentState, transitionW) =
                Raft.Handle.handleEvent nodeConfig initRaftNodeState persistentState event
          lift $ savePersistentState resPersistentState
          updateRaftNodeState resRaftNodeState
          handleActions $ twActions transitionW
          handleLogs logWriter $ twLogs transitionW
          handleEventLoop' resPersistentState

    updateRaftNodeState :: RaftNodeState v -> RaftT s v m ()
    updateRaftNodeState newRaftNodeState =
      modify $ \raftState ->
        raftState { serverNodeState = newRaftNodeState }

handleActions
  :: (Show v, MonadConc m, RaftStateMachine s v, RaftSendRPC m v)
  => [Action v]
  -> RaftT s v m ()
handleActions = mapM_ handleAction

handleAction
  :: (Show v, MonadConc m, RaftStateMachine s v, RaftSendRPC m v)
  => Action v
  -> RaftT s v m ()
handleAction action =
  case action of
    SendMessage nid msg -> lift (sendRPC nid msg)
    SendMessages msgs ->
      forConcurrently_ (Map.toList msgs) $ \(nid, msg) ->
        lift (sendRPC nid msg)
    Broadcast nids msg -> mapConcurrently_ (lift . flip sendRPC msg) nids
    RedirectClient (ClientId cid) currLdr -> undefined
    RespondToClient cid _ -> undefined
    ApplyCommittedLogEntry entry ->
      modify $ \raftState -> do
        let stateMachine = serverStateMachine raftState
            v = entryValue entry
        raftState { serverStateMachine = applyCommittedLogEntry stateMachine v }
    ResetTimeoutTimer tout ->
      case tout of
        ElectionTimeout -> resetServerTimer serverElectionTimer
        HeartbeatTimeout -> resetServerTimer serverHeartbeatTimer
  where
    resetServerTimer f =
      lift . resetTimer =<< asks f

handleLogs
  :: (Show v, MonadConc m)
  => (TWLog -> m ())
  -> TWLogs
  -> RaftT s v m ()
handleLogs f logs = lift $ mapM_ f logs

------------------------------------------------------------------------------
 --Event Producers
------------------------------------------------------------------------------

-- | Producer for rpc message events
rpcHandler
  :: (Show v, MonadConc m, RaftRecvRPC m v)
  => Chan m (Event v)
  -> m ()
rpcHandler eventChan =
  forever $
    receiveRPC >>= \rpcMsg ->
      writeChan eventChan (Message rpcMsg)

-- | Producer for the election timeout event
electionTimeoutTimer :: MonadConc m => Timer m -> Chan m (Event v)
 -> m ()
electionTimeoutTimer timer eventChan =
  forever $ do
    startTimer timer >> waitTimer timer
    writeChan eventChan (Timeout ElectionTimeout)


-- | Producer for the heartbeat timeout event
heartbeatTimeoutTimer :: MonadConc m => Timer m -> Chan m (Event v) -> m ()
heartbeatTimeoutTimer timer eventChan =
  forever $ do
    startTimer timer >> waitTimer timer
    writeChan eventChan (Timeout HeartbeatTimeout)

natsToInteger :: (Natural, Natural) -> (Integer, Integer)
natsToInteger (t1, t2) = (fromIntegral t1, fromIntegral t2)

rndTimeout :: (Natural, Natural) -> Natural
rndTimeout t = fromIntegral $ fst $ randomR (natsToInteger t) initialStdGen

initialStdGen :: StdGen
initialStdGen = mkStdGen 0
