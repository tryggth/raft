{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE GADTs #-}

module Raft.Types where

import Protolude

type NodeId = ByteString
type NodeIds = Set NodeId

newtype Term = Term Int
newtype Index = Index Int

data NodeConfig = NodeConfig
  { configNodeId :: NodeId
  , configNodeIds :: NodeIds
  , configElectionTimeout :: Int
  , configElectionHeartbeat :: Int
  }

data Entry a = Entry
  { entryTerm :: Term
    -- ^ term when entry was received by leader
  , entryIndex :: Int
    -- ^ index of entry in the log
  , entryValue :: a
    -- ^ command to update state machine
  }

data PersistentState a = PersistentState
  { psCurrentTerm :: Term
    -- ^ Last term server has seen
  , psVotedFor :: Maybe NodeId
    -- ^ candidate id that received vote in current term
  , psLog :: [Entry a]
    -- ^ log entries; each entry contains command for state machine
  }

--------------------------------------------------------------------------------
-- Node States
--------------------------------------------------------------------------------

data NodeType
  = Follower
  | Candidate
  | Leader

type family StateNodeType a :: NodeType where
  StateNodeType FollowerState = Follower
  StateNodeType CandidateState = Candidate
  StateNodeType LeaderState = Leader

type family Find (x :: NodeType) (ys :: [NodeType]) where
    Find x '[]       = 'False
    Find x (x ': ys) = 'True
    Find x (y ': ys) = Find x ys

type family Transitions (s :: NodeType) where
  Transitions Follower = '[Follower, Candidate]
  Transitions Candidate = '[Follower, Candidate, Leader]
  Transitions Leader = '[Leader, Follower]

type IsValidTransition src dst = Find (StateNodeType dst) (Transitions (StateNodeType src)) ~ True

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

-- TODO Map RPC messages to their responses using types...

data AppendEntries a = AppendEntries
  { aeTerm :: Term
    -- ^ leader's term
  , aeLeaderId :: NodeId
    -- ^ so follower can redirect clients
  , aePrevLogIndex :: Index
    -- ^ index of log entry immediately preceding new ones
  , aePrevLogTerm :: Term
    -- ^ term of aePrevLogIndex entry
  , aeEntries :: [Entry a]
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
