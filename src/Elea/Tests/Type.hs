module Elea.Tests.Type
(
  tests
)
where

import Elea.Prelude
import Elea.Type hiding ( get )
import Elea.Testing ( Test )
import qualified Elea.Testing as Test

tests :: Test
tests = 
  Test.test "Type" $ do
    Test.assertBool "isBaseCase true" (isBaseCase true)
    Test.assertBool "isBaseCase zero" (isBaseCase zero)
    Test.assertEq "succ single rec arc" [0] (recursiveArgs succ)
    Test.assertBool "isRecursive nat" (isRecursive nat)
  where
  Base nat = read "nat"
  Base bool = read "bool"
  true = Constructor bool 0 []
  zero = Constructor nat 0 []
  succ = Constructor nat 1 []
