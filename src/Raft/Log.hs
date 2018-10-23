{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

module Raft.Log where

import Protolude

import Data.Serialize
import Data.Sequence (Seq(..), (<|), (|>))
import qualified Data.Sequence as Seq

import Raft.Types

-- | An entry in the replicated log
data Entry v = Entry
  { entryIndex :: Index
    -- ^ index of entry in log
  , entryTerm :: Term
    -- ^ term when entry was received by leader
  , entryValue :: v
    -- ^ command to update state machine
  , entryClientId :: ClientId
  } deriving (Show, Generic, Serialize)

data AppendEntryError
  = UnexpectedLogIndex Index Index
  deriving (Show)

type Entries v = Seq (Entry v)

-- | The replicated log of entries on each node
newtype Log v = Log { unLog :: Entries v } deriving Show

-- | Append a log entry to the log. Checks if the log is the correct index
appendLogEntry :: Show v => Log v -> Entry v -> Either AppendEntryError (Log v)
appendLogEntry (Log logEntries) newEntry =
    case logEntries of
      Empty
        | newEntryIndex == 0 -> Right newLog
        | otherwise -> Left (UnexpectedLogIndex newEntryIndex 0)
      entries :|> entry
        | newEntryIndex == entryIndex entry + 1 -> Right newLog
        | otherwise -> Left (UnexpectedLogIndex newEntryIndex (entryIndex entry + 1))
  where
    newEntryIndex = entryIndex newEntry
    newLog = Log (logEntries |> newEntry)

-- | Append a sequence of log entries to the log. The log entries must be in
-- descending order with respect to the log entry indices.
appendLogEntries :: Show v => Log v -> Seq (Entry v) -> Either AppendEntryError (Log v)
appendLogEntries = foldrM (flip appendLogEntry)

lookupLogEntry :: Index -> Log v -> Maybe (Entry v)
lookupLogEntry idx (Log log) =
  Seq.lookup (fromIntegral idx) log

lastLogEntry :: Log v -> Maybe (Entry v)
lastLogEntry (Log entries) = lastEntry entries

lastEntry :: Seq (Entry v) -> Maybe (Entry v)
lastEntry Empty = Nothing
--lastEntry (e :<| _) = Just e
lastEntry (_ :|> e) = Just e

-- | Get the last log entry index
lastLogEntryIndex :: Log v -> Index
lastLogEntryIndex log =
  case lastLogEntry log of
    Nothing -> index0
    Just entry -> entryIndex entry

nextLogEntryIndex :: Log v -> Index
nextLogEntryIndex log =
  case lastLogEntry log of
    Nothing -> index0
    Just entry -> entryIndex entry + 1

lastLogEntryClientId :: Log v -> Maybe ClientId
lastLogEntryClientId log =
  entryClientId <$> lastLogEntry log

-- | Get the last log entry index and term
lastLogEntryIndexAndTerm :: Log v -> (Index, Term)
lastLogEntryIndexAndTerm log =
  case lastLogEntry log of
    -- TODO: Is term0 the default term when there are no logs?
    -- If we store a log for each new election, then the default term can be 0
    Nothing -> (index0, term0)
    Just entry -> (entryIndex entry, entryTerm entry)

takeLogEntriesUntil :: Log v -> Index -> Entries v
takeLogEntriesUntil (Log log) idx =
  Seq.takeWhileL ((<=) idx . entryIndex) log

dropLogEntriesUntil :: Log v -> Index -> Log v
dropLogEntriesUntil (Log log) idx =
  Log (Seq.dropWhileL ((<=) idx . entryIndex) log)
