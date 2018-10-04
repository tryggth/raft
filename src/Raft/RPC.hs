
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Raft.RPC where

import Protolude

import Raft.Log
import Raft.Types

data Message v = RPC
  { sender :: NodeId
  , rpc :: RPC v
  } deriving (Show)

data RPC v
  = AppendEntriesRPC (AppendEntries v)
  | AppendEntriesResponseRPC AppendEntriesResponse
  | RequestVoteRPC RequestVote
  | RequestVoteResponseRPC RequestVoteResponse
  deriving (Show)

class RPCType a v where
  toRPC :: a -> RPC v

instance RPCType (AppendEntries v) v where
  toRPC = AppendEntriesRPC

instance RPCType AppendEntriesResponse v where
  toRPC = AppendEntriesResponseRPC

instance RPCType RequestVote v where
  toRPC = RequestVoteRPC

instance RPCType RequestVoteResponse v where
  toRPC = RequestVoteResponseRPC

rpcTerm :: RPC v -> Term
rpcTerm = \case
  AppendEntriesRPC ae -> aeTerm ae
  AppendEntriesResponseRPC aer -> aerTerm aer
  RequestVoteRPC rv -> rvTerm rv
  RequestVoteResponseRPC rvr -> rvrTerm rvr

data AppendEntries v = AppendEntries
  { aeTerm :: Term
    -- ^ leader's term
  , aeLeaderId :: LeaderId
    -- ^ so follower can redirect clients
  , aePrevLogIndex :: Index
    -- ^ index of log entry immediately preceding new ones
  , aePrevLogTerm :: Term
    -- ^ term of aePrevLogIndex entry
  , aeEntries :: Seq (Entry v)
    -- ^ log entries to store (empty for heartbeat)
  , aeLeaderCommit :: Index
    -- ^ leader's commit index
  } deriving (Show)

data AppendEntriesResponse = AppendEntriesResponse
  { aerTerm :: Term
    -- ^ current term for leader to update itself
  , aerSuccess :: Bool
    -- ^ true if follower contained entry matching aePrevLogIndex and aePrevLogTerm
  } deriving (Show)

data RequestVote = RequestVote
  { rvTerm :: Term
    -- ^ candidates term
  , rvCandidateId :: NodeId
    -- ^ candidate requesting vote
  , rvLastLogIndex :: Index
    -- ^ index of candidate's last log entry
  , rvLastLogTerm :: Term
    -- ^ term of candidate's last log entry
  } deriving (Show)

data RequestVoteResponse = RequestVoteResponse
  { rvrTerm :: Term
    -- ^ current term for candidate to update itself
  , rvrVoteGranted :: Bool
    -- ^ true means candidate recieved vote
  } deriving (Show)
