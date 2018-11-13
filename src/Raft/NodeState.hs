{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}

module Raft.NodeState where

import Protolude

import qualified Data.Serialize as S
import Data.Sequence (Seq(..))

import Raft.Log
import Raft.Types

data Mode
  = Follower
  | Candidate
  | Leader
  deriving (Show)

-- | All valid state transitions of a Raft node
data Transition (init :: Mode) (res :: Mode) where
  StartElection            :: Transition 'Follower 'Candidate
  HigherTermFoundFollower  :: Transition 'Follower 'Follower

  RestartElection          :: Transition 'Candidate 'Candidate
  DiscoverLeader           :: Transition 'Candidate 'Follower
  HigherTermFoundCandidate :: Transition 'Candidate 'Follower
  BecomeLeader             :: Transition 'Candidate 'Leader

  SendHeartbeat            :: Transition 'Leader 'Leader
  DiscoverNewLeader        :: Transition 'Leader 'Follower
  HigherTermFoundLeader    :: Transition 'Leader 'Follower

  -- TODO Replace with specific transition names
  Noop :: Transition init init

deriving instance Show (Transition init res)

-- | Existential type hiding the result type of a transition
data ResultState init v where
  ResultState :: Transition init res -> NodeState res -> ResultState init v

deriving instance Show (ResultState init v)

followerResultState
  :: Transition init 'Follower
  -> FollowerState
  -> ResultState init v
followerResultState transition fstate =
  ResultState transition (NodeFollowerState fstate)

candidateResultState
  :: Transition init 'Candidate
  -> CandidateState
  -> ResultState init v
candidateResultState transition cstate =
  ResultState transition (NodeCandidateState cstate)

leaderResultState
  :: Transition init 'Leader
  -> LeaderState
  -> ResultState init v
leaderResultState transition lstate =
  ResultState transition (NodeLeaderState lstate)

-- | Existential type hiding the internal node state
data RaftNodeState where
  RaftNodeState :: { unRaftNodeState :: NodeState s } -> RaftNodeState

nodeMode :: RaftNodeState -> Mode
nodeMode (RaftNodeState rns) =
  case rns of
    NodeFollowerState _ -> Follower
    NodeCandidateState _ -> Candidate
    NodeLeaderState _ -> Leader

-- TODO Take term last long entry term and index as argument
initRaftNodeState :: RaftNodeState
initRaftNodeState =
  RaftNodeState $
    NodeFollowerState FollowerState
      { fsCommitIndex = index0
      , fsLastApplied = index0
      , fsCurrentLeader = NoLeader
      , fsLastLogEntryData = (index0, term0)
      , fsEntryTermAtAEIndex = Nothing
      }

deriving instance Show RaftNodeState

-- | The volatile state of a Raft Node
data NodeState (a :: Mode) where
  NodeFollowerState :: FollowerState -> NodeState 'Follower
  NodeCandidateState :: CandidateState -> NodeState 'Candidate
  NodeLeaderState :: LeaderState -> NodeState 'Leader

deriving instance Show (NodeState v)

data CurrentLeader
  = CurrentLeader LeaderId
  | NoLeader
  deriving (Show, Eq, Generic)

instance S.Serialize CurrentLeader

data FollowerState = FollowerState
  { fsCurrentLeader :: CurrentLeader
    -- ^ The id of the current leader
  , fsCommitIndex :: Index
    -- ^ index of highest log entry known to be committed
  , fsLastApplied :: Index
    -- ^ index of highest log entry applied to state machine
  , fsLastLogEntryData :: (Index, Term)
    -- ^ the index and term of the last log entry in the node's log
  , fsEntryTermAtAEIndex :: Maybe Term
    -- ^ The term of the log entry specified in and AppendEntriesRPC
  } deriving (Show)

data CandidateState = CandidateState
  { csCommitIndex :: Index
    -- ^ index of highest log entry known to be committed
  , csLastApplied :: Index
    -- ^ index of highest log entry applied to state machine
  , csVotes :: NodeIds
    -- ^ votes from other nodes in the raft network
  , csLastLogEntryData :: (Index, Term)
    -- ^ the index and term of the last log entry in the node's log
  } deriving (Show)

data LeaderState = LeaderState
  { lsCommitIndex :: Index
    -- ^ index of highest log entry known to be committed
  , lsLastApplied :: Index
    -- ^ index of highest log entry applied to state machine
  , lsNextIndex :: Map NodeId Index
    -- ^ for each server, index of the next log entry to send to that server
  , lsMatchIndex :: Map NodeId Index
    -- ^ for each server, index of highest log entry known to be replicated on server
  , lsLastLogEntryData
      :: ( Index
         , Term
         , Maybe ClientId -- ^ The only time this will be Nothing is at term 1
         )
    -- ^ the index, term, and client id of the last log entry in the node's log
  } deriving (Show)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

setLastLogEntryData :: NodeState ns -> Entries v -> NodeState ns
setLastLogEntryData nodeState entries =
  case entries of
    Empty -> nodeState
    _ :|> e ->
      case nodeState of
        NodeFollowerState fs ->
          NodeFollowerState fs
            { fsLastLogEntryData = (entryIndex e, entryTerm e) }
        NodeCandidateState cs ->
          NodeCandidateState cs
            { csLastLogEntryData = (entryIndex e, entryTerm e) }
        NodeLeaderState ls ->
          NodeLeaderState ls
            { lsLastLogEntryData = (entryIndex e, entryTerm e, Just (entryClientId e)) }

getLastLogEntryData :: NodeState ns -> (Index, Term)
getLastLogEntryData nodeState =
  case nodeState of
    NodeFollowerState fs -> fsLastLogEntryData fs
    NodeCandidateState cs -> csLastLogEntryData cs
    NodeLeaderState ls -> let (peTerm, peIndex, _) = lsLastLogEntryData ls
                           in (peTerm, peIndex)

getLastAppliedAndCommitIndex :: NodeState ns -> (Index, Index)
getLastAppliedAndCommitIndex nodeState =
  case nodeState of
    NodeFollowerState fs -> (fsLastApplied fs, fsCommitIndex fs)
    NodeCandidateState cs -> (csLastApplied cs, csCommitIndex cs)
    NodeLeaderState ls -> (lsLastApplied ls, lsCommitIndex ls)

isFollower :: NodeState s  -> Bool
isFollower nodeState =
  case nodeState of
    NodeFollowerState _ -> True
    _ -> False

isCandidate :: NodeState s  -> Bool
isCandidate nodeState =
  case nodeState of
    NodeCandidateState _ -> True
    _ -> False

isLeader :: NodeState s  -> Bool
isLeader nodeState =
  case nodeState of
    NodeLeaderState _ -> True
    _ -> False
