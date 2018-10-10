
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
  , timerGen :: TMVar (STM m) StdGen
  }

waitTimer :: MonadConc m => Timer m -> m ()
waitTimer (Timer _ lock _ _) =
  atomically $ readTMVar lock

-- | Starting a timer will only work if the timer is currently stopped
startTimer :: MonadConc m => Timer m -> m ()
startTimer (Timer tid lock trange@(tmin, tmax) tgen) = do
  timerLock <- atomically $ tryTakeTMVar lock
  g <- atomically $ takeTMVar tgen
  let (n, g') = randomR (fromIntegral tmin :: Integer, fromIntegral tmax :: Integer) g
  case timerLock of
    Nothing -> pure ()
    Just () ->
      void $ fork $ do
        threadId <- myThreadId
        atomically $ do
          _ <- tryTakeTMVar tid
          putTMVar tid threadId

        atomically $ putTMVar tgen g'

        threadDelay (fromIntegral n)
        atomically $ do
          putTMVar lock ()
          void $ takeTMVar tid


stopTimer :: MonadConc m => Timer m -> m ()
stopTimer (Timer tid lock _ _) = do
  timerLock <- atomically $ tryTakeTMVar lock
  case timerLock of
    Nothing -> do
        currThreadId <-
          atomically $ do
            putTMVar lock ()
            takeTMVar tid
        killThread currThreadId
    Just _ -> pure ()

resetTimer :: MonadConc m => Timer m -> m ()
resetTimer timer =
  stopTimer timer >> startTimer timer

newTimer :: MonadConc m => (Natural, Natural) -> m (Timer m)
newTimer timeoutRange = do
  (timerThread, timerLock, timerGen) <-
    atomically $ (,,) <$> newEmptyTMVar <*> newTMVar () <*> newTMVar (mkStdGen 0)
  pure $ Timer timerThread timerLock timeoutRange timerGen

natsToInteger :: (Natural, Natural) -> (Integer, Integer)
natsToInteger (t1, t2) = (fromIntegral t1, fromIntegral t2)

initialStdGen :: StdGen
initialStdGen = mkStdGen 0

rndTimeout :: (Natural, Natural) -> Natural
rndTimeout t = fromIntegral $ fst $ randomR (natsToInteger t) initialStdGen


