{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FunctionalDependencies #-}

module Examples.Raft.FileStore where

import Protolude

import Control.Concurrent.Classy hiding (catch, ThreadId)
import Control.Monad.Catch
import Control.Monad.Trans.Class

import Data.Sequence ((><))
import qualified Data.Sequence as Seq
import qualified Data.Serialize as S

import Raft

newtype NodeEnvError = NodeEnvError Text
  deriving (Show)

instance Exception NodeEnvError

data NodeFileStoreEnv = NodeFileStoreEnv
  { nfsPersistentState :: FilePath
  , nfsLogEntries :: FilePath
  }

newtype RaftFileStoreT m a = RaftFileStoreT { unRaftFileStoreT :: ReaderT NodeFileStoreEnv m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader NodeFileStoreEnv, Alternative, MonadPlus, MonadTrans)

deriving instance MonadConc m => MonadThrow (RaftFileStoreT m)
deriving instance MonadConc m => MonadCatch (RaftFileStoreT m)
deriving instance MonadConc m => MonadMask (RaftFileStoreT m)
deriving instance MonadConc m => MonadConc (RaftFileStoreT m)

--------------------
-- Raft Instances --
--------------------

instance (MonadIO m, MonadConc m, S.Serialize v) => RaftWriteLog (RaftFileStoreT m) v where
  type RaftWriteLogError (RaftFileStoreT m) = NodeEnvError
  writeLogEntries newEntries = do
    entriesPath <- asks nfsLogEntries
    currEntriesE <- S.decode . toS <$> liftIO (readFile entriesPath)
    case currEntriesE of
      Left err -> panic (toS $ "writeLogEntries: " ++ err)
      Right currEntries -> liftIO $ Right <$> writeFile entriesPath (toS $ S.encode (currEntries >< newEntries))

instance (MonadIO m, MonadConc m) => RaftPersist (RaftFileStoreT m) where
  type RaftPersistError (RaftFileStoreT m) = NodeEnvError
  writePersistentState ps = do
    psPath <- asks nfsPersistentState
    liftIO $ Right <$> writeFile psPath (toS $ S.encode ps)

  readPersistentState = do
    psPath <- asks nfsPersistentState
    fileContent <- liftIO $ readFile psPath
    case S.decode (toS fileContent) of
      Left err -> panic (toS $ "readPersistentState: " ++ err)
      Right ps -> pure $ Right ps

instance (MonadIO m, MonadConc m, S.Serialize v) => RaftReadLog (RaftFileStoreT m) v where
  type RaftReadLogError (RaftFileStoreT m) = NodeEnvError
  readLogEntry (Index idx) = do
    entriesPath <- asks nfsLogEntries
    fileContent <- liftIO $ readFile entriesPath
    case S.decode (toS fileContent) of
      Left err -> panic (toS $ "readLogEntry: " ++ err)
      Right entries ->
        case entries Seq.!? fromIntegral (if idx == 0 then 0 else idx - 1) of
          Nothing -> pure (Right Nothing)
          Just e -> pure (Right (Just e))

  readLastLogEntry = do
    entriesPath <- asks nfsLogEntries
    fileContent <- liftIO $ readFile entriesPath
    case S.decode (toS fileContent) of
      Left err -> panic (toS err)
      Right entries -> case entries of
        Seq.Empty -> pure (Right Nothing)
        (_ Seq.:|> e) -> pure (Right (Just e))

instance (MonadIO m, MonadConc m, S.Serialize v) => RaftDeleteLog (RaftFileStoreT m) v where
  type RaftDeleteLogError (RaftFileStoreT m) = NodeEnvError
  deleteLogEntriesFrom idx = do
    entriesPath <- asks nfsLogEntries
    fileContent <- liftIO $ readFile entriesPath
    case S.decode (toS fileContent) :: Either [Char] (Entries v) of
      Left err -> panic (toS $ "deleteLogEntriesFrom: " ++ err)
      Right entries -> pure $ const (Right DeleteSuccess) $ Seq.dropWhileR ((>= idx) . entryIndex) entries
