{-# OPTIONS_GHC -Wall -fno-warn-name-shadowing #-}
{-# LANGUAGE ScopedTypeVariables, GADTs #-}
module Backends.D16Hoopl.Split where
import Control.Monad
import Compiler.Hoopl
import Backends.D16Hoopl.Expr
import Backends.D16Hoopl.IR
import Backends.D16Hoopl.OptSupport
import Prelude hiding ((<*>))
import Debug.Trace (trace)

{-
 -This pass splits expressions into assignments with a single binary, unary, or call expression.
 -This is necessary because we need to allocate registers for subexpressions and for instruction 
 -selection (as each assignment corresponds to 1 or 2 instructions for instruction selection. 
 -}

type SplitFact = Int
splitLattice :: DataflowLattice SplitFact
splitLattice = DataflowLattice {
    fact_name = "Temp counter",
    fact_bot = 0,
    fact_join = add }
    where
        add _ (OldFact old) (NewFact new) =
            let i = max old new 
                changeFlag = changeIf $ i /=old && i/= new
            in (changeFlag, i)
            

countNodes :: FwdTransfer Node SplitFact
countNodes = mkFTransfer ft
  where
    ft :: Node e x -> SplitFact -> Fact x SplitFact
    ft (Label _)            f = f
    ft (Assign _ _)         f = f + 1
    
    ft (Store _ _ _)          f = f
    ft (Branch l)           f = mapSingleton l f
    ft (Cond _ tl fl)       f =
        mkFactBase splitLattice [(tl,f + 1 ), (fl,f + 1)]
    ft (None _)             f = f
    ft (Return _)           _ = mapEmpty
        
    


splitExpr :: forall m . FuelMonad m => FwdRewrite m Node SplitFact
splitExpr = mkFRewrite split
  where
    split :: Node e x -> SplitFact -> m (Maybe (Graph Node e x))
    split (Assign v (Binop Div l r)) f =
        let (lst,left,i) = splitExpr l f
            (lst',right,_) = splitExpr r i
            graph = mkMiddles (lst ++ lst' ++ [(Assign v (Call "div" [left,right]))])
        in return $ Just graph
    split (Assign v (Binop Mul l r)) f =
        let (lst,left,i) = splitExpr l f
            (lst',right,_) = splitExpr r i
            graph = mkMiddles (lst ++ lst' ++ [(Assign v (Call "mul" [left,right]))])
        in return $ Just graph
    split (Assign v (Binop op l r)) f =
        let (lst,left,i) = splitExpr l f
            (lst',right,_) = splitExpr r i
            graph = mkMiddles (lst ++ lst' ++ [(Assign v (Binop op left right))])
        in return $ Just graph
    split (Assign v e) f = 
        let (lst,expr,_) = splitExpr e f
            graph = mkMiddles (lst ++ [(Assign v expr)])
        in  return $ Just graph
    split (Cond c l r) f = 
        let (lst,expr,_) = splitExpr c f
            graph = mkMiddles lst
        in  return $ Just $ graph <*> (mkLast (Cond expr l r))
--    split (None c@(Call name es)) f = trace ("Split call " ++ (show c)) $ 
--        let (lst,exprs,_) = fold_split es f
--            graph = mkMiddles lst
--        in return $ Just $ graph <*> ( mkMiddle $ None $ Call name exprs)
    split (None e) f=
        let (lst,expr,_) = splitExpr e f
            graph = mkMiddles lst
        in return $ Just $ graph <*> (mkMiddle (None expr))
    {-split (Store loc l@(Lit _) fl) f =-}
        {-let tmp = (Svar "tmp" (f+1) S_None)-}
            {-node = Assign (S tmp) l-}
        {-in return $ Just $ mkMiddles [node,Store loc (SVar tmp) fl]-}
    split n@(Store loc expr fl) f = trace ("Splitting node " ++ show n) $
        let (lst,expr',_) = splitExpr expr f
            tmp = Svar "tmp" (f+1) S_None
            graph = mkMiddles lst
        in return $ Just $ graph <*> (mkMiddles [Assign (S tmp) expr', Store loc expr' fl])
    split (Return e) f = 
        let (lst,expr,_) = fold_split e f
            graph = mkMiddles (lst)
        in  return $ Just $ graph <*> (mkLast (Return expr))
        
    split _ _ = 
        return $ liftM insnToG $ Nothing
    
    splitExpr :: Expr -> Int -> ([Node O O],Expr,Int)
    {-splitExpr node _ | trace ("SplitExpr " ++ show node) False = undefined-}
    splitExpr l@(Lit (Int _)) i =
        let tmp = (Svar "tmp" (i+1) S_None)
            node = (Assign (S tmp) l)
            in ([node], (SVar tmp), i+1)
    splitExpr l@(Load _ _) i =
        let tmp = (Svar "tmp" (i+1) S_None)
            node = (Assign (S tmp) l)
            in ([node], (SVar tmp), i+1)
    splitExpr (Binop Mul l r) i =
        let (l_nodes,l_e,l_i) = splitExpr l i
            (r_nodes,r_e,r_i) = splitExpr r l_i
            tmp = (Svar "tmp" (r_i+1) S_None)
            node = (Assign (S tmp) (Call "mul" [l_e,r_e]))
        in  (l_nodes ++ r_nodes ++ [node], SVar tmp, r_i+1)
    splitExpr (Binop Div l r) i =
        let (l_nodes,l_e,l_i) = splitExpr l i
            (r_nodes,r_e,r_i) = splitExpr r l_i
            tmp = (Svar "tmp" (r_i+1) S_None)
            node = (Assign (S tmp) (Call "div" [l_e,r_e]))
        in  (l_nodes ++ r_nodes ++ [node], SVar tmp, r_i+1)
    splitExpr (Binop op l r) i = 
        let (l_nodes,l_e,l_i) = splitExpr l i
            (r_nodes,r_e,r_i) = splitExpr r l_i
            tmp = (Svar "tmp" (r_i+1) S_None)
            node = (Assign (S tmp) (Binop op l_e r_e ))
            in (l_nodes ++ r_nodes ++ [node], (SVar tmp), r_i+1)
    splitExpr (Unop op e) i =
        let (e_nodes,e_e,e_i) = splitExpr e i
            tmp = (Svar "tmp" (e_i+1) S_None)
            node = (Assign (S tmp) (Unop op e_e ))
            in (e_nodes ++ [node], (SVar tmp), e_i+1)
    splitExpr (Call n es) i =
        let (nodes,exprs,i') = fold_split es i 
            tmp = (Svar "tmp" (i'+1) S_None)
            node = (Assign (S tmp) (Call n exprs))
            in (nodes ++ [node], (SVar tmp), i'+1)   
    splitExpr (PostAssign (SVar a) e) i =
        let tmp = (Svar "tmp" (i+1) S_None)
            nodes = [(Assign (S tmp) (SVar a)),Assign (S a) e]
        in  (nodes,SVar tmp,i+1)
    splitExpr (PreAssign (SVar a) e) i =
        let nodes = [Assign (S a) e]
        in  (nodes, SVar a, i)
    splitExpr e i = --trace ("Default splitExpr on " ++ (show e)) $
        ([],e,i)
    fold_split :: [Expr] -> Int -> ([Node O O],[Expr],Int)
    fold_split (e:rest) i =
        let (lst,new_e,i' ) = splitExpr e i
            (lst_rest,es,i'') = fold_split rest i'
        in  (lst ++ lst_rest, new_e:es, i'')
    fold_split [] i = 
        ([],[],i)
    
