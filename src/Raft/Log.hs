{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE GADTs #-}

module Raft.Log where

import Protolude

import Data.Serialize
import Data.Sequence (Seq(..), (|>))

import Raft.Types

-- | Representation of an entry in the replicated log
data Entry v = Entry
  { entryIndex :: Index
    -- ^ Index of entry in the log
  , entryTerm :: Term
    -- ^ Term when entry was received by leader
  , entryValue :: v
    -- ^ Command to update state machine
  , entryClientId :: ClientId
    -- ^ Id of the client that issued the command
  } deriving (Show, Generic, Serialize)

type Entries v = Seq (Entry v)

-- | Provides an interface for nodes to write log entries to storage.
class Monad m => RaftWriteLog m v where
  type RaftWriteLogError m
  -- | Write the given log entries to storage
  writeLogEntries
    :: Exception (RaftWriteLogError m)
    => Entries v -> m (Either (RaftWriteLogError m) ())

-- | Provides an interface for nodes to delete log entries from storage.
class Monad m => RaftDeleteLog m v where
  type RaftDeleteLogError m
  -- | Delete log entries from a given index; e.g. 'deleteLogEntriesFrom 7'
  -- should delete every log entry
  deleteLogEntriesFrom
    :: Exception (RaftDeleteLogError m)
    => Index -> m (Either (RaftDeleteLogError m) (Maybe (Entry v)))

-- | Provides an interface for nodes to read log entries from storage.
class Monad m => RaftReadLog m v where
  type RaftReadLogError m
  -- | Read the log at a given index
  readLogEntry
    :: Exception (RaftReadLogError m)
    => Index -> m (Either (RaftReadLogError m) (Maybe (Entry v)))
  -- | Read log entries from a specific index onwards, including the specific
  -- index
  readLogEntriesFrom
    :: Exception (RaftReadLogError m)
    => Index -> m (Either (RaftReadLogError m) (Entries v))
  -- | Read the last log entry in the log
  readLastLogEntry
    :: Exception (RaftReadLogError m)
    => m (Either (RaftReadLogError m) (Maybe (Entry v)))

  default readLogEntriesFrom
    :: Exception (RaftReadLogError m)
    => Index
    -> m (Either (RaftReadLogError m) (Entries v))
  readLogEntriesFrom idx = do
      eLastLogEntry <- readLastLogEntry
      case eLastLogEntry of
        Left err -> pure (Left err)
        Right Nothing -> pure (Right Empty)
        Right (Just lastLogEntry)
          | entryIndex lastLogEntry < idx -> pure (Right Empty)
          | otherwise -> fmap (|> lastLogEntry) <$> go (decrIndex (entryIndex lastLogEntry))
    where
      go idx'
        | idx' < idx || idx' == 0 = pure (Right Empty)
        | otherwise = do
            eLogEntry <- readLogEntry idx'
            case eLogEntry of
              Left err -> pure (Left err)
              Right Nothing -> panic "Malformed log"
              Right (Just logEntry) -> fmap (|> logEntry) <$>  go (decrIndex idx')

type RaftLog m v = (RaftReadLog m v, RaftWriteLog m v, RaftDeleteLog m v)
type RaftLogExceptions m = (Exception (RaftReadLogError m), Exception (RaftWriteLogError m), Exception (RaftDeleteLogError m))

-- | Representation of possible errors that come from reading, writing or
-- deleting logs from the persistent storage
data RaftLogError m where
  RaftLogReadError :: RaftReadLogError m -> RaftLogError m
  RaftLogWriteError :: RaftWriteLogError m -> RaftLogError m
  RaftLogDeleteError :: RaftDeleteLogError m -> RaftLogError m

updateLog
  :: forall m v. ( RaftDeleteLog m v, Exception (RaftDeleteLogError m)
     , RaftWriteLog m v, Exception (RaftWriteLogError m)
     )
  => Entries v
  -> m (Either (RaftLogError m) ())
updateLog entries =
  case entries of
    Empty -> pure (Right ())
    e :<| _ -> do
      -- TODO: This does not look right
      eDel <- deleteLogEntriesFrom (entryIndex e)
      case eDel of
        Left err -> pure (Left (RaftLogDeleteError err))
        Right (_ :: Maybe (Entry v))-> first RaftLogWriteError <$> writeLogEntries entries
