{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}

module Raft.Types where

import Protolude

import Data.Sequence (Seq(Empty, (:<|)), (<|))
import qualified Data.Sequence as Seq
import Numeric.Natural (Natural)

--------------------------------------------------------------------------------
-- NodeIds
--------------------------------------------------------------------------------

type NodeId = ByteString
type NodeIds = Set NodeId

newtype ClientId = ClientId NodeId
  deriving (Show, Eq, Ord)

newtype LeaderId = LeaderId { unLeaderId :: NodeId }
  deriving (Show, Eq)

--------------------------------------------------------------------------------
-- Term
--------------------------------------------------------------------------------

newtype Term = Term Natural
  deriving (Show, Eq, Ord, Enum)

term0 :: Term
term0 = Term 0

incrTerm :: Term -> Term
incrTerm = succ

--------------------------------------------------------------------------------
-- Index
--------------------------------------------------------------------------------

newtype Index = Index Natural
  deriving (Show, Eq, Ord, Enum, Num, Integral, Real)

index0 :: Index
index0 = Index 0

incrIndex :: Index -> Index
incrIndex = succ

decrIndex :: Index -> Index
decrIndex (Index 0) = index0
decrIndex i = pred i
