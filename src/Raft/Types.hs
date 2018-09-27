{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}

module Raft.Types where

import Protolude

type NodeId = ByteString
type NodeIds = Set NodeId

newtype Term = Term Int
newtype Index = Index Int
  deriving (Num)

data NodeConfig = NodeConfig
  { configNodeId :: NodeId
  , configNodeIds :: NodeIds
  , configElectionTimeout :: Int
  , configElectionHeartbeat :: Int
  }

data Entry v = Entry
  { entryTerm :: Term
    -- ^ term when entry was received by leader
  , entryIndex :: Int
    -- ^ index of entry in the log
  , entryValue :: v
    -- ^ command to update state machine
  }

-- | State saved to disk before issuing any RPC
data PersistentState a = PersistentState
  { psCurrentTerm :: Term
    -- ^ Last term server has seen
  , psVotedFor :: Maybe NodeId
    -- ^ candidate id that received vote in current term
  , psLog :: [Entry a]
    -- ^ log entries; each entry contains command for state machine
  }

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

data Timeout = ElectionTimeout

data Event v
  = Message (Message v)
  | Timeout Timeout

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

data Action v
  = SendMessage NodeId (Message v)
  | Broadcast NodeIds (Message v)
  | ResetElectionTimeout

--------------------------------------------------------------------------------
-- Node States
--------------------------------------------------------------------------------

data FollowerState = FollowerState
  { fsCommitIndex :: Index
    -- ^ index of highest log entry known to be committed
  , fsLastApplied :: Index
    -- ^ index of highest log entry applied to state machine
  }

data CandidateState = CandidateState
  { csCommitIndex :: Index
    -- ^ index of highest log entry known to be committed
  , csLastApplied :: Index
    -- ^ index of highest log entry applied to state machine
  , csVotes :: Set NodeId
  }

data LeaderState = LeaderState
  { lsCommitIndex :: Index
    -- ^ index of highest log entry known to be committed
  , lsLastApplied :: Index
    -- ^ index of highest log entry applied to state machine
  , lsNextIndex :: Map NodeId Index
    -- ^ for each server, index of the next log entry to send to that server
  , lsMatchIndex :: Map NodeId Index
    -- ^ for each server, index of highest log entry known to be replicated on server
  }

--------------------------------------------------------------------------------
-- RPCs
--------------------------------------------------------------------------------

data Message v = RPC
  { sender :: NodeId
  , rpc :: RPC v
  }

data RPC v
  = AppendEntriesRPC (AppendEntries v)
  | AppendEntriesResponseRPC AppendEntriesResponse
  | RequestVoteRPC RequestVote
  | RequestVoteResponseRPC RequestVoteResponse

class RPCType a v where
  toRPC :: a -> RPC v

instance RPCType (AppendEntries v) v where
  toRPC = AppendEntriesRPC

instance RPCType (AppendEntriesResponse) v where
  toRPC = AppendEntriesResponseRPC

instance RPCType (RequestVote) v where
  toRPC = RequestVoteRPC

instance RPCType (RequestVoteResponse) v where
  toRPC = RequestVoteResponseRPC

data AppendEntries v = AppendEntries
  { aeTerm :: Term
    -- ^ leader's term
  , aeLeaderId :: NodeId
    -- ^ so follower can redirect clients
  , aePrevLogIndex :: Index
    -- ^ index of log entry immediately preceding new ones
  , aePrevLogTerm :: Term
    -- ^ term of aePrevLogIndex entry
  , aeEntries :: [Entry v]
    -- ^ log entries to store (empty for heartbeat)
  , aeLeaderCommit :: Index
    -- ^ leader's commit index
  }

data AppendEntriesResponse = AppendEntriesResponse
  { aerTerm :: Term
    -- ^ current term for leader to update itself
  , aerSuccess :: Bool
    -- ^ true if follower contained entry matching aePrevLogIndex and aePrevLogTerm
  }

data RequestVote = RequestVote
  { rvTerm :: Term
    -- ^ candidates term
  , rvCandidateId :: NodeId
    -- ^ candidate requesting vote
  , rvLastLogIndex :: Index
    -- ^ index of candidate's last log entry
  , rvLastLogTerm :: Term
    -- ^ term of candidate's last log entry
  }

data RequestVoteResponse = RequestVoteResponse
  { rvrTerm :: Term
    -- ^ current term for candidate to update itself
  , rvrVoteGranted :: Bool
    -- ^ true means candidate recieved vote
  }
