
module Control.Concurrent.STM.Timer (
  Timer,
  waitTimer,
  startTimer,
  resetTimer,
  newTimer,
  newTimerRange,
) where

import Protolude hiding (STM, killThread, ThreadId, threadDelay, myThreadId, atomically)

import Control.Monad.Conc.Class
import Control.Concurrent.Classy.STM
import System.Random (StdGen, randomR, mkStdGen)

import Numeric.Natural

data Timer m = Timer
  { timerThread :: TMVar (STM m) (ThreadId m)
  , timerLock :: TMVar (STM m) ()
  , timerRange :: (Natural, Natural)
  , timerGen :: TVar (STM m) StdGen
  }

waitTimer :: MonadConc m => Timer m -> m ()
waitTimer (Timer _ lock _ _) =
  atomically $ readTMVar lock

-- | Starting a timer will only work if the timer is currently stopped
startTimer :: MonadConc m => Timer m -> m ()
startTimer timer = do
  lock <- atomically $ tryTakeTMVar (timerLock timer)
  case lock of
    Nothing -> pure ()
    Just () -> spawnTimer timer

resetTimer :: MonadConc m => Timer m -> m ()
resetTimer timer = do
  -- Kill the old timer
  mOldTid <- atomically $ tryTakeTMVar (timerThread timer)
  case mOldTid of
    Just oldTid -> killThread oldTid
    Nothing -> pure ()
  -- Spawn a new timer
  spawnTimer timer

-- | Spawn a timer thread. This function assumes that there are no other threads
-- are using the timer
spawnTimer :: MonadConc m => Timer m -> m ()
spawnTimer timer = do
  g <- atomically $ readTVar (timerGen timer)
  let (tmin, tmax) = timerRange timer
      (n, g') = randomR (toInteger tmin, toInteger tmax) g
  atomically $ writeTVar (timerGen timer) g'
  void $ fork $ do
    threadId <- myThreadId
    atomically $ do
      _ <- tryTakeTMVar (timerLock timer)
      _ <- tryTakeTMVar (timerThread timer)
      void $ putTMVar (timerThread timer) threadId
    threadDelay (fromIntegral n)
    atomically $ do
      _ <- tryTakeTMVar (timerThread timer)
      putTMVar (timerLock timer) ()

newTimer :: MonadConc m => Natural -> m (Timer m)
newTimer timeout = newTimerRange 0 (timeout, timeout)

-- | Create a new timer with the given random seed and range of timer timeouts.
newTimerRange :: MonadConc m => Int -> (Natural, Natural) -> m (Timer m)
newTimerRange seed timeoutRange = do
  (timerThread, timerLock, timerGen) <-
    atomically $ (,,) <$> newEmptyTMVar <*> newTMVar () <*> newTVar (mkStdGen seed)
  pure $ Timer timerThread timerLock timeoutRange timerGen
