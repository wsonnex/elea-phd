module Elea.Tests.Term
(
  tests
)
where

import Elea.Prelude
import Elea.Term
import Elea.Term.Ext
import Elea.Type
import Elea.Testing ( Test )
import Elea.Monad.Fedd.Include ()
import qualified Elea.Term.Index as Indices
import qualified Elea.Monad.Env as Env
import qualified Elea.Unification as Unifier
import qualified Elea.Testing as Test
import qualified Elea.Transform.Evaluate as Eval
import qualified Elea.Transform.Simplify as Simp
import qualified Elea.Foldable as Fold
import qualified Elea.Foldable.WellFormed as WellFormed
import qualified Data.Set as Set

tests :: IO Test
tests = return
  . Test.label "Term" 
  . Test.list 
  $ [ testBuildFold, testDecreasing, testMakeContext
    -- , testRead   doesn't hold due to $names not having type args
    , testConjunction, testSubterms, testAbstract
    , testFindArgs, testRecursiveId, testEquateArgs, testStrictWithin ]

-- testMSG :: Test
-- whateva

testPUG :: Test 
testPUG = Test.test "generalisation" $ do
  return ()
  -- test (x + x) PUG (x + (Suc x))
  --    ==> ([x + y], x + (Suc y))
  -- test (rev (rev xs)) PUG (rev (snoc y (rev xs))) 
  --    ==> ([rev ys], rev (snoc y ys))
  -- test $(flatten t) PUG $(flatten t1 ++ [x] ++ flatten t2)
  --    ==> ([$(xs), $(ys)], $(xs ++ [x] ++ ys))
  -- test (q xs []) PUG (q xs [x]) 
  --    ==> ([q xs ys], q xs (x:ys))
-- should also test unfolding metrics, for example, whether a fixed point can
--  be immediately unrolled (whether it is consumed)
-- also test critical pair code with insertsort example
--  $(x:(xs ++ [n] ++ ys)) example
--  and div3/double
--  also even(Suc x)

-- critical pair code should NOT unfold
--    le x (Suc y)  for le-filter
--    le (Suc x) y  for parity with the above

-- separately test fissioning code, since it is now a completely separate function
--  or, it should be

testBuildFold :: Test
testBuildFold = 
  Test.testWithPrelude "build fold" $ do
    Test.assertSimpEq "fold: nat -> nat" 
      fold_nat_nat (buildFold nat (Base nat))
    Test.assertSimpEq "fold: tree<nat> -> list<nat>" 
      fold_ntree_nlist (buildFold ntree (Base nlist))
  where
  Base nat = read "nat"
  Base ntree = read "tree<nat>"
  Base nlist = read "list<nat>"

  fold_nat_nat = read
    $ "fun (v: nat) (k: nat -> nat) -> "
    ++  "fix (f: nat -> nat) (x: nat) -> "
    ++  "match x with | 0 -> v | Suc x' -> k (f x') end"

  fold_ntree_nlist = read
    $ "fun (v: list<nat>) (k: list<nat> -> nat -> list<nat> -> list<nat>) -> "
    ++  "fix (f: tree<nat> -> list<nat>) (t: tree<nat>) -> "
    ++  "match t with | Leaf -> v | Node t1 x t2 -> k (f t1) x (f t2) end"

testDecreasing :: Test
testDecreasing = Test.test "decreasing args" $ do
  Test.assertEq "eq decreases in all args" [0, 1] (decreasingAppArgs eq_n_0)
  Test.assertBool "zero is finite" (isFinite (read "0")) 
  Test.assertBool "eq n 0 should unfold" (any (isFinite . (args !!)) [0, 1])
  where
  eq_n_0@(App eq args) = read "env (n: nat) in eq n 0"

testRead :: Test
testRead = Test.test "read terms" $ do
  forM_ all_subterms 
    $ \t -> Test.assertBool (show t) ((WellFormed.is . readTerm . show) t)
  where
  readTerm :: String -> Term = read
  all_subterms = Fold.collectAll (readTerm def_take_drop)

testConjunction :: Test
testConjunction = 
  Test.test "conjunction" $ do
    Test.assertSimpEq "conjunction" 
      (read "fun (p q r: bool) -> and p (and q r)")
      (conjunction 3)
      
testSubterms :: Test
testSubterms = Test.test "subterms" $ do     
  Test.assertEq "free subterms" (Set.fromList [add_x_y]) (Set.fromList free_ts) 
  Test.assertEq "free vars 1" (Set.fromList [x, y]) free_vars
  Test.assertEq "free vars 2" free_vars free_vars2
  Test.assertEq "remove subterms" [add_stuff, two] removed_ts 
  where
  [x, y, one, two, add_x_y, add_stuff] = 
    Test.withEnv "(x y: nat)"
    ["x", "y", "1", "2", "add x y", "add (add x y) 1"]

  free_ts = freeSubtermsOf add_stuff
  free_vars = freeVarSet add_stuff
  free_vars2 = freeVarSet add_x_y
  removed_ts = removeSubterms [add_stuff, one, two, y]

testAbstract :: Test
testAbstract = Test.test "abstraction" $ do
  Test.assertTermEq "abstract vars" abs_xy abs_xy'
  Test.assertTermEq "abstract term" abs_xxy abs_xxy'
  where
  [xy, x, y, abs_xy, xxy, abs_xxy] = Test.withEnv "(x y: nat)" 
    [ "add x y", "x", "y", "fun (x y: nat) -> add y x"
    , "add x (add x y)", "fun (n: nat) -> add x n"]
  abs_xy' = abstractVars [y, x] xy
  abs_xxy' = abstractTerm xy xxy 
    
testFindArgs :: Test
testFindArgs = Test.test "find args" $ do
  Test.assertTermEq "findArgs" ctx_arg arg
  where
  [ctx_t, in_ctx, ctx_arg] = 
    Test.withEnv "(f: list<nat> -> list<nat>) (xs: list<nat>) (n x: nat)"
    [ "fun (ys: list<nat>) -> Cons<nat> n ys"
    , "Cons<nat> n (append<nat> (f xs) (Cons<nat> x Nil<nat>))"
    , "append<nat> (f xs) (Cons<nat> x Nil<nat>)" ]

  Just [arg] = findArguments ctx_t in_ctx
    
testRecursiveId :: Test
testRecursiveId = Test.test "recursive id" $ do
  Test.assertTermEq "eval" (read def_nat_id) (Eval.apply (recursiveId nat))
  where
  Base nat = read "nat"

testEquateArgs :: Test
testEquateArgs = Test.test "equateArgs" $ do
  let t2' = equateArgs 0 2 t1
  Test.assertEq "equate 0 2" t2 t2' 
  
  let t3' = equateArgs 1 2 t2
  Test.assertEq "equate 1 2" t3 t3'
      
  let t3'' = equateArgsMany [(0, 2), (1, 3)] t1
  Test.assertEq "equate many" t3 t3''
  where
  [t1, t2, t3] = Test.withEnv "(f: nat -> nat -> nat -> nat -> nat)"
    [ "fun (a b c d: nat) -> f a b c d"
    , "fun (a b d: nat) -> f a b a d"
    , "fun (a b: nat) -> f a b a b" ]


testStrictWithin :: Test
testStrictWithin = Test.test "strictWithin" $ do
  let strict1' = strictWithin t1
      strict1 = Set.fromList [x, y]
      
  let strict2' = strictWithin t2
      strict2 = strict1
  Test.assertEq "strict within list" strict1 strict1' 
  Test.assertEq "strict in term" strict2 strict2'
  where
  [t1, x, y, t2] = Test.withEnv "(x y z: nat)"
    [ def_strict_test, "x", "y", "not (eq x y)" ]


testMakeContext :: Test 
testMakeContext = Test.test "makeContext" $ do
  let add = read "add"
      mul = read "mul"
      id_ctx = makeContext id (toBind add)
  Test.assertEq "identity context" mul (reduce id_ctx [mul])

  let mkAddCtx gap_t = reduce (read "fun (y x: nat) -> add x y") [gap_t]
      add_ctx = makeContext mkAddCtx (toBind (read "env (x: nat) in x"))  
  Test.assertEq "add x (add y z) context" 
    (read "env (y z: nat) in fun (x: nat) -> add x (add y z)") 
    (reduce add_ctx [read "env (y z: nat) in add y z"])


def_eq_unit, def_eq_bool, def_eq, def_eq_ntree :: String
def_eq_unit = 
  "fun (u v: unit) -> True"
def_eq_bool =
  "fun (p q: bool) -> if p then q else not q"
def_eq =
  "fix (eq: nat -> nat -> bool) (x y: nat) -> "
  ++ "match x with "
  ++ "| 0 -> match y with | 0 -> True | Suc y' -> False end "
  ++ "| Suc x' -> match y with | 0 -> False | Suc y' -> eq x' y' end "
  ++ "end"
def_eq_ntree =
  "fix (eq: tree<nat> -> tree<nat> -> bool) (t t': tree<nat>) -> "
  ++ "match t with "
  ++ "| Leaf -> match t' with | Leaf -> True | Node t1' x' t2' -> False end "
  ++ "| Node t1 x t2 -> match t' with "
    ++ "| Leaf -> False "
    ++ "| Node t1' x' t2' -> and (eq t1 t1') (and (eq[nat] x x') (eq t2 t2')) "
    ++ "end end"
    
def_add_raw =
  "fix (add: nat -> nat -> nat) (y: nat) (x: nat) -> "
  ++ "match x with | 0 -> y | Suc x' -> Suc (add y x') end"
  
def_nat_id = 
  "fix (id: nat -> nat) (x: nat) -> "
  ++ "match x with | 0 -> 0 | Suc x' -> Suc (id x') end"
  
def_strict_test = 
  "match x with "
  ++ "| 0 -> match y with | 0 -> False | Suc y' -> eq z z end "
  ++ "| Suc x' -> eq y z end"
    
def_take_drop = unlines
  [ "fun (n: nat) (xs: list<nat>) -> "
  , "(fix (take: nat -> list<nat> -> nat -> list<nat> -> list<nat>) (n1: nat) (xs1: list<nat>) (n2: nat) (xs2: list<nat>) -> "
  , "match n2 with"
  , "| 0  -> drop<nat> n1 xs1"
  , "| Suc n' ->"
  ,   "match xs2 with"
  ,    "| Nil  -> drop<nat> n1 xs1"
  ,    "| Cons y ys -> Cons<nat> y (take n1 xs1 n' ys)"
  ,    "end"
  ,  "end) n xs n xs" ]