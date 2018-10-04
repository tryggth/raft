
module Control.Concurrent.STM.Timer (
  Timer,
  waitTimer,
  startTimer,
  newTimer
) where

import Protolude hiding (STM, ThreadId, threadDelay, myThreadId, atomically)

import Control.Monad.Conc.Class
import Control.Concurrent.Classy.STM

import Numeric.Natural

data Timer m = Timer
  { timerThread :: TMVar (STM m) (ThreadId m)
  , timerLock :: TMVar (STM m) ()
  }

waitTimer :: MonadConc m => Timer m -> m ()
waitTimer (Timer _ lock) =
  atomically $ readTMVar lock

-- | Starting a timer will only work if the timer is currently stopped
startTimer :: MonadConc m => Natural -> Timer m -> m ()
startTimer n (Timer tid lock) = do
  timerLock <- atomically $ tryTakeTMVar lock
  case timerLock of
    Nothing -> pure ()
    Just () ->
      void $ fork $ do
        threadId <- myThreadId
        atomically $ do
          _ <- tryTakeTMVar tid
          putTMVar tid threadId
        threadDelay (fromIntegral n)
        atomically $ do
          putTMVar lock ()
          void $ takeTMVar tid

newTimer :: MonadConc m => m (Timer m)
newTimer = do
  timerThread <- atomically newEmptyTMVar
  timerLock <- atomically (newTMVar ())
  pure $ Timer timerThread timerLock
