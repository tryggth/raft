
module Control.Concurrent.STM.Timer (
  Timer,
  waitTimer,
  startTimer,
  resetTimer,
  newTimer
) where

import Protolude hiding (STM, killThread, ThreadId, threadDelay, myThreadId, atomically)

import Control.Monad.Conc.Class
import Control.Concurrent.Classy.STM
import System.Random (StdGen, randomR, RandomGen, mkStdGen)

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
startTimer timer@(Timer _ lock _ _) = do
  timerLock <- atomically $ tryTakeTMVar lock
  case timerLock of
    Nothing -> pure ()
    Just () -> spawnTimer timer

resetTimer :: MonadConc m => Timer m -> m ()
resetTimer timer@(Timer tid _ _ _) = do
  -- Kill the old timer
  mOldTid <- atomically $ tryTakeTMVar tid
  case mOldTid of
    Just oldTid -> killThread oldTid
    Nothing -> pure ()
  -- Spawn a new timer
  spawnTimer timer

-- | Spawn a timer thread. This function assumes that there are no other threads
-- are using the timer
spawnTimer :: MonadConc m => Timer m -> m ()
spawnTimer (Timer tid lock trange@(tmin, tmax) tgen) = do
  g <- atomically $ readTVar tgen
  let (n, g') = randomR (toInteger tmin, toInteger tmax) g
  atomically $ writeTVar tgen g'
  void $ fork $ do
    threadId <- myThreadId
    atomically $ do
      _ <- tryTakeTMVar lock
      _ <- tryTakeTMVar tid
      void $ putTMVar tid threadId
    threadDelay (fromIntegral n)
    atomically $ do
      _ <- tryTakeTMVar tid
      putTMVar lock ()

newTimer :: MonadConc m => (Natural, Natural) -> m (Timer m)
newTimer timeoutRange = do
  (timerThread, timerLock, timerGen) <-
    atomically $ (,,) <$> newEmptyTMVar <*> newTMVar () <*> newTVar (mkStdGen 0)
  pure $ Timer timerThread timerLock timeoutRange timerGen

--------------------------------------------------------------------------------

natsToInteger :: (Natural, Natural) -> (Integer, Integer)
natsToInteger (t1, t2) = (fromIntegral t1, fromIntegral t2)

initialStdGen :: StdGen
initialStdGen = mkStdGen 0

rndTimeout :: (Natural, Natural) -> Natural
rndTimeout t = fromIntegral $ fst $ randomR (natsToInteger t) initialStdGen
