------------------------------------------------------------------------
-- |
-- Module           : Reopt.Semantics.DeadRegisterElimination
-- Description      : A CFG pass to remove registers which are not used
-- Copyright        : (c) Galois, Inc 2015
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- Given a code block like
--    r0 := initial
--    r1 := f(r0)
--    r2 := g(initial)
--    fetch_and_execute { rax := r1 }
--
-- this code will remove the (unused) r2
------------------------------------------------------------------------
{-# LANGUAGE GADTs #-}

module Reopt.Semantics.DeadRegisterElimination (eliminateDeadRegisters) where

import           Control.Applicative ((<$>), (<*>))
import           Control.Lens
import           Control.Monad.State (State, evalState, gets, modify)
import           Data.Foldable (foldrM)
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.Set (Set)
import qualified Data.Set as S

import           Reopt.Semantics.Representation

eliminateDeadRegisters :: CFG -> CFG
eliminateDeadRegisters cfg = (cfgBlocks .~ newCFG) cfg
  where
    newCFG = M.unions [ liveRegisters cfg l | l <- M.keys (cfg ^. cfgBlocks)
                                            , case l of { DecompiledBlock _ -> True; _ -> False } ]
             
-- FIXME: refactor to be more efficient
traverseBlocks :: CFG
                  -> BlockLabel
                  -> (Block -> a)
                  -> (a -> a -> a -> a)
                  -> a
traverseBlocks cfg root f merge = go root
  where
    go l = case cfg ^. cfgBlocks . at l of
            Nothing -> error $ "label not found"
            Just b  -> let v = f b in
                        case blockTerm b of
                         Branch _ lb rb -> merge (go lb) v (go rb)
                         _              -> v

-- | Find the set of referenced registers, via a post-order traversal of the
-- CFG.
liveRegisters :: CFG -> BlockLabel -> Map BlockLabel Block
liveRegisters cfg root = evalState (traverseBlocks cfg root blockLiveRegisters merge) S.empty
  where
    merge l v r = M.union <$> (M.union <$> l <*> r) <*> v
      
blockLiveRegisters :: Block -> State (Set AssignId) (Map BlockLabel Block)
blockLiveRegisters b = do addIDs terminalIds
                          stmts' <- foldrM noteAndFilter [] (blockStmts b)
                          return $ M.singleton (blockLabel b) (b { blockStmts = stmts' })
  where
    terminalIds = case blockTerm b of
                   Branch v _ _      -> refsInValue v
                   FetchAndExecute s -> foldX86StateValue refsInValue s
    addIDs ids = modify (S.union ids)
    noteAndFilter stmt@(AssignStmt (Assignment v rhs)) ss
      = do v_in <- gets (S.member v)
           if v_in then
             do addIDs (refsInAssignRhs rhs)
                return (stmt : ss)
             else return ss
    noteAndFilter stmt@(Write loc rhs) ss    = do addIDs (refsInLoc loc)
                                                  addIDs (refsInValue rhs)
                                                  return (stmt : ss)

refsInAssignRhs :: AssignRhs tp -> Set AssignId
refsInAssignRhs rhs = case rhs of
                       EvalApp v      -> refsInApp v
                       SetUndefined _ -> S.empty
                       Read loc       -> refsInLoc loc

refsInApp :: App Value tp -> Set AssignId
refsInApp app = foldApp (\v s -> refsInValue v `S.union` s) S.empty app

refsInLoc :: StmtLoc tp -> Set AssignId
refsInLoc (MemLoc v _) = refsInValue v
refsInLoc _            = S.empty

refsInValue :: Value tp -> Set AssignId
refsInValue (AssignedValue (Assignment v _)) = S.singleton v
refsInValue _                                = S.empty
