module Elea.Tests.Context
(
  tests
)
where

import Elea.Prelude
import qualified Elea.Context as Context
import qualified Elea.Transform.Simplify as Simp
import qualified Elea.Monad.Env as Env
import qualified Elea.Testing as Test

context :: String -> Test.M Context.Context
context = liftM Context.fromLambda . Test.simplifiedTerm

tests = Test.label "Contexts"                                          
    $ Test.run $ do
  Test.loadPrelude
  
  test1 <- contextTest ctx1 sub1 aim1
 --  test2 <- contextTest ctx2 sub2 aim2
  test3 <- dropLambdasTest ctx3 aim3
  
  return $ Test.list [test1, {- test2, -} test3]       
  where
  ctx1 = "fun (gap:nat) (y:nat) -> add y gap"
  sub1 = "mul 1 2"
  aim1 = "fun (y:nat) -> add y (mul 1 2)"
  
  ctx2 = "fun (gap:nat) (x:nat) -> "
    ++ "match x with | 0 -> fun (y:nat) -> mul gap y "
    ++ "| Suc x' -> fun (y:nat) -> mul x' gap end"
  sub2 = "add 2 2"
  aim2 = "fun (x:nat) -> match x with "
    ++ "| 0 -> fun (y:nat) -> mul (add 2 2) y "
    ++ "| Suc x' -> fun (y:nat) -> mul x' (add 2 2) end"
    
  ctx3 = "fun (gap:nat->nat) (x:nat) (y:nat) -> add y (gap x)"
  aim3 = "fun (gap:nat) (y:nat) -> add y gap"
                                    
  
contextTest :: String -> String -> String -> Test.M Test.Test
contextTest ctx_s sub_s aim_s = do
  ctx <- context ctx_s
  sub <- Test.simplifiedTerm sub_s
  aim <- Test.simplifiedTerm aim_s
  let app = Context.apply ctx sub
      test1 = Test.assertEq aim app
      Just sub' = Context.strip ctx aim
      sub'' = Simp.run sub'
      test2 = Test.assertEq sub sub''
  return $ Test.list [test1, test2]
  
dropLambdasTest :: String -> String -> Test.M Test.Test
dropLambdasTest ctx_s aim_s = do
  ctx <- context ctx_s
  aim <- context aim_s
  let (_, dropped) = Context.dropLambdas ctx
  return (Test.assertEq aim dropped)
  
