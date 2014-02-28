-- | Where I put the monolithic run function, which solves the 
-- general problem of:
-- > if C[E] = E'
-- > then C = Inventor.run E E'
-- The first term argument @E@ should always be 
-- a fixpoint with all arguments applied.
module Elea.Inventor 
(
  run
)
where

import Prelude ()
import Elea.Prelude
import Elea.Term
import Elea.Context ( Context )
import Elea.Show ( showM )
import qualified Elea.Unifier as Unifier
import qualified Elea.Index as Indices
import qualified Elea.Env as Env
import qualified Elea.Terms as Term
import qualified Elea.Types as Type
import qualified Elea.Simplifier as Simp
import qualified Elea.Context as Context
import qualified Elea.Foldable as Fold
import qualified Elea.Fixpoint as Fix
import qualified Elea.Monad.Failure as Fail
import qualified Elea.Monad.Definitions as Defs


run :: forall m . (Env.Read m, Defs.Read m, Fail.Can m)
  -- | A simplification function to be called within run.
  => (Term -> m Term)
  -> Term 
  -> Term 
  -> m Context
  
run simplify f_term@(App f_fix@(Fix {}) f_args) g_term = do
  Fail.unless (Term.inductivelyTyped f_term)
  inventor g_term
  where
  -- The inductive type of f_term
  f_ty@(Type.Base f_ind) = Type.quickGet f_term
  
  -- We use a helper function because the first two arguments never change.
  inventor :: Term -> m Context
  
  -- If g_term has a constructor topmost, we use that as the outer context
  -- and run run on one of the arguments. This assumes that only one
  -- argument will contain a fixpoint.
  inventor g_term@(App g_con@(Con {}) g_args) = do
    Fail.unless (length complex_args == 1)
    inner_ctx <- run simplify f_term (g_args !! arg_i)
    return (con_ctx ++ inner_ctx)
    where
    complex_args = findIndices (not . Term.isSimple) g_args 
    [arg_i] = complex_args
  
    con_ctx = Context.make mkConCtx
      where
      mkConCtx gap = 
        app g_con (setAt arg_i gap g_args)
        
        
  -- If g_term has a pattern match topmost, we use that as the outer context
  -- and run run on one of the branches, or the matched term, provided
  -- only one is non-simple.
  inventor g_term@(Case ind cse_t alts)
    -- If every branch is simple, use the match as a context 
    -- around the matched term
    | length complex_alts == 0 = do
      inner_ctx <- run simplify f_term cse_t
      return (match_ctx ++ inner_ctx)
      
    -- If exactly one brach is non-simple, use that branch term as a context
    | length complex_alts == 1 = do
      inner_ctx <- Env.bindMany alt_bs (run simplify f_term alt_t)
      return (alt_ctx ++ inner_ctx)
      
    | length complex_alts > 1 = 
      Fail.here
    where
    complex_alts = findIndices (not . Term.isSimple . get altInner) alts
    [alt_i] = complex_alts
    Alt alt_bs alt_t = alts !! alt_i
    
    match_ctx = Context.make
      $ \gap -> Case ind gap alts
      
    alt_ctx = Context.make 
      $ \gap -> Case ind cse_t (setAt alt_i (Alt alt_bs gap) alts)
    
      
  -- If the two terms are just equal, we can return the identity context
  inventor g_term@(App (Fix {}) _)
    | f_term == g_term = return mempty
 
    
  -- If the inner term is non-recursively typed then we can use the special
  -- case where we fuse a pattern match over f_term into g_term
  inventor g_term@(App g_fix@(Fix {}) g_args)
    | not (Type.isRecursive f_ind) = do
      alts <- mapM makeAlt [0..length g_ind_cons - 1]
      return 
        $ Context.make 
        $ \gap -> Case f_ind gap alts
    where
    g_ty@(Type.Base (Type.Ind _ g_ind_cons)) = Type.quickGet g_term
    
    makeAlt :: Nat -> m Alt
    makeAlt con_n = do
      alt_t <- Fix.fusion Simp.run full_ctx g_fix
      return 
        . Alt alt_bs
        . Indices.liftMany (length alt_bs) 
        $ alt_t
      where
      alt_bs = Type.makeAltBindings f_ind con_n
      con_ctx = Term.constraint f_term f_ind con_n g_ty
      g_args_ctx = Context.make (\gap -> app gap g_args)
      full_ctx = con_ctx ++ g_args_ctx
    
    
  -- Otherwise we need to do proper fixpoint
  inventor g_term@(App (Fix {}) _) = do  
    Fail.here
    -- DEBUG  
    f_term_s <- showM f_term
    g_term_s <- showM g_term
    let s1 = "\nInventing C s.t. C[" ++ f_term_s ++ "] is " ++ g_term_s
      
    -- Retrieve the type of f_term and g_term
    -- so we can pass them to inventCase
    f_ty <- trace s1 $ Type.get f_term
    let Type.Base ind_ty@(Type.Ind _ cons) = f_ty
    g_ty <- Type.get g_term 
    
    -- We are inventing a fold function and inventCase discovers each of
    -- the fold parameters
    fold_cases <-
      mapM (inventCase f_ty g_ty . toEnum) [0..length cons - 1]
    
    let fold_f = Term.buildFold ind_ty g_ty
    fold <- Simp.run (app fold_f fold_cases)
    let ctx = Context.make (\t -> app fold [t])
    
    -- This algorithm is not sound by construction, so we check its answer using
    -- fusion, which is sound.
    {-
    let f_args_ctx = Context.make (\t -> app t f_args)
        fusion_ctx = ctx ++ f_args_ctx
    fused <- fusion (\_ _ -> Simp.run) fusion_ctx f_fix
    Fail.unless (fused == g_term)
    -}
    -- I've left the soundness check above out because the equality check
    -- at the end is non-trivial. Will put this back in later.
    return ctx
    where
    inventCase :: Type -> Type -> Nat -> m Term
    inventCase f_ty g_ty con_n = do
      -- Fuse this context with the inner fixpoint.
      -- If this fails then just unroll the inner fixpoint once.
      -- For now we don't use this, because it just makes computation longer
      -- and is only for more advanced examples we can't do yet anyway
      mby_fused_eq <- return Nothing 
        -- Fail.catch (fusion (\_ _ -> simplify) full_ctx f_fix)
      fused_eq <- case mby_fused_eq of
        Just eq -> return eq
        Nothing -> simplify (Context.apply full_ctx (Term.unfoldFix f_fix))
        
      -- DEBUG
      fused_eq_s <- showM fused_eq
      let s2 = "\nBranch: " ++ fused_eq_s
      
      -- Find a function which satisfies the equation
      func <- trace s2
        . Fail.fromMaybe
        . Env.trackOffset
        . Fold.findM (runMaybeT . caseFunction) 
        $ fused_eq
      
      -- DEBUG 
      func_s <- showM func
      let s3 = "\nFunction discovered: " ++ func_s
      trace s3 (return func)
      where
      -- Constrain @f_term@ to be this particular constructor
      constraint_ctx = 
        Term.constraint f_term (Type.inductiveType f_ty) con_n eq_ty
      
      -- We represent the equation using a new inductive type.
      eq_ind = Type.Ind "__EQ" [("==", [Type.ConArg f_ty, Type.ConArg g_ty])]
      eq_ty = Type.Base eq_ind
      
      -- Build a context which is an equation between f_term and g_term
      -- where the fixpoint in f_term has been replaced by the gap.
      eq_ctx = Context.make makeEqCtx
        where
        makeEqCtx gap_f = 
          app (Con eq_ind 0) [app gap_f f_args, g_term]
          
      -- Compose the constraint with the equation context 
      -- using the context monoid
      full_ctx = constraint_ctx ++ eq_ctx
          
      caseFunction :: Term -> MaybeT Env.TrackOffset Term
      caseFunction t@(App (Con eq_ind' 0) [left_t, right_t])
        -- Make sure this is actually an equation
        | eq_ind' == eq_ind
        , get Type.name eq_ind' == "__EQ" = do
          -- Check the shape of the left side of the equation is
          -- the constructor we are finding the case for
          Fail.unless (isCon left_f)
          Fail.unless (ind == ind' && con_n == con_n')
          
          -- Try to invent a function which satisfies the equation at this point.
          func <- id
            . foldrM constructFunction right_t 
            $ zip con_args left_args
            
          -- Lower the indices in the discovered function to be valid 
          -- outside this point in the term. 
          -- Remember we have descended into a term to collect equations.
          offset <- Env.offset
          Fail.unless (Indices.lowerableBy offset func)
          return (Indices.lowerMany offset func)
        where
        Type.Base ind@(Type.Ind _ cons) = f_ty
        left_f:left_args = Term.flattenApp left_t
        Con ind' con_n' = left_f
        (_, con_args) = id
          . assert (length cons > con_n)
          $ cons !! enum con_n
        
        -- We move through the constructor arguments backwards, building
        -- up the term one by one.
        constructFunction :: (Type.ConArg, Term) -> Term 
          -> MaybeT Env.TrackOffset Term
        -- If we are at a regular constructor argument (non recursive) 
        -- then the term at this position should just be a variable.
        constructFunction (Type.ConArg ty, Var x) term =
          return  
            . Lam (Bind "x" ty)
            -- Replace the variable at this position with the newly lambda 
            -- abstracted variable
            . Indices.replaceAt (succ x) (Var 0) 
            $ Indices.lift term
            
        -- If we are at a non variable recursive constructor argument,
        -- then we'll need to rewrite the recursive call to @f_term@.
        constructFunction (Type.IndVar, rec_term) term = do
          -- Need to lift the indices in @f_term@ and @g_term@ to be 
          -- what they would be at this point inside the equation term.
          f_term' <- Env.liftByOffset f_term
          g_term' <- Env.liftByOffset g_term
          uni <- Unifier.find f_term' rec_term
          let g_term'' = Unifier.apply uni g_term'
          return
            . Lam (Bind "x" g_ty)
            . Term.replace (Indices.lift g_term'') (Var 0)
            $ Indices.lift term
          
        constructFunction _ _ = Fail.here
          
      caseFunction _ = 
        Fail.here
  
  inventor _ = Fail.here
        
