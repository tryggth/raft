{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}

module TestUtils where

import Protolude

import Raft.NodeState
import qualified Raft.NodeState
import Raft.Types

isLeader :: RaftNodeState v -> Bool
isLeader (RaftNodeState rns) = Raft.NodeState.isLeader rns

isCandidate :: RaftNodeState v -> Bool
isCandidate (RaftNodeState rns) = Raft.NodeState.isCandidate rns

isFollower :: RaftNodeState v -> Bool
isFollower (RaftNodeState rns) = Raft.NodeState.isFollower rns

checkCurrentLeader :: RaftNodeState v -> CurrentLeader
checkCurrentLeader (RaftNodeState (NodeFollowerState FollowerState{..})) = fsCurrentLeader
checkCurrentLeader (RaftNodeState (NodeCandidateState _)) = NoLeader
checkCurrentLeader (RaftNodeState (NodeLeaderState _)) = NoLeader

getLastAppliedLog :: RaftNodeState v -> Index
getLastAppliedLog (RaftNodeState (NodeFollowerState FollowerState{..})) = fsLastApplied
getLastAppliedLog (RaftNodeState (NodeCandidateState CandidateState{..})) = csLastApplied
getLastAppliedLog (RaftNodeState (NodeLeaderState LeaderState{..})) = lsLastApplied

getCommittedLogIndex :: RaftNodeState v -> Index
getCommittedLogIndex (RaftNodeState (NodeFollowerState FollowerState{..})) = fsCommitIndex
getCommittedLogIndex (RaftNodeState (NodeCandidateState CandidateState{..})) = csCommitIndex
getCommittedLogIndex (RaftNodeState (NodeLeaderState LeaderState{..})) = lsCommitIndex
