{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}


module Raft.Logging where

import Protolude

import Control.Monad.Trans.Class (MonadTrans)
import Control.Monad.State (modify')

import Raft.NodeState
import Raft.Types

data Severity
  = Info
  | Debug
  | Critical
  deriving (Show)

data LogMsg = LogMsg
  { severity :: Severity
  , logMsgData :: LogMsgData
  }

logMsgToText :: LogMsg -> Text
logMsgToText (LogMsg s d) =  "[" <> show s <> "]" <> " " <> show d

data LogMsgData = LogMsgData
  { logMsgNodeId :: NodeId
  , logMsgNodeState :: RaftNodeState
  , logMsg :: Text
  } deriving (Show)

class Monad m => RaftLogger m where
  loggerNodeId :: m NodeId
  loggerNodeState :: m RaftNodeState

newtype RaftLoggerT m a = RaftLoggerT {
    unRaftLoggerT :: StateT [LogMsg] m a
  } deriving (Functor, Applicative, Monad, MonadState [LogMsg], MonadTrans)

type RaftLoggerM = RaftLoggerT Identity

mkLogMsgData :: RaftLogger m => Text -> m LogMsgData
mkLogMsgData msg = do
  nid <- loggerNodeId
  ns <- loggerNodeState
  pure $ LogMsgData nid ns msg

logWithSeverity :: RaftLogger m => Severity -> Text -> RaftLoggerT m ()
logWithSeverity s txt = do
  !logMsgData <- mkLogMsgData txt
  let !logMsg = LogMsg s logMsgData
  modify' (++ [logMsg])

instance RaftLogger m => RaftLogger (RaftLoggerT m) where
  loggerNodeId = lift loggerNodeId
  loggerNodeState = lift loggerNodeState

runRaftLoggerT
  :: Monad m
  => RaftLoggerT m a -- ^ The computation from which to extract the logs
  -> m (a, [LogMsg])
runRaftLoggerT = flip runStateT [] . unRaftLoggerT

runRaftLoggerM
  :: RaftLoggerM a
  -> (a, [LogMsg])
runRaftLoggerM = runIdentity . runRaftLoggerT

--------------------------------------------------------------------------------

logInfo :: RaftLogger m => Text -> RaftLoggerT m ()
logInfo = logWithSeverity Info

logDebug :: RaftLogger m => Text -> RaftLoggerT m ()
logDebug = logWithSeverity Debug

logCritical :: RaftLogger m => Text -> RaftLoggerT m ()
logCritical = logWithSeverity Critical
