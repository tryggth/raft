{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Raft where

import Protolude hiding (STM, TChan, newTChan, readTChan, writeTChan, atomically)

import Control.Monad.Conc.Class
import Control.Monad.STM.Class
import Control.Concurrent.STM.Timer
import Control.Concurrent.Classy.STM.TChan
import Control.Concurrent.Classy.Async

import Control.Monad.Catch
import Control.Monad.Trans.Class

import qualified Data.Map as Map
import Numeric.Natural
import System.Random (randomIO)

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
  sendRPC :: NodeId -> RPCMessage v -> m ()

class RaftRecvRPC m v where
  receiveRPC :: m (RPCMessage v)


class RaftSendClient m sm where
  sendClient :: ClientId -> ClientResponse sm -> m ()

class RaftRecvClient m v where
  receiveClient :: m (ClientRequest v)

-- | A typeclass providing an interface to save and load the persistent state of
-- a raft node.
--
-- TODO: It is infeasible to keep the persistent state in memory, as it contains
-- all of the logs in their entirety. Perhaps there is a better solution... see
-- the Raft.PersistentState module.
class RaftPersist m v where
  savePersistentState :: PersistentState v -> m ()
  loadPersistentState :: m (PersistentState v)

-- | The raft server environment composed of the concurrent variables used in
-- the effectful raft layer.
data RaftEnv v m = RaftEnv
  { serverEventChan :: TChan (STM m) (Event v)
  , serverElectionTimer :: Timer m
  , serverHeartbeatTimer :: Timer m
  }

newtype RaftT s v m a = RaftT
  { unRaftT :: ReaderT (RaftEnv v m) (StateT (RaftNodeState s) m) a
  } deriving (Functor, Applicative, Monad, MonadReader (RaftEnv v m), MonadState (RaftNodeState s), Alternative, MonadPlus)

instance MonadTrans (RaftT s m) where
  lift = RaftT . lift . lift

deriving instance MonadThrow m => MonadThrow (RaftT s v m)
deriving instance MonadCatch m => MonadCatch (RaftT s v m)
deriving instance MonadMask m => MonadMask (RaftT s v m)
deriving instance MonadConc m => MonadConc (RaftT s v m)

runRaftT
  :: MonadConc m
  => RaftNodeState s
  -> RaftEnv v m
  -> RaftT s v m ()
  -> m ()
runRaftT raftNodeState raftEnv =
  flip evalStateT raftNodeState . flip runReaderT raftEnv . unRaftT

------------------------------------------------------------------------------

runRaftNode
   :: forall s sm v m.
     ( Show v, Show sm
     , MonadConc m
     , StateMachine sm v
     , RaftSendRPC m v
     , RaftRecvRPC m v
     , RaftPersist m v
     , RaftSendClient m sm
     , RaftRecvClient m v
     )
   => NodeConfig
   -> Int
   -> sm
   -> (TWLog -> m ())
   -> m ()
runRaftNode nodeConfig@NodeConfig{..} timerSeed initStateMachine logWriter = do
  eventChan <- atomically newTChan :: m (TChan (STM m) (Event v))

  electionTimer <- newTimerRange timerSeed configElectionTimeout
  heartbeatTimer <- newTimer configHeartbeatTimeout

  fork (electionTimeoutTimer electionTimer eventChan)
  fork (heartbeatTimeoutTimer heartbeatTimer eventChan)
  fork (rpcHandler eventChan)
  fork (clientReqHandler eventChan)

  let raftEnv = RaftEnv eventChan electionTimer heartbeatTimer
  runRaftT initRaftNodeState raftEnv $
    handleEventLoop nodeConfig initStateMachine logWriter


handleEventLoop
   :: forall s sm v m.
      ( Show v, Show sm
      , MonadConc m
      , StateMachine sm v
      , RaftPersist m v
      , RaftSendRPC m v
      , RaftSendClient m sm
      , RaftRecvClient m v
      )
   => NodeConfig
   -> sm
   -> (TWLog -> m ())
   -> RaftT s v m ()
handleEventLoop nodeConfig initStateMachine logWriter = do
    handleEventLoop' =<<
      flip TransitionState initStateMachine <$> lift loadPersistentState
  where
    handleEventLoop' :: TransitionState sm v -> RaftT s v m ()
    handleEventLoop' transitionState = do
      raftNodeState <- get
      event <- atomically . readTChan =<< asks serverEventChan
      let (resRaftNodeState, resTransitionState, transitionW) =
            Raft.Handle.handleEvent nodeConfig raftNodeState transitionState event
      lift $ savePersistentState (transPersistentState resTransitionState)
      updateRaftNodeState resRaftNodeState
      handleLogs logWriter $ twLogs transitionW
      handleActions $ twActions transitionW
      handleEventLoop' resTransitionState

    updateRaftNodeState :: RaftNodeState s -> RaftT s v m ()
    updateRaftNodeState newRaftNodeState =
      modify $ const newRaftNodeState

handleActions
  :: (Show v, Show sm, MonadConc m, StateMachine sm v, RaftSendRPC m v, RaftSendClient m sm)
  => [Action sm v]
  -> RaftT s v m ()
handleActions = mapM_ handleAction

handleAction
   :: (Show v, Show sm, MonadConc m, StateMachine sm v, RaftSendRPC m v, RaftSendClient m sm)
   => Action sm v
   -> RaftT s v m ()
handleAction action = do
  traceM $ "Handling action: " <> show action
  case action of
    SendRPCMessage nid msg -> lift (sendRPC nid msg)
    SendRPCMessages msgs ->
      forConcurrently_ (Map.toList msgs) $ \(nid, msg) ->
        lift (sendRPC nid msg)
    BroadcastRPC nids msg -> mapConcurrently_ (lift . flip sendRPC msg) nids
    RespondToClient cid cr -> lift $ sendClient cid cr
    ResetTimeoutTimer tout ->
      case tout of
        ElectionTimeout -> resetServerTimer serverElectionTimer
        HeartbeatTimeout -> resetServerTimer serverHeartbeatTimer
  where
    resetServerTimer f =
      lift . resetTimer =<< asks f

handleLogs
  :: (MonadConc m)
  => (TWLog -> m ())
  -> TWLogs
  -> RaftT s v m ()
handleLogs f logs = lift $ mapM_ f logs

------------------------------------------------------------------------------
 --Event Producers
------------------------------------------------------------------------------

-- | Producer for rpc message events
rpcHandler
  :: (MonadConc m, RaftRecvRPC m v)
  => TChan (STM m) (Event v)
  -> m ()
rpcHandler eventChan =
  forever $
    receiveRPC >>= \rpcMsg ->
      atomically $ writeTChan eventChan (MessageEvent (RPCMessageEvent rpcMsg))

-- | Producer for rpc message events
clientReqHandler
  :: (MonadConc m, RaftRecvClient m v)
  => TChan (STM m) (Event v)
  -> m ()
clientReqHandler eventChan =
  forever $
    receiveClient >>= \clientReq ->
      atomically $ writeTChan eventChan (MessageEvent (ClientRequestEvent clientReq))

-- | Producer for the election timeout event
electionTimeoutTimer :: MonadConc m => Timer m -> TChan (STM m) (Event v) -> m ()
electionTimeoutTimer timer eventChan =
  forever $ do
    startTimer timer >> waitTimer timer
    atomically $ writeTChan eventChan (TimeoutEvent ElectionTimeout)


-- | Producer for the heartbeat timeout event
heartbeatTimeoutTimer :: MonadConc m => Timer m -> TChan (STM m) (Event v) -> m ()
heartbeatTimeoutTimer timer eventChan =
  forever $ do
    startTimer timer >> waitTimer timer
    atomically $ writeTChan eventChan (TimeoutEvent HeartbeatTimeout)
