-- | A transformation monad carries around a 'Term -> m Term' function
-- allowing it to apply the transformation recursively.
{-# LANGUAGE UndecidableInstances #-}
module Elea.Monad.Transform
(
  Step (..),
  RewriteT (..),
  Env (..),
  NamedStep,
  compose,
  visible,
  invisible,
  mapRewriteT,
  whenTraceSteps,
)
where

import Elea.Prelude hiding ( liftCatch )
import Elea.Term
import qualified Elea.Type as Type
import qualified Elea.Term.Ext as Term
import qualified Elea.Monad.Failure.Class as Fail
import qualified Elea.Monad.Env.Class as Env
import qualified Elea.Monad.Definitions.Class as Defs
import qualified Elea.Monad.Fusion as Fusion
import qualified Elea.Monad.Discovery.Class as Discovery
import qualified Elea.Monad.History as History
import qualified Elea.Monad.Memo.Class as Memo
import qualified Elea.Monad.Direction as Direction
import qualified Elea.Monad.Error.Class as Err
import qualified Elea.Monad.Error.Assertion as Assert
import qualified Elea.Term.Tag as Tag
import qualified Elea.Monad.StepCounter as Steps
import qualified Control.Monad.Reader.Class as Reader
import qualified Control.Monad.Trans.Reader as Reader hiding ( ask )
import qualified Control.Monad.Trans.Maybe as Maybe
import qualified Control.Monad.Trans.Class as Trans

import qualified Data.Poset as Quasi
import qualified Data.Map as Map


{-# INLINE compose #-}

class Fail.Can m => Step m where
  -- | Accessing the recursive call to our transformation
  continue :: Term -> m Term

-- | Carry around a call to a simplification function
newtype RewriteT m a 
  = RewriteT { rewriteT :: ReaderT (Term -> m Term) (MaybeT m) a }
  deriving ( Functor, Applicative, Monad )
  
data NamedStep m = NamedStep 
  { stepName :: !String
  , stepVisible :: !Bool
  , stepRewrite :: !(Term -> RewriteT m Term) }

visible :: Monad m => String -> (Term -> RewriteT m Term) -> NamedStep m
visible name rewrite = NamedStep 
  { stepName = name
  , stepVisible = True
  , stepRewrite = rewrite }

invisible :: Monad m => String -> (Term -> RewriteT m Term) -> NamedStep m
invisible name rewrite = NamedStep 
  { stepName = name
  , stepVisible = False
  , stepRewrite = rewrite }

mapRewriteT :: forall m a b . Monad m 
  => (m (Maybe a) -> m (Maybe b)) -> RewriteT m a -> RewriteT m b
mapRewriteT f = RewriteT . mapReaderT (mapMaybeT f) . rewriteT
    
compose :: forall m . (Steps.Limiter m, Env.Read m, History.Env m, Defs.Read m, Env m) 
  => [NamedStep m] -> Term -> m Term
compose all_steps = applyOneStep all_steps
  where
  applyOneStep :: [NamedStep m] -> Term -> m Term
  applyOneStep [] term = return term
  applyOneStep (named_step : steps) term = do
    mby_term' <- runMaybeT (runReaderT rewritten_term (compose all_steps))
    case mby_term' of
      Nothing -> applyOneStep steps term
      Just term' -> do
        Steps.take
        full_term' <- applyContext term'  -- Terms within the current context
        full_term <- applyContext term
        let valid_rewrite = id
              . Assert.augment (printf "within step \"%s\"" step_name)
              $ Term.assertValidRewrite full_term full_term'
        Assert.check valid_rewrite
          . traceStep full_term'
          $ return term'
    where
    step_name = stepName named_step
    rewritten_term = rewriteT (stepRewrite named_step term)

    traceStep full_term'
      | stepVisible named_step = 
        whenTraceSteps (printf "Applied step \"%s\", yielding: %s" step_name full_term')
      | otherwise = id
          

liftCatch :: Monad m 
  => (m (Maybe a) -> (e -> m (Maybe a)) -> m (Maybe a))
  -> RewriteT m a -> (e -> RewriteT m a) -> RewriteT m a
liftCatch catch step_t handle = 
  RewriteT (catch' (rewriteT step_t) handle')
  where
  handle' = rewriteT . handle
  catch' = Reader.liftCatch (Maybe.liftCatch catch)

instance MonadTrans RewriteT where
  lift m = RewriteT (ReaderT (\_ -> Trans.lift m))
  
instance Monad m => Step (RewriteT m) where
  continue t = do
    f <- RewriteT Reader.ask
    Trans.lift (f t)
    
instance Monad m => Fail.Can (RewriteT m) where
  here = RewriteT Fail.here
  catch = RewriteT . Fail.catch . rewriteT
    
instance Step m => Step (MaybeT m) where
  continue = Trans.lift . continue
  
instance Env.Read m => Env.Read (RewriteT m) where
  bindings = Trans.lift Env.bindings
  
instance Env.Write m => Env.Write (RewriteT m) where
  bindAt at b = mapRewriteT (Env.bindAt at b)
  matched m = mapRewriteT (Env.matched m)
  forgetMatches w = mapRewriteT (Env.forgetMatches w)

instance Defs.Read m => Defs.Read (RewriteT m) where
  lookupTerm n = Trans.lift . Defs.lookupTerm n
  lookupType n = Trans.lift . Defs.lookupType n
  lookupName = Trans.lift . Defs.lookupName

instance Err.Throws m => Err.Throws (RewriteT m) where
  type Err (RewriteT m) = Err.Err m
  throw = Trans.lift . Err.throw
  catch = liftCatch Err.catch
  augment e = mapRewriteT (Err.augment e)
  
instance Tag.Gen m => Tag.Gen (RewriteT m) where
  generateId = Trans.lift Tag.generateId
  
instance Fusion.Env m => Fusion.Env (RewriteT m) where
  rewrites = Trans.lift Fusion.rewrites
  local a t x = mapRewriteT (Fusion.local a t x)
  forgetRewrites = mapRewriteT Fusion.forgetRewrites
  disable = mapRewriteT Fusion.disable
  isDisabled = Trans.lift Fusion.isDisabled

instance Env.MatchRead m => Env.MatchRead (RewriteT m) where
  matches = Trans.lift Env.matches
  
instance Discovery.Tells m => Discovery.Tells (RewriteT m) where
  tell = Trans.lift . Discovery.tell
  
instance History.Env m => History.Env (RewriteT m) where
  ask = Trans.lift History.ask
  local f = mapRewriteT (History.local f)
  
instance Direction.Has m => Direction.Has (RewriteT m) where
  get = Trans.lift Direction.get
  local d = mapRewriteT (Direction.local d)
  
instance Memo.Can m => Memo.Can (RewriteT m) where
  maybeMemo n t = mapRewriteT instep
    where
    instep :: m (Maybe (Maybe Term)) -> m (Maybe (Maybe Term))
    instep mx =
      liftM return (Memo.maybeMemo n t (liftM join mx))

instance Steps.Counter m => Steps.Counter (RewriteT m) where
  take = Trans.lift Steps.take
  listen = RewriteT . Steps.listen . rewriteT

instance Steps.Limiter m => Steps.Limiter (RewriteT m) where
  limit n = RewriteT . Steps.limit n . rewriteT
  remaining = Trans.lift Steps.remaining

instance Env m => Env (RewriteT m) where
  clearContext = mapRewriteT clearContext
  augmentContext = mapRewriteT . augmentContext
  applyContext = Trans.lift . applyContext
  traceSteps = Trans.lift traceSteps
  enableTraceSteps = mapRewriteT enableTraceSteps

class Monad m => Env m where
  applyContext :: Term -> m Term
  augmentContext :: (Term -> Term) -> m a -> m a
  clearContext :: m a -> m a

  traceSteps :: m Bool
  enableTraceSteps :: m a -> m a

{-# INLINE whenTraceSteps #-}
whenTraceSteps :: Env m => String -> m a -> m a
#ifndef TRACE
whenTraceSteps _ = id
#else
whenTraceSteps msg run = do
  should <- traceSteps
  if should
  then trace msg run
  else run
#endif
