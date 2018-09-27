{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators #-}

module Raft where

import Protolude

import Control.Monad.Writer.Strict

import Data.Type.Bool

-- import Raft.Follower
-- import Raft.Candidate
-- import Raft.Leader
import Raft.Monad
import Raft.Types

handleEvent :: NodeConfig -> NodeState s -> Event v -> (ResultState s, [Action v])
handleEvent nodeConfig nodeState event =
  runTransitionM nodeConfig $
    case nodeState of
      NodeFollowerState fs -> undefined
      NodeCandidateState cs -> undefined
      NodeLeaderState ls -> undefined
