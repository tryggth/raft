{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}

module Raft.Logging where

import Protolude

import Control.Monad.Trans.Class (MonadTrans)
import Control.Monad.State (modify')

import Data.Time

import Raft.NodeState
import Raft.Types

data LogDest
  = LogFile FilePath
  | LogStdout
  | NoLogs

data Severity
  = Info
  | Debug
  | Critical
  deriving (Show)

data LogMsg = LogMsg
  { mTime :: Maybe UTCTime
  , severity :: Severity
  , logMsgData :: LogMsgData
  }

data LogMsgData = LogMsgData
  { logMsgNodeId :: NodeId
  , logMsgNodeState :: Mode
  , logMsg :: Text
  } deriving (Show)

logMsgToText :: LogMsg -> Text
logMsgToText (LogMsg mt s d) =
    maybe "" timeToText mt <> "(" <> show s <> ")" <> " " <> logMsgDataToText d
  where
    timeToText :: UTCTime -> Text
    timeToText t = "[" <> toS (timeToText' t) <> "]"

    timeToText' = formatTime defaultTimeLocale (iso8601DateFormat (Just "%H:%M:%S"))

logMsgDataToText :: LogMsgData -> Text
logMsgDataToText LogMsgData{..} =
  "<" <> toS logMsgNodeId <> " | " <> show logMsgNodeState <> ">: " <> logMsg

class Monad m => RaftLogger m where
  loggerNodeId :: m NodeId
  loggerNodeState :: m RaftNodeState

mkLogMsgData :: RaftLogger m => Text -> m LogMsgData
mkLogMsgData msg = do
  nid <- loggerNodeId
  ns <- nodeMode <$> loggerNodeState
  pure $ LogMsgData nid ns msg

instance RaftLogger m => RaftLogger (RaftLoggerT m) where
  loggerNodeId = lift loggerNodeId
  loggerNodeState = lift loggerNodeState

--------------------------------------------------------------------------------
-- Logging with IO
--------------------------------------------------------------------------------

logToDest :: MonadIO m => LogDest -> LogMsg -> m ()
logToDest logDest logMsg =
  case logDest of
    LogStdout -> putText (logMsgToText logMsg)
    LogFile fp -> liftIO $ appendFile fp (logMsgToText logMsg)
    NoLogs -> pure ()

logToStdout :: MonadIO m => LogMsg -> m ()
logToStdout = logToDest LogStdout

logToFile :: MonadIO m => FilePath -> LogMsg -> m ()
logToFile fp = logToDest (LogFile fp)

logWithSeverityIO :: (RaftLogger m, MonadIO m) => Severity -> LogDest -> Text -> m ()
logWithSeverityIO s logDest msg = do
  logMsgData <- mkLogMsgData msg
  now <- liftIO getCurrentTime
  let logMsg = LogMsg (Just now) s logMsgData
  logToDest logDest logMsg

logInfoIO :: (RaftLogger m, MonadIO m) => LogDest -> Text -> m ()
logInfoIO = logWithSeverityIO Info

logDebugIO :: (RaftLogger m, MonadIO m) => LogDest -> Text -> m ()
logDebugIO = logWithSeverityIO Debug

logCriticalIO :: (RaftLogger m, MonadIO m) => LogDest -> Text -> m ()
logCriticalIO = logWithSeverityIO Critical

--------------------------------------------------------------------------------
-- Pure Logging
--------------------------------------------------------------------------------

newtype RaftLoggerT m a = RaftLoggerT {
    unRaftLoggerT :: StateT [LogMsg] m a
  } deriving (Functor, Applicative, Monad, MonadState [LogMsg], MonadTrans)

runRaftLoggerT
  :: Monad m
  => RaftLoggerT m a -- ^ The computation from which to extract the logs
  -> m (a, [LogMsg])
runRaftLoggerT = flip runStateT [] . unRaftLoggerT

type RaftLoggerM = RaftLoggerT Identity

runRaftLoggerM
  :: RaftLoggerM a
  -> (a, [LogMsg])
runRaftLoggerM = runIdentity . runRaftLoggerT

logWithSeverity :: RaftLogger m => Severity -> Text -> RaftLoggerT m ()
logWithSeverity s txt = do
  !logMsgData <- mkLogMsgData txt
  let !logMsg = LogMsg Nothing s logMsgData
  modify' (++ [logMsg])

logInfo :: RaftLogger m => Text -> RaftLoggerT m ()
logInfo = logWithSeverity Info

logDebug :: RaftLogger m => Text -> RaftLoggerT m ()
logDebug = logWithSeverity Debug

logCritical :: RaftLogger m => Text -> RaftLoggerT m ()
logCritical = logWithSeverity Critical
