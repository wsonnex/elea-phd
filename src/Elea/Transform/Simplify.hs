-- | An extension of 'Elea.Transform.Evaluate'. Slightly more heavyweight
-- transformations but fundamentally those which make terms smaller and simpler.
-- They do not require fusion and they do not need to make use of 'Elea.Embed'.
module Elea.Transform.Simplify
  ( Step, Env,
    apply, applyM, applyWithoutUnfoldM, steps )
where

import Elea.Prelude hiding ( run )
import Elea.Term
import qualified Elea.Term.Ext as Term
import qualified Elea.Type as Type
import qualified Elea.Term.Tag as Tag
import qualified Elea.Term.Index as Indices
import qualified Elea.Term.Constraint as Constraint
import qualified Elea.Monad.Env as Env
import qualified Elea.Unification as Unifier
import qualified Elea.Transform.Names as Step
import qualified Elea.Transform.Evaluate as Eval
import qualified Elea.Foldable as Fold
import qualified Elea.Foldable.WellFormed as WellFormed
import qualified Elea.Monad.Error.Assertion as Assert
import qualified Elea.Monad.Error.Class as Err
import qualified Elea.Monad.Failure.Class as Fail
import qualified Elea.Monad.Definitions as Defs
import qualified Elea.Monad.Fusion as Fusion
import qualified Elea.Monad.Memo.Class as Memo
import qualified Elea.Monad.Transform as Transform
import qualified Elea.Monad.Direction as Direction
import qualified Elea.Monad.StepCounter as Steps
import qualified Elea.Monad.Fedd as Fedd  
import qualified Elea.Monad.Transform.Signals as Signals

import qualified Data.Monoid as Monoid
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.Poset as Quasi
import qualified Control.Monad.Trans as Trans

-- TODO properly tweak step order
-- TODO awareness of being inside a pattern match to guide unrolling eagerness


type Env m = 
  ( Eval.Env m
  , Env.All m
  , Direction.Has m
  , Fusion.Env m
  , Steps.Limiter m )

type Step m = (Eval.Step m, Env m)

-- TODO remove occurrences of this, it's almost certainly gonna cause issues
apply :: Term -> Term
apply = Fedd.eval . applyM        
    
applyM :: (Steps.Limiter m, Env m) => Term -> m Term
applyM = id
  . Transform.clearContext
  . Transform.compose all_steps
  . WellFormed.check 
  where
  all_steps = []
    ++ Eval.transformSteps 
    ++ Eval.traverseSteps     
    ++ steps       
   
-- Bit of a hack which is needed for free-arg fusion
applyWithoutUnfoldM :: Env m => Term -> m Term
applyWithoutUnfoldM = id
  . Transform.clearContext
  . Transform.compose eval_and_constArg
  . WellFormed.check
  where
  eval_and_constArg = []
    ++ Eval.transformSteps
    ++ Eval.traverseSteps
    ++ [ Transform.step Step.ConstArgFusion constArg ]

{-# SPECIALISE steps :: [Transform.NamedStep (Fedd.FeddT IO)] #-}
{-# INLINEABLE steps #-}  
    
steps :: Env m => [Transform.NamedStep m]
steps =
  [ Transform.step Step.LambdaBranch caseFun
  , Transform.step Step.ConstArgFusion constArg
  , Transform.step Step.IdentityCase identityCase
  , Transform.step Step.SubtermFission constantFix
  , Transform.step Step.Unfold unfold
  , Transform.step Step.UnfoldCase unfoldCase ] 

-- | We do not want pattern matches to return function typed values,
-- so we add a new lambda above one if this is the case.
caseFun :: Step m => Term -> m Term
caseFun cse@(Case t alts) 
  | Just new_b <- mby_new_b = id
    . return
    . Lam new_b
    . Case (Indices.lift t) 
    $ map appAlt alts
  where
  alt_ts = map (get altInner) alts
  mby_new_b = potentialBinds alts
  
  potentialBinds :: [Alt] -> Maybe Bind
  potentialBinds = 
    msum . map findLam
    where
    findLam :: Alt -> Maybe Bind
    findLam (Alt _ _ (Lam b _)) = Just b
    findLam (Alt _ _ (Case _ alts)) = potentialBinds alts
    findLam _ = Nothing
  
  appAlt (Alt con bs alt_t) = id
    . Alt con bs
    $ Term.reduce alt_t [arg]
    where
    arg = Var (elength bs) (fromJust mby_new_b)
    
caseFun _ = Fail.here
  
  
-- | If an argument to a 'Fix' never changes in any recursive call
-- then we should float that lambda abstraction outside the 'Fix'.
constArg :: Step m => Term -> m Term
constArg term@(App fix@(Fix fix_info (Bind fix_name fix_ty) fix_t) args)
  | length arg_bs /= length args = Fail.here
  | otherwise = do
    Fail.when (length arg_idxs == 0)
    let fix' = removeConstArg pos
    
    -- Might as well simplify the constant argument before pushing it inside
    -- and possible duplicating it
    arg' <- Transform.restart (args !! pos)
    let args' = setAt (enum pos) arg' args
    
    -- Run evaluation to reduce all the new lambdas
    let term' = Term.reduce fix' args'
    Term.lookupFixName term' 
  where
  arg_idxs = Term.constantArgs fix ++ Term.unusedArgs fix
  pos = head arg_idxs
  
  -- Strip off the preceding lambdas of the function
  (arg_bs, fix_body) = flattenLam fix_t
  arg_count = length (Type.flatten fix_ty) - 1
  
  -- The index of the recursive call to the function within 'fix_body'
  fix_f = elength arg_bs :: Index

  -- Remove an argument to the function at the given position.
  removeConstArg :: Nat -> Term
  removeConstArg arg_i = id
    -- Add new outer lambdas to keep these` type of the term the same
    . unflattenLam (left_bs ++ [dropped_b])
    . flip app outer_args
    
    -- Need to make sure no variables are captured by these new outer lambdas
    . Indices.liftManyAt (nlength left_bs) 1 
    . Fix fix_info fix_b'
    
    -- Remove the argument everywhere it appears
    . Env.trackIndices 0
    . Fold.transformM removeArg
    
    -- Remove the lambda, and replace all occurrences of that variable
    -- with index 1 (here index 0 will be the fix variable)
    . Indices.substAt Indices.omega (Var 1 dropped_b)
    . Indices.liftAt 1
    . unflattenLam left_bs
    . Indices.substAt 0 (Var Indices.omega dropped_b)
    . unflattenLam right_bs
    $ fix_body
    where
    -- Lambdas to the left and right of the removed lambda
    (left_bs, dropped_b:right_bs) = splitAt (enum arg_i) arg_bs
    
    -- The arguments that will be applied outside the fix
    outer_args = zipWith (Var . enum) (reverse [1..arg_i]) left_bs
    
    -- The new type binding for the fix, with the given argument removed
    fix_b' = Bind fix_name fix_ty'
      where
      fix_ty' = id
        . Type.unflatten
        . removeAt arg_i
        $ Type.flatten fix_ty
    
    removeArg :: Term -> Env.TrackIndices Index Term
    removeArg term@(App (Var f _) args) = do   
      fix_f <- Env.tracked
      if fix_f == f
      then return (App (Var f fix_b') (removeAt arg_i args))
      else return term
    removeArg term = 
      return term
      
constArg _ = Fail.here


-- | Removes a pattern match which just returns the term it is matching upon.
identityCase :: Step m => Term -> m Term
identityCase (Case cse_t alts)
  | all isIdAlt alts = return cse_t
  where
  isIdAlt :: Alt -> Bool
  isIdAlt alt@(Alt con _ alt_t) = 
    alt_t == (patternTerm . altPattern) alt
identityCase _ = Fail.here


-- | Dunno if this ever comes up but if we have a fix without any occurrence
-- of the fix variable in the body we can just drop it.
uselessFix :: Step m => Term -> m Term
uselessFix (Fix _ _ fix_t)
  | not (0 `Set.member` Indices.free fix_t) = do
    Signals.tellStopRewriting
    return (Indices.lower fix_t)
uselessFix _ = Fail.here


-- | If a recursive function just returns the same value, regardless of its
-- inputs, just reduce it to that value.
constantFix :: Step m => Term -> m Term
constantFix t@(flattenApp -> Fix _ fix_b fix_t : args)  
  | length args /= length arg_bs = Fail.here
  
  | Just [result] <- mby_results
  , correctGuess result = do
    Direction.requireInc
    return result
  
  | Just [] <- mby_results
  , correctGuess (Bot result_ty) = do
    Direction.requireInc
    return (Bot result_ty)
  
  where
  (arg_bs, _) = flattenLam fix_t
  fix_ty = get Type.bindType fix_b
  result_ty = Type.Base (Type.returnType fix_ty)
  
  mkLam = id
    . unflattenLam rem_bs
    . Indices.liftMany (nlength rem_bs)
    where
    rem_bs = drop (length args) arg_bs
  
  mby_results = id
    . potentialResults
    . Eval.apply
    $ Indices.substAt 0 (Bot fix_ty) fix_t
  
  potentialResults :: Term -> Maybe [Term]
  potentialResults term
    | not (isCase (snd (flattenLam term))) = Nothing
    | otherwise = id
      . map toList
      . Env.trackOffset
      . runMaybeT
      . Fold.isoFoldM Term.branches resultTerm
      $ term
    where
    resultTerm :: Term -> MaybeT Env.TrackOffset (Set Term)
    resultTerm term
      | Term.isBot term = return mempty
      | otherwise = do
        depth <- Env.offset
        Fail.unless (Indices.lowerableBy depth term)
        return
          . Set.singleton
          $ Indices.lowerMany depth term
      
  correctGuess :: Term -> Bool
  correctGuess guess_t
    | Just [] <- mby_results' = True
    | Just [guess_t'] <- mby_results' =
    --  tracE [("orig", show t), ("guess", show guess_t), ("guess check", show guess_t')]
      guess_t == guess_t'
    | otherwise = False
    where
    rec_f = id
      . unflattenLam arg_bs
      . Indices.liftMany (nlength arg_bs)
      $ guess_t
      
    fix_t' = Eval.apply (Indices.substAt 0 rec_f fix_t)
    mby_results' = potentialResults fix_t'
        
constantFix _ = 
  Fail.here
  
  {-
-- | Unfolds a 'Fix' within itself if it can be unrolled at
-- at a point it is called recursively.
unfoldWithinFix :: Fail.Can m => Term -> m Term
unfoldWithinFix fix@(Fix fix_i fix_b fix_t) = do
  Fail.unless any_replaced
  return (Fix fix_i fix_b fix_t')
  where
  (fix_t', Monoid.Any any_replaced) = id
    . Env.trackIndices (0, fix_t)
    . runWriterT
    $ Fold.transformM unfold fix_t
  
  unfold :: Term -> WriterT Monoid.Any (Env.TrackIndices (Index, Term)) Term
  unfold term@(App (Var f) args) = do
    (fix_f, fix_t) <- Env.tracked
    if f /= fix_f || any (not . Term.isFinite) args
    then return term
    else do
      tell (Any True)
      (_, fix_t) <- Env.tracked
      return (Eval.run (app fix_t args))
  unfold other = 
    return other
  
unfoldWithinFix _ = Fail.here
          -}

-- | Removes a pattern match if every branch returns the same value.
constantCase :: forall m . Step m => Term -> m Term
constantCase (Case _ alts) = do
  Direction.requireInc
  (alt_t:alt_ts) <- mapM loweredAltTerm alts
  Fail.unless (all (== alt_t) alt_ts)
  return alt_t
    
constantCase _ = Fail.here

   
unfold :: Step m => Term -> m Term
unfold term@(App fix@(Fix {}) args)
  | any needsUnroll dec_args
  || all (isCon . leftmost) dec_args
  || cant_fix_con_fuse = do
    term' <- id
      . Transform.restart
      $ Term.reduce (Term.unfoldFix fix) args
    Fail.when (term Quasi.<= term')
    Signals.tellStopRewriting
    return term'
  where
  needsUnroll t = 
    Term.isBot t
    || Term.isFinite t 
    || (isCon (leftmost t) && not (Set.null (Tag.exceptOmega t)))
    
  cant_fix_con_fuse = 
    Type.isRecursive (Type.fromBase (Type.get term))
    && any (isCon . leftmost) dec_args
    
  dec_args = map (args !!) (Term.decreasingArgs fix)
  
unfold _ = Fail.here


floatVarMatch :: Step m => Term -> m Term
floatVarMatch term@(Case (App fix@(Fix {}) xs) _)
  | (not . any (isCon . leftmost)) dec_xs
  , (not . null) useful_ms = do
    let term' = Term.applyCases useful_ms term
    Assert.check (Type.assertEq term term')
      $ return term'
  where
  dec_xs = map (xs !!) (Term.decreasingArgs fix) 
  dec_ixs = (Set.fromList . map fromVar . filter isVar) dec_xs
  
  useful_ms = id
    . Env.trackOffset
    $ Fold.collectM usefulVarMatch term
  
  usefulVarMatch :: Term -> MaybeT Env.TrackOffset Term
  usefulVarMatch (Case (Var x b) alts) = do
    offset <- Env.tracked
    x' <- Indices.tryLowerMany (enum offset) x
    Fail.unless (x' `Set.member` dec_ixs)
    return (Case (Var x' b) (map blank alts))
    where
    blank (Alt con bs _) = Alt con bs empty
  usefulVarMatch _ = 
    Fail.here
    
floatVarMatch _ = Fail.here


unfoldCase :: Step m => Term -> m Term
unfoldCase term@(Case (flattenApp -> fix@(Fix {}) : xs) alts)
  | assert_fun || only_prod  = do
    let term' = Case (Term.reduce (Term.unfoldFix fix) xs) alts
    term'' <- Transform.restart term'
    Fail.when (term Quasi.<= term'')
    Signals.tellStopRewriting
    return term''
  where
  assert_fun = 
    any (isCon . leftmost) xs
    && Constraint.has term
    
  only_prod = 
    Term.isProductive fix 
    && Term.decreasingArgs fix == []
  
unfoldCase _ = Fail.here
