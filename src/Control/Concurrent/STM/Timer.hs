
module Control.Concurrent.STM.Timer (
  waitTimer,
  startTimer,
  newTimer
) where

import Protolude

import Control.Concurrent.STM

data Timer = Timer
  { timerThread :: TMVar ThreadId
  , timerLock :: TMVar ()
  }

waitTimer :: Timer -> IO ()
waitTimer (Timer _ lock) = do
  atomically $ readTMVar lock

-- | Starting a timer will only work if the timer is currently stopped
startTimer :: Int -> Timer -> IO ()
startTimer n (Timer tid lock) = do
  timerLock <- atomically $ tryTakeTMVar lock
  case timerLock of
    Nothing -> pure ()
    Just () ->
      void $ forkIO $ do
        threadId <- myThreadId
        atomically $ do
          _ <- tryTakeTMVar tid
          putTMVar tid threadId
        threadDelay n
        atomically $ do
          putTMVar lock ()
          void $ takeTMVar tid

newTimer :: IO Timer
newTimer = do
  timerThread <- newEmptyTMVarIO
  timerLock <- newTMVarIO ()
  pure $ Timer timerThread timerLock
