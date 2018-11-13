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

import qualified Data.Set as Set
import qualified Data.Map as Map

import Raft.NodeState
import Raft.RPC
import Raft.Client
import Raft.Event
import Raft.Action
import Raft.Persistent
import Raft.Config
import Raft.Monad
import Raft.Types

--------------------------------------------------------------------------------
-- Candidate
--------------------------------------------------------------------------------

handleAppendEntries :: RPCHandler 'Candidate sm (AppendEntries v) v
handleAppendEntries (NodeCandidateState candidateState@CandidateState{..}) sender AppendEntries {..} = do
  currentTerm <- gets currentTerm
  if currentTerm <= aeTerm
    then stepDown sender aeTerm csCommitIndex csLastApplied csLastLogEntryData
    else pure $ candidateResultState Noop candidateState

-- | Candidates should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Candidate sm AppendEntriesResponse v
handleAppendEntriesResponse (NodeCandidateState candidateState) _sender _appendEntriesResp =
  pure $ candidateResultState Noop candidateState

handleRequestVote :: RPCHandler 'Candidate sm RequestVote v
handleRequestVote ns@(NodeCandidateState candidateState@CandidateState{..}) sender requestVote@RequestVote{..} = do
  currentTerm <- gets currentTerm
  send sender $
    SendRequestVoteResponseRPC $
      RequestVoteResponse currentTerm False
  pure $ candidateResultState Noop candidateState

-- | Candidates should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: forall sm v. RPCHandler 'Candidate sm RequestVoteResponse v
handleRequestVoteResponse (NodeCandidateState candidateState@CandidateState{..}) sender requestVoteResp@RequestVoteResponse{..} = do
  currentTerm <- gets currentTerm
  if  | Set.member sender csVotes -> pure $ candidateResultState Noop candidateState
      | not rvrVoteGranted -> pure $ candidateResultState Noop candidateState
      | otherwise -> do
          let newCsVotes = Set.insert sender csVotes
          cNodeIds <- asks (configNodeIds . nodeConfig)
          if not $ hasMajority cNodeIds newCsVotes
            then do
              let newCandidateState = candidateState { csVotes = newCsVotes }
              pure $ candidateResultState Noop newCandidateState
            else leaderResultState BecomeLeader <$> becomeLeader

  where
    hasMajority :: Set a -> Set b -> Bool
    hasMajority nids votes =
      Set.size votes >= Set.size nids `div` 2 + 1

    becomeLeader :: TransitionM sm v LeaderState
    becomeLeader = do
      currentTerm <- gets currentTerm
      resetHeartbeatTimeout
      broadcast $ SendAppendEntriesRPC
        AppendEntriesData
          { aedTerm = currentTerm
          , aedLeaderCommit = csCommitIndex
          , aedEntriesSpec = NoEntries FromHeartbeat
          }
      cNodeIds <- asks (configNodeIds . nodeConfig)
      let (lastLogEntryIdx, lastLogEntryTerm) = csLastLogEntryData
      pure LeaderState
       { lsCommitIndex = csCommitIndex
       , lsLastApplied = csLastApplied
       , lsNextIndex = Map.fromList $
           (,incrIndex lastLogEntryIdx) <$> Set.toList cNodeIds
       , lsMatchIndex = Map.fromList $
           (,index0) <$> Set.toList cNodeIds
       -- We use index0 as the new leader doesn't know yet what
       -- the highest log has been seen by other nodes
       , lsLastLogEntryData = (lastLogEntryIdx, lastLogEntryTerm, Nothing)
       }

handleTimeout :: TimeoutHandler 'Candidate sm v
handleTimeout (NodeCandidateState candidateState@CandidateState{..}) timeout =
  case timeout of
    HeartbeatTimeout -> pure $ candidateResultState Noop candidateState
    ElectionTimeout ->
      candidateResultState RestartElection <$>
        startElection csCommitIndex csLastApplied csLastLogEntryData

-- | When candidates handle a client request, they respond with NoLeader, as the
-- very reason they are candidate is because there is no leader. This is done
-- instead of simply not responding such that the client can know that the node
-- is live but that there is an election taking place.
handleClientRequest :: ClientReqHandler 'Candidate sm v
handleClientRequest (NodeCandidateState candidateState) (ClientRequest clientId _) = do
  redirectClientToLeader clientId NoLeader
  pure (candidateResultState Noop candidateState)

--------------------------------------------------------------------------------

stepDown
  :: NodeId
  -> Term
  -> Index
  -> Index
  -> (Index, Term)
  -> TransitionM a sm (ResultState 'Candidate)
stepDown sender term commitIndex lastApplied lastLogEntryData = do
  send sender $
    SendRequestVoteResponseRPC $
      RequestVoteResponse
        { rvrTerm = term
        , rvrVoteGranted = True
        }
  resetElectionTimeout
  pure $ ResultState DiscoverLeader $
    NodeFollowerState FollowerState
      { fsCurrentLeader = CurrentLeader (LeaderId sender)
      , fsCommitIndex = commitIndex
      , fsLastApplied = lastApplied
      , fsLastLogEntryData = lastLogEntryData
      , fsEntryTermAtAEIndex = Nothing
      }
