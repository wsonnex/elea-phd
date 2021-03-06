module Elea.Tests.Fusion
(
  tests  
)
where

import Elea.Prelude
import Elea.Term
import Elea.Testing ( Test )
import qualified Elea.Monad.Env as Env
import qualified Elea.Transform.Simplify as Simp
import qualified Elea.Monad.Transform as Transform
import qualified Elea.Testing as Test
import qualified Elea.Monad.Error.Class as Err
import qualified Elea.Transform.Fusion as Fusion
import qualified Elea.Monad.Definitions as Defs
import qualified Elea.Monad.Transform.TraceSteps as TraceSteps

testProp :: String -> Test 
testProp prop_name = id
  . Test.testWithPrelude prop_name $ do
    all_props <- Test.loadFile properties_file
    let Just (Prop _ prop_t _) = find ((== prop_name) . get propName) all_props
    prop_t' <- id
      . Test.recordTimeTaken prop_name 
      . TraceSteps.enable
      $ Fusion.applyM prop_t
    Test.assertTermEq "" truth prop_t'

tests :: IO Test
tests = do
  prop_names <- Test.loadPropertyNamesFromFile properties_file
  return 
    . Test.label "Fusion"
    . Test.list 
    . map testProp 
   -- . filter (== "zeno55")
    $ prop_names

properties_file :: String
properties_file = "src/Elea/Tests/fusion.elea"
