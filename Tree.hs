module Tree where
import Parse (Tree(..), OP(..), Type(..))
import Eval (funcop)
import Debug.Trace (trace)
import Control.Monad.State
import Control.Monad.Trans.Maybe
import Data.Map (Map)
import qualified Data.Map as M

m_apply :: (Tree -> EV Tree) -> Tree -> EV Tree 

m_apply f (Operator op left right) = do
    l <- m_apply f left
    r <- m_apply f right
    f (Operator op l r)
m_apply f (Assign left right) = do
    l <- m_apply f left
    r <- m_apply f right
    f (Assign l r)
m_apply f (List (x:xs)) =
    do
        item <- m_apply f x
        (List list') <- m_apply f (List xs)
        f (List (item:list'))
m_apply f (List []) = f (List [])
m_apply f (Return tree) = do
    tree' <- m_apply f tree
    f (Return tree')
m_apply f (If cond tree) = 
    do
        cond' <- m_apply f cond
        tree' <- m_apply f tree
        f (If cond' tree')
m_apply f (IfElse cond left right) = do
    c <- m_apply f cond
    l <- m_apply f left
    r <- m_apply f right
    f (IfElse c l r)

m_apply f (Compound left right) = do
    l <- m_apply f left
    r <- m_apply f right
    f (Compound l r)
m_apply f (FuncDec t str left right) = do
    l <- m_apply f left
    r <- m_apply f right
    f (FuncDec t str l r)
m_apply f (FCall str tree) = do
    t <- m_apply f tree
    f (FCall str t)

m_apply f tree = f tree
getFunctions (List lst) = [FuncDec t str decls body | (FuncDec t str decls body) <- lst]
getGlobals (List lst) = [VarDec t str | (VarDec t str) <- lst]

type SymTab = M.Map String (Integer)
type EV a = State SymTab a

lookUp :: String -> EV (Integer)
lookUp str = do
    symTab <- get
    case M.lookup str symTab of
        Just v -> return v
        Nothing -> error $ "Undefined variable " ++ str

addSymbol :: String -> Integer -> EV ()
addSymbol str val = do
    symTab <- get
    put $ M.insert str val symTab
    return ()
    

passes = [const_subexpr_simplification, constant_folding, const_subexpr_simplification]

run_passes (pass:passes) tree =
    let (tree',symTab) = runState (m_apply pass tree) (M.empty)
    
    in run_passes passes tree'
run_passes [] tree = tree

const_subexpr_simplification :: Tree -> EV Tree
const_subexpr_simplification (Operator op (Num l) (Num r)) =
    do 
    return (Num ((funcop op) l r))
const_subexpr_simplification tree = return tree

constant_folding :: Tree -> EV Tree

constant_folding (Assign (VarAssign v) (Num x)) = do
    addSymbol v x
    return (Assign (VarAssign v) (Num x))
constant_folding (Var v) = do
    symTab <- get    
    do 
    let val = M.lookup v symTab
    case val of
        (Just x) -> return (Num x)
        (Nothing) -> return (Var v)
        
constant_folding tree = return tree



