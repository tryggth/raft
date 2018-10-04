{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}

module Raft where

import Protolude hiding (Chan, newChan, readChan, writeChan)

import Control.Concurrent.Classy
import Control.Concurrent.STM.Timer

import Control.Monad.Trans.Class

import Numeric.Natural

import Raft.Action
import Raft.Config
import Raft.Event
import Raft.Handle
import Raft.Monad
import Raft.NodeState
import Raft.Persistent
import Raft.RPC
import Raft.Types

-- | Provide an interface for nodes to send/receive messages to/from one
-- another. E.g. Control.Concurrent.Chan, Network.Socket, etc.
class MonadConc m => RaftRPC m v where
  sendRPC :: NodeId -> Message v -> m ()
  receiveRPC :: m (Message v)
  broadcastRPC :: NodeIds -> Message v -> m ()

-- | Functional dependency allowing only one v per sm
class RaftStateMachine sm v | sm -> v where
  applyLogEntry :: sm -> v -> sm

class MonadConc m => RaftPersist m v where
  savePersistentState :: PersistentState v -> m ()
  loadPersistentState :: m (PersistentState v)

data RaftState s m v = RaftState
  { serverNodeState :: RaftNodeState v
  , serverStateMachine :: s
  , serverEventChan :: Chan m (Event v)
  }

newtype RaftStateM s v m a = RaftStateM
  { unRaftStateM :: ReaderT (RaftState s m v) m a
  } deriving (Functor, Applicative, Monad, MonadReader (RaftState s m v))

instance RaftRPC m v => RaftRPC (RaftStateM s v m) v

runRaftStateM :: MonadConc m => RaftState s m v -> RaftStateM s v m () -> m ()
runRaftStateM raftState = flip runReaderT raftState . unRaftStateM

--------------------------------------------------------------------------------

runRaftNode
  :: (MonadConc m, RaftStateMachine s v, RaftRPC m v, RaftPersist m v)
  => NodeConfig
  -> s
  -> m ()
runRaftNode nodeConfig@NodeConfig{..} initStateMachine = do
  eventChan <- newChan
  electionTimer <- newTimer
  heartbeatTimer <- newTimer

  fork (electionTimeoutTimer configElectionTimeout electionTimer eventChan)
  fork (heartbeatTimeoutTimer configElectionTimeout electionTimer eventChan)
  fork (rpcHandler eventChan)

  let raftState = RaftState initRaftNodeState initStateMachine eventChan
  runRaftStateM raftState (handleEventLoop nodeConfig)

handleEventLoop
  :: (MonadConc m, RaftStateMachine s v, RaftPersist m v, RaftRPC m v)
  => NodeConfig
  -> RaftStateM s v m ()
handleEventLoop nodeConfig =
    handleEventLoop' =<< lift loadPersistentState
  where
    handleEventLoop' :: PersistentState v -> RaftStateM s v m ()
    handleEventLoop' persistentState = do
      eventChan <- asks serverEventChan
      event <- lift (readChan eventChan)
      let (resRaftNodeState, resPersistentState, actions) =
            Raft.Handle.handleEvent nodeConfig initRaftNodeState persistentState event
      savePersistentState resPersistentState
      handleActions actions
      handleEventLoop' resPersistentState

handleActions :: (MonadConc m, RaftStateMachine s v, RaftRPC m v) => [Action v] -> RaftStateM s v m ()
handleActions = mapM_ handleAction

handleAction :: (MonadConc m, RaftStateMachine s v, RaftRPC m v) => Action v -> RaftStateM s v m ()
handleAction action = undefined

--------------------------------------------------------------------------------
-- Event Producers
--------------------------------------------------------------------------------

-- | Producer for rpc message events
rpcHandler :: (MonadConc m, RaftRPC m v) => Chan m (Event v) -> m ()
rpcHandler eventChan =
  forever $
    receiveRPC >>= \rpcMsg ->
      writeChan eventChan (Message rpcMsg)

-- | Producer for the election timeout event
electionTimeoutTimer :: MonadConc m => Natural -> Timer m -> Chan m (Event v) -> m ()
electionTimeoutTimer n timer eventChan =
  forever $ do
    startTimer n timer >> waitTimer timer
    writeChan eventChan (Timeout ElectionTimeout)

-- | Producer for the heartbeat timeout event
heartbeatTimeoutTimer :: MonadConc m => Natural -> Timer m -> Chan m (Event v) -> m ()
heartbeatTimeoutTimer n timer eventChan =
  forever $ do
    startTimer n timer >> waitTimer timer
    writeChan eventChan (Timeout HeartbeatTimeout)
