module Elea.Testing 
(
  Test, M, execute,
  label, list, run, 
  assert, assertEq, assertNot,
  assertSimpEq,
  loadPrelude, loadFile,
  term, _type,
  simplifiedTerm,
  fusedTerm,
  assertProvablyEq,
  assertTermEq,
  localVars,
) 
where

import Elea.Prelude hiding ( assert )
import Elea.Term
import Elea.Type
import Elea.Show
import Elea.Monad.Edd ( Edd )
import qualified Elea.Monad.Edd as Edd
import qualified Elea.Monad.Env as Env
import qualified Elea.Parser.Calculus as Parse
-- import qualified Elea.Simplifier as Simp
-- import qualified Elea.Equality as Equality
-- import qualified Elea.Fusion as Fusion
import qualified Elea.Monad.Parser.Class as Parser
import qualified Elea.Monad.Error.Class as Err
import qualified Elea.Monad.Fusion.Class as Fusion
import qualified Test.HUnit as HUnit

type Test = HUnit.Test
type M = Edd

execute :: Test -> IO ()
execute test = do
  HUnit.runTestTT test
  return ()

list :: [Test] -> Test
list = HUnit.TestList

label :: String -> Test -> Test
label = HUnit.TestLabel

run :: HUnit.Testable t => Edd t -> Test
run = HUnit.test . Edd.eval . Discovery.trace

assert :: HUnit.Assertable t => t -> Test
assert = HUnit.TestCase . HUnit.assert

assertNot :: Bool -> Test
assertNot = assert . not

assertEq :: (Show a, Eq a) => a -> a -> Test
assertEq = (HUnit.TestCase .) . HUnit.assertEqual ""

prelude :: String
prelude = unsafePerformIO
  $ readFile "prelude.elea"
  
loadFile :: Defs.Has m => String -> m [Equation]
loadFile = id
  . Err.noneM 
  . liftM (map uninterpreted) 
  . Parse.program 
  . unsafePerformIO 
  . readFile

loadPrelude :: Defs.Has m => m ()
loadPrelude = do
  eqs <- Err.noneM (Parse.program prelude)
  return ()

term :: (Defs.Has m, Env.Read m) => String -> m Term
term = Err.noneM . Parse.term

_type :: Defs.Has m => String -> m Type
_type = Err.noneM . Parse._type

localVars :: (Parser.State m, Env.Write m) => String -> m a -> m a
localVars bs_s run = do
  bs <- Err.noneM (Parse.bindings bs_s)
  Env.bindMany bs $ do
    zipWithM defineBind [0..length bs - 1] (reverse bs)
    run
  where
  defineBind idx (Bind lbl _) =
    Parser.defineTerm lbl p_term
    where
    p_term = polymorphic [] (const (Var (enum idx)))
    
{-
assertSimpEq :: Term -> Term -> Test
assertSimpEq (Simp.run -> t1) (Simp.run -> t2) = 
  assertEq t1 t2
  
simplifiedTerm :: (Defs.Has m, Env.Read m) => String -> m Term
simplifiedTerm = liftM Simp.run . term

fusedTerm :: (Defs.Has m, Fusion.FusionM m) => String -> m Term
fusedTerm = Fusion.run <=< term

assertProvablyEq :: Fusion.FusionM m => Term -> Term -> m Test
assertProvablyEq t1 t2 = do
  mby_eq <- runMaybeT (Equality.prove Fusion.run t1 t2)
  t1s <- showM t1
  t2s <- showM t2
  let prop_s = "\nexpected: " ++ t1s ++ "\nbut got: " ++ t2s
  return 
    . HUnit.TestCase   
    . HUnit.assertBool prop_s
    $ fromMaybe False mby_eq
  
assertTermEq :: Fusion.FusionM m => Term -> Term -> m Test
assertTermEq t1 t2 = do
  t1s <- showM t1
  t2s <- showM t2
  let prop_s = "\nexpected: " ++ t1s ++ "\nbut got: " ++ t2s
  return 
    . HUnit.TestCase
    . HUnit.assertBool prop_s 
    $ t1 == t2
-}
