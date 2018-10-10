{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TupleSections #-}

module Raft.Candidate (
    handleAppendEntries
  , handleAppendEntriesResponse
  , handleRequestVote
  , handleRequestVoteResponse
  , handleTimeout
  , handleClientRequest
) where

import Protolude

import Control.Monad.Writer (tell)

import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.Sequence as Seq

import Raft.NodeState
import Raft.RPC
import Raft.Client
import Raft.Event
import Raft.Action
import Raft.Persistent
import Raft.Config
import Raft.Log
import Raft.Monad
import Raft.Types

--------------------------------------------------------------------------------
-- Candidate
--------------------------------------------------------------------------------

handleAppendEntries :: RPCHandler 'Candidate (AppendEntries v) v
handleAppendEntries (NodeCandidateState candidateState@CandidateState{..}) sender AppendEntries {..} = do
  currentTerm <- gets psCurrentTerm
  if currentTerm <= aeTerm
    then stepDown sender aeTerm csCommitIndex csLastApplied
    else pure $ candidateResultState Noop candidateState

-- | Candidates should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Candidate AppendEntriesResponse v
handleAppendEntriesResponse (NodeCandidateState candidateState) _sender _appendEntriesResp =
  pure $ candidateResultState Noop candidateState

handleRequestVote :: RPCHandler 'Candidate RequestVote v
handleRequestVote (NodeCandidateState candidateState@CandidateState{..}) sender requestVote@RequestVote{..} = do
  currentTerm <- gets psCurrentTerm
  if rvTerm > currentTerm
    then stepDown sender rvTerm csCommitIndex csLastApplied
    else do
      send sender (RequestVoteResponse currentTerm False)
      pure $ candidateResultState Noop candidateState

-- | Candidates should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: forall v. RPCHandler 'Candidate RequestVoteResponse v
handleRequestVoteResponse (NodeCandidateState candidateState@CandidateState{..}) sender requestVoteResp@RequestVoteResponse{..} = do
  currentTerm <- gets psCurrentTerm
  cNodeIds <- asks configNodeIds
  if
      -- | rvrTerm < currentTerm -> DT.trace ("rvrTerm: " ++ show rvrTerm ++ ",
      --currentTerm: " ++ show currentTerm) pure $ candidateResultState Noop
      --candidateState
      | rvrTerm > currentTerm -> stepDown sender rvrTerm csCommitIndex csLastApplied
      | not rvrVoteGranted -> pure $ candidateResultState Noop candidateState
      | Set.member sender csVotes -> pure $ candidateResultState Noop candidateState
      | otherwise -> do
          let newCsVotes = Set.insert sender csVotes

          if not $ hasMajority cNodeIds newCsVotes
            then pure $ candidateResultState Noop candidateState
            else leaderResultState BecomeLeader <$> becomeLeader csCommitIndex csLastApplied

  where
    hasMajority :: Set a -> Set b -> Bool
    hasMajority totalNodeIds votes =
      Set.size votes >= Set.size totalNodeIds `div` 2 + 1

    becomeLeader :: Index -> Index -> TransitionM v LeaderState
    becomeLeader commitIndex lastApplied = do
      resetHeartbeatTimeout
      selfNodeId <- asks configNodeId
      currentTerm <- gets psCurrentTerm
      (logEntryIndex, logEntryTerm) <-
        lastLogEntryIndexAndTerm <$> gets psLog
      broadcast AppendEntries { aeTerm = currentTerm
                              , aeLeaderId = LeaderId selfNodeId
                              , aePrevLogIndex = logEntryIndex
                              , aePrevLogTerm = logEntryTerm
                              , aeEntries = Seq.Empty :: Seq.Seq (Entry v)
                              , aeLeaderCommit = index0
                              }

      cNodeIds <- asks configNodeIds
      pure LeaderState
              { lsCommitIndex = commitIndex
              , lsLastApplied = lastApplied
              , lsNextIndex = Map.fromList $
                  (,incrIndex logEntryIndex) <$> Set.toList cNodeIds
              , lsMatchIndex = Map.fromList $
                  (,index0) <$> Set.toList cNodeIds
              -- ^ We use index0 as the new leader doesn't know yet what
              -- the highest log has been seen by other nodes
              }

handleTimeout :: TimeoutHandler 'Candidate v
handleTimeout (NodeCandidateState candidateState@CandidateState{..}) timeout =
  case timeout of
    HeartbeatTimeout -> pure $ candidateResultState Noop candidateState
    ElectionTimeout ->
      candidateResultState RestartElection <$>
        updateElectionTimeoutCandidateState csCommitIndex csLastApplied

-- | When candidates handle a client request, they respond with NoLeader, as the
-- very reason they are candidate is because there is no leader. This is done
-- instead of simply not responding such that the client can know that the node
-- is live but that there is an election taking place.
handleClientRequest :: ClientReqHandler 'Candidate v
handleClientRequest (NodeCandidateState candidateState) (ClientWriteReq clientId _) = do
  redirectClientToLeader clientId NoLeader
  pure (candidateResultState Noop candidateState)


--------------------------------------------------------------------------------

stepDown
  :: NodeId
  -> Term
  -> Index
  -> Index
  -> TransitionM a (ResultState 'Candidate v)
stepDown sender term commitIndex lastApplied = do
  resetElectionTimeout
  pure $ ResultState DiscoverLeader $
    NodeFollowerState FollowerState
      { fsCurrentLeader = CurrentLeader (LeaderId sender)
      , fsCommitIndex = commitIndex
      , fsLastApplied = lastApplied
      }
