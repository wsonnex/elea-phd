{-# LANGUAGE UndecidableInstances #-}
-- | Class instances for the constraints in "Elea.Monad.Env".
-- Also a lot of general class instances for 'Term's, since they 
-- require environment tracking term traversal.
module Elea.Monad.Env 
(
  module Elea.Monad.Env.Class,
  
  TrackMatches, trackMatches,
  mapTrackMatches,
 
  AlsoTrack, alsoTrack, alsoWith,
  TrackIndices, TrackIndicesT,
  trackIndices, trackIndicesT,
  mapAlsoTrack,
  
  TrackOffset, TrackOffsetT,
  trackOffset, trackOffsetT,
  
  TrackAllT, trackAllT,
  TrackAll, trackAll,
  
  ignoreClosed,
  isoFree, isoShift,
  empty, emptyT,
  variableMatches,
  isBaseCase,
  
  TrackSmallerTermsT, TrackSmallerTerms, 
  trackSmallerThan, isSmaller,
)
where

import Elea.Prelude
import Elea.Term.Index
import Elea.Term
import Elea.Type ( ContainsTypes (..) )
import Elea.Unification ( Unifiable, Unifier )
import Elea.Monad.Env.Class
import qualified Elea.Type as Type
import qualified Elea.Monad.Failure.Class as Fail
import qualified Elea.Monad.Definitions.Class as Defs
import qualified Elea.Monad.Discovery.Class as Discovery
import qualified Elea.Monad.History as History
import qualified Elea.Term.Index as Indices
import qualified Elea.Unification as Unifier 
import qualified Elea.Unification.Map as UMap
import qualified Elea.Foldable as Fold
import qualified Control.Monad.Trans as Trans
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Algebra.Lattice as Algebra

instance Write m => Fold.FoldableM m Term where
  -- To fold over a 'Term' we require that our monad implement a 'Write'
  -- environment. This environment can then be correctly updated as 
  -- we move into the syntax tree of the term.
  distM (Lam' b (mt, _)) =
    return (Lam' b) `ap` bind b mt
  distM (Fix' i b (mt, _)) =
    return (Fix' i b) `ap` bind b mt
  distM (Case' (mt, cse_t) malts) = do
    t <- mt
    alts <- mapM distAltM malts
    return (Case' t alts)
    where
    distAltM (Alt' con bs (mt, _)) = do
      t <- id
        . bindMany bs
        . matched (Indices.liftMany (length bs) cse_t) (altPattern con)
        $ mt
      return (Alt' con bs t)
  distM other = 
    sequence (fmap fst other)
    
instance Write m => Fold.TransformableM m Term where
    
isoFree :: 
    (Fold.TransformableM (WriterT (Set Index) (TrackIndices Index)) t) =>
  Fold.Iso Term t -> Term -> Set Index
isoFree iso = id
  . trackIndices 0
  . Fold.isoFoldM iso freeR
  where
  freeR :: Term -> TrackIndices Index (Set Index)
  freeR (Var x) = do
    at <- tracked
    if x >= at
    then return (Set.singleton (x - at))
    else return mempty
  freeR _ = 
    return mempty
    
isoShift :: (Fold.TransformableM (TrackIndices Index) t) => 
  Fold.Iso Term t -> (Index -> Index) -> Term -> Term
isoShift iso f = id
  . trackIndices 0
  . Fold.isoTransformM iso shiftVar
  where
  shiftVar :: Term -> TrackIndices Index Term
  shiftVar (Var x) = do
    at <- tracked
    let x' | x >= at = f (x - at) + at
           | otherwise = x
    return (Var x')
  shiftVar other = 
    return other
    
-- | A wrapper around 'Term' for the 'ignoreClosed' isomorphism.
newtype IgnoreClosed = IgnoreClosed { notIgnoreClosed :: Term }
  deriving ( Eq, Ord )

  
ignoreClosed :: Fold.Iso Term IgnoreClosed
ignoreClosed = Fold.iso IgnoreClosed notIgnoreClosed

type instance Fold.Base IgnoreClosed = Term'
  
instance Fold.Foldable IgnoreClosed where
  project = fmap IgnoreClosed . Fold.project . notIgnoreClosed
  
instance Fold.Unfoldable IgnoreClosed where
  embed = IgnoreClosed . Fold.embed . fmap notIgnoreClosed
  
instance Write m => Fold.FoldableM m IgnoreClosed where
  distM = Fold.distM . fmap (second notIgnoreClosed)

instance Write m => Fold.TransformableM m IgnoreClosed where
  transformM f = id
    . liftM IgnoreClosed 
    . Fold.selectiveTransformM ignore f'
    . notIgnoreClosed
    where
    f' = liftM notIgnoreClosed . f . IgnoreClosed
    
    ignore :: Term -> m (Bool, Term' Bool)
    ignore (Fix fix_i fix_b _) 
      | get fixClosed fix_i = 
        return (True, Fix' fix_i fix_b False)
    ignore other = 
      Fold.selectAll other
  
instance Indexed Term where
  free = isoFree id
  shift = isoShift id
  
instance Indexed Alt where
  free (Alt _ bs alt_t) = id
    -- Drop the remaining variables to their value outside of the alt bindings
    . Set.map (Indices.lowerMany (length bs))
    -- Take the free variables of the term, minus those bound by the alt
    $ Indices.free alt_t `Set.difference` not_free
    where
    not_free :: Set Index
    not_free = Set.fromList (map enum [0..length bs - 1])
    
  shift f (Alt con bs alt_t) = 
    Alt con bs (Indices.shift f' alt_t)
    where
    -- The first index not bound by the alt
    min_idx :: Index
    min_idx = length bs
    
    -- The shifting function, altered to be within the alt bindings
    f' idx 
      | idx < min_idx = idx
      | otherwise = f (idx - min_idx) + min_idx
      
instance Indexed FixInfo where
  free = mempty
  shift f = id

instance Substitutable Term where
  type Inner Term = Term

  substAt at with = id
    . trackIndices (at, with)
    . Fold.transformM substVar
    where
    substVar :: Term -> TrackIndices (Index, Term) Term
    substVar (App f xs) =
      return (app f xs)
    substVar (Var var) = do
      (at, with) <- tracked
      return $ case at `compare` var of
        -- Substitution occurs
        EQ -> with
        -- Substitution does not occur
        LT -> Var (pred var)
        GT -> Var var
    substVar other = 
      return other

instance ContainsTypes Term where
  mapTypesM f = runIdentityT . Fold.transformM mapTy
    where
    f' = IdentityT . f
    
    -- We use IdentityT to absorb the type bindings written by transformM.
    -- See 'Elea.Monad.Env.Write'.
    mapTy (Lam b t) = do
      b' <- mapTypesM f' b
      return (Lam b' t)
    mapTy (Fix i b t) = do
      b' <- mapTypesM f' b
      return (Fix i b' t)
    mapTy (Con con) = do
      con' <- mapTypesM f' con
      return (Con con')
    mapTy (Case cse_t alts) = do
      alts' <- mapM mapAlt alts
      return (Case cse_t alts')
      where
      mapAlt (Alt con bs alt_t) = do
        con' <- mapTypesM f' con
        bs' <- mapM (mapTypesM f') bs
        return (Alt con' bs' alt_t)
    mapTy term =
      return term
      
instance ContainsTypes Equation where
  mapTypesM f (Equals name bs t) = do
    bs' <- mapM (mapTypesM f) bs
    t' <- mapTypesM f t
    return (Equals name bs' t')
      
      
-- | If you just need a simple type environment, use the reader
-- monad over a stack of type bindings. This function will strip this
-- monad off, by starting with an empty stack.
empty :: Reader [Bind] a -> a
empty = runIdentity . emptyT

emptyT :: Monad m => ReaderT [Bind] m a -> m a
emptyT = flip runReaderT mempty


-- | Create a 'Unifier' from just the pattern matches over variables.
-- Requires the 'Substitutable' instance for 'Term'. Hence why it's here.
variableMatches :: MatchRead m => m (Unifier Term)
variableMatches =
  liftM (foldl addMatch mempty) matches
  where
  addMatch :: Unifier Term -> (Term, Term) -> Unifier Term
  addMatch uni (Var x, t) = id
    . Map.insert x t 
    -- Apply this substitution to earlier matches.
    -- This is why we use 'foldl' as opposed to 'foldr', 
    -- as the leftmost element is the first match.
    $ map (substAt x t) uni
  addMatch uni _ = uni

  
-- | Whether a given term has been matched to a base case
-- down this branch.
isBaseCase :: MatchRead m => Term -> m Bool
isBaseCase term = do
  ms <- matches
  case lookup term ms of
    Nothing -> return False
    Just con_term -> do
      let Con con : args = flattenApp con_term
      allM isBaseCase
        . map (args `nth`)
        $ Type.recursiveArgs con

  
-- Place 'AlsoTrack' over the top of a 'Write' environment monad.
-- 'AlsoTrack' will capture all changes to the environment and pass them
-- along to the inner monad. 
-- If you don't want your inner monad to not receive the changes 
-- (or it is just not 'Write'), then use 'TrackIndicesT'.
newtype AlsoTrack r m a
  = AlsoTrack { runAlsoTrack :: ReaderT r m a }
  deriving ( Monad, MonadTrans )
  
instance (Indexed r, Monad m) => Tracks r (AlsoTrack r m) where
  tracked = AlsoTrack ask
  liftTrackedMany n =
    AlsoTrack . local (Indices.liftMany n) . runAlsoTrack

mapAlsoTrack :: Monad m => (m a -> n b) -> 
  (AlsoTrack r m a -> AlsoTrack r n b)
mapAlsoTrack f = AlsoTrack . mapReaderT f . runAlsoTrack

alsoTrack :: r -> AlsoTrack r m a -> m a
alsoTrack r = flip runReaderT r . runAlsoTrack

alsoWith :: Monad m => (r' -> r) -> AlsoTrack r m a -> AlsoTrack r' m a
alsoWith f = AlsoTrack . withReaderT f . runAlsoTrack

-- Instances for 'AlsoTrack'
instance (Write m, Indexed r) => Write (AlsoTrack r m) where
  bindAt at b = id
    . AlsoTrack 
    . local (liftAt at)
    . runAlsoTrack 
    . mapAlsoTrack (bindAt at b)
    
  matched t w = 
    mapAlsoTrack (matched t w)
    
instance (Read m, Indexed r) => Read (AlsoTrack r m) where
  bindings = Trans.lift bindings
    
instance (Indexed r, MatchRead m) => MatchRead (AlsoTrack r m) where
  matches = Trans.lift matches
  
instance Fail.Can m => Fail.Can (AlsoTrack r m) where
  here = Trans.lift Fail.here
  catch = mapAlsoTrack Fail.catch
  
instance Defs.Read m => Defs.Read (AlsoTrack r m) where
  lookupTerm n = Trans.lift . Defs.lookupTerm n
  lookupType n = Trans.lift . Defs.lookupType n
  lookupName = Trans.lift . Defs.lookupName
  
instance Discovery.Tells m => Discovery.Tells (AlsoTrack r m) where
  tell = Trans.lift . Discovery.tell

instance Discovery.Listens m => Discovery.Listens (AlsoTrack r m) where
  listen = mapAlsoTrack Discovery.listen
  
instance History.Env m => History.Env (AlsoTrack r m) where
  ask = Trans.lift History.ask
  local f = mapAlsoTrack (History.local f)


-- | To stop effects reaching the inner monad we
-- just wrap it in an 'IdentityT'.
-- TODO change this to a new IgnoreT monad, the current behaviour is 
-- a bit unexpected
type TrackIndicesT r m = AlsoTrack r (IdentityT m)
type TrackIndices r = TrackIndicesT r Identity

trackIndicesT :: r -> TrackIndicesT r m a -> m a
trackIndicesT r = runIdentityT . flip runReaderT r . runAlsoTrack

trackIndices :: r -> TrackIndices r a -> a
trackIndices r = runIdentity . trackIndicesT r


-- | For just tracking how many variables have been bound.
type TrackOffsetT m = TrackIndicesT Index m
type TrackOffset = TrackOffsetT Identity

trackOffsetT :: Monad m => TrackOffsetT m a -> m a
trackOffsetT = trackIndicesT 0

trackOffset :: TrackOffset a -> a
trackOffset = runIdentity . trackOffsetT


newtype TrackMatches m a
  = TrackMatches { runTrackMatches :: ReaderT [(Term, Term)] m a }
  deriving ( Monad, MonadTrans )
  
mapTrackMatches :: Monad m => (m a -> n b) -> 
  (TrackMatches m a -> TrackMatches n b)
mapTrackMatches f = TrackMatches . mapReaderT f . runTrackMatches

trackMatches :: TrackMatches m a -> m a
trackMatches = flip runReaderT mempty . runTrackMatches

localMatches :: Monad m =>
  ([(Term, Term)] -> [(Term, Term)]) -> TrackMatches m a -> TrackMatches m a
localMatches f = TrackMatches . local f . runTrackMatches

instance Write m => Write (TrackMatches m) where
  bindAt at b = id
    . localMatches (map (liftAt at *** liftAt at))
    . mapTrackMatches (bindAt at b)
  
  matched t con_t = id
    . localMatches (++ [(t, con_t)])
    . mapTrackMatches (matched t con_t)
    
instance Read m => Read (TrackMatches m) where
  bindings = Trans.lift bindings
  
instance Write m => MatchRead (TrackMatches m) where
  matches = TrackMatches ask
  
instance Fail.Can m => Fail.Can (TrackMatches m) where
  here = Trans.lift Fail.here
  catch = mapTrackMatches Fail.catch
  
instance Tracks r m => Tracks r (TrackMatches m) where
  tracked = Trans.lift tracked
  liftTrackedMany n = mapTrackMatches (liftTrackedMany n)
  
instance Defs.Read m => Defs.Read (TrackMatches m) where
  lookupTerm n = Trans.lift . Defs.lookupTerm n
  lookupType n = Trans.lift . Defs.lookupType n
  lookupName = Trans.lift . Defs.lookupName

instance Discovery.Tells m => Discovery.Tells (TrackMatches m) where
  tell = Trans.lift . Discovery.tell

instance Discovery.Listens m => Discovery.Listens (TrackMatches m) where
  listen = mapTrackMatches Discovery.listen
  
  
-- | Like 'TrackIndicesT' but which also reads variable pattern matches 
-- and applies them as rewrites to the tracked object.
-- Matches and bindings are (necessarily) NOT written to the inner monad.
newtype TrackAllT r m a
  = TrackAllT { runTrackAllT :: ReaderT r m a }
  deriving ( Monad, MonadTrans )
  
type TrackAll r = TrackAllT r Identity

runTrackAll :: TrackAll r a -> Reader r a
runTrackAll = runTrackAllT
  
instance (Indexed r, Monad m) => Tracks r (TrackAllT r m) where
  tracked = TrackAllT ask
  liftTrackedMany n =
    TrackAllT . local (Indices.liftMany n) . runTrackAllT

mapTrackAllT :: Monad m => (m a -> n b) -> 
  (TrackAllT r m a -> TrackAllT r n b)
mapTrackAllT f = TrackAllT . mapReaderT f . runTrackAllT

trackAllT :: r -> TrackAllT r m a -> m a
trackAllT r = flip runReaderT r . runTrackAllT

trackAll :: r -> TrackAll r a -> a
trackAll r = runIdentity . trackAllT r

-- Instances for 'TrackAllT'
instance (Monad m, Substitutable r, Inner r ~ Term) 
    => Write (TrackAllT r m) where
  bindAt at b = id
    . TrackAllT 
    . local (liftAt at)
    . runTrackAllT
    
  matched (Var x) w = id
    . TrackAllT
    . local (Indices.replaceAt x w)
    . runTrackAllT
  matched _ _ = id
    
  
instance Fail.Can m => Fail.Can (TrackAllT r m) where
  here = Trans.lift Fail.here
  catch = mapTrackAllT Fail.catch
  
instance Defs.Read m => Defs.Read (TrackAllT r m) where
  lookupTerm n = Trans.lift . Defs.lookupTerm n
  lookupType n = Trans.lift . Defs.lookupType n
  lookupName = Trans.lift . Defs.lookupName
  
instance Discovery.Tells m => Discovery.Tells (TrackAllT r m) where
  tell = Trans.lift . Discovery.tell

instance Discovery.Listens m => Discovery.Listens (TrackAllT r m) where
  listen = mapTrackAllT Discovery.listen

  

-- | Stores a list of terms structurally smaller than a given object.
data Smaller a
  = Smaller { smallerThan :: a
            , smaller :: Set a }
  deriving ( Eq, Show )
                  
instance (Ord a, Indexed a) => Indexed (Smaller a) where
  free (Smaller than set) = 
    free than ++ concatMap free set
    
  shift f (Smaller than set) = 
    Smaller (shift f than) (Set.mapMonotonic (shift f) set)
    
type TrackSmallerTermsT = ReaderT (Smaller Term)
type TrackSmallerTerms = TrackSmallerTermsT Identity

trackSmallerThan :: Term -> TrackSmallerTermsT m a -> m a
trackSmallerThan than = flip runReaderT (Smaller than mempty) 

isSmaller :: (Show Term, Monad m) => Term -> TrackSmallerTermsT m Bool
isSmaller term = do
  set <- asks smaller
  return (isFinite term || term `Set.member` set)
    
instance (Show Term, Write m) => Write (TrackSmallerTermsT m) where
  bindAt idx t = id
    . mapReaderT (bindAt idx t)
    . local (liftAt idx)
    
  matched term with@(flattenApp -> Con con : args) = id
    . mapReaderT (matched term with) 
    . local addMatch
    where
    rec_args = id
      . Set.fromList
      . map (args `nth`) 
      $ Type.recursiveArgs con
     
    addMatch (Smaller than set) = 
      Smaller than set'
      where
      set' | term == than = set ++ rec_args
           | term `Set.member` set = Set.insert with (set ++ rec_args)
           | otherwise = set

        
-- Other stuff

instance Unifiable Term where
  find t1 t2 = do
    possible_uni <- trackIndicesT 0 (t1 `uni` t2)
    -- Need to test out the unifier. It could be invalid if at some
    -- points a variable needs to be replaced, but at others it stays the same.
    Fail.when (Unifier.apply possible_uni t1 /= t2)
    return possible_uni
    where
    uni :: forall m . Fail.Can m => 
      Term -> Term -> TrackIndicesT Index m (Unifier Term)
    uni (Eql x y) (Eql x' y') = do
      uni_x <- uni x x'
      uni_y <- uni y y'
      Unifier.union uni_x uni_y
    uni (Bot _) (Bot _) = 
      return mempty
    uni (Var x1) (Var x2)
      | x1 == x2 = return mempty
    uni (Var idx) t2 = do
      free_var_limit <- tracked
      -- If the variable on the left is not locally scoped
      -- then we can substitute it for something.
      -- We subtract 'free_var_limit' to get the index
      -- outside the bindings of this term.
      if idx < free_var_limit
      then Fail.here
      else do
        let lowered_idx = idx - free_var_limit
            lowered_t2 = Indices.lowerMany (enum free_var_limit) t2
        return (Unifier.singleton lowered_idx lowered_t2)
    uni (Lam b1 t1) (Lam b2 t2) =
      -- Since we are inside a binding the indices go up by one, 
      -- so we call 'liftTracked'.
      liftTracked (t1 `uni` t2)
    uni (Fix i1 b1 t1) (Fix i2 b2 t2) 
      | i1 == i2 =
      -- ^ Need to make sure tags match
        liftTracked (t1 `uni` t2)
    uni (App f1 xs1) (App f2 xs2) = do
      uni_f <- uni f1 f2
      uni_xs <- zipWithM uni xs1 xs2
      Unifier.unions (uni_f : uni_xs)
    uni (Con con1) (Con con2) = do
      Fail.when (con1 /= con2)
      return mempty
    uni (Case t1 alts1) (Case t2 alts2) = do
      ut <- uni t1 t2
      ualts <- zipWithM uniAlt alts1 alts2
      Unifier.unions (ut:ualts) 
      where
      uniAlt :: Alt -> Alt -> TrackIndicesT Index m (Unifier Term)
      uniAlt (Alt con1 bs1 t1) (Alt con2 bs2 t2) = do
        Fail.when (con1 /= con2)
        liftTrackedMany (length bs1) (uni t1 t2)
    uni _ _ = Fail.here 
    
  apply uni = id
    . trackOffset
    . Fold.transformM replace
    where
    replace :: Term -> TrackOffset Term
    replace (App f xs) =
      return (app f xs)
    replace (Var x) = do
      n <- offset
      if x < enum n
      then return (Var x)
      else do
        case Map.lookup (x - enum n) uni of 
          Nothing -> return (Var x)
          Just t -> return (Indices.liftMany n t)
    replace other = 
      return other
      
  -- This compare function will set free variables equal to anything
  gcompare t1 t2 = trackOffset (comp t1 t2)
    where
    comp :: Term -> Term -> TrackOffset Ordering
    comp (Var x) t = do
      free_x <- lowerableByOffset x
      free_t <- lowerableByOffset t
      if free_x && free_t
      then return EQ
      else if isVar t
      then return (x `compare` fromVar t)
      else return LT
    comp t (Var y) = do
      free_y <- lowerableByOffset y
      free_t <- lowerableByOffset t
      if free_y && free_t
      then return EQ
      else return GT
    comp (Eql x y) (Eql x' y') = do
      cx <- comp x x'
      cy <- comp y y'
      return (cx ++ cy)
    comp (Bot _) (Bot _) =  
      return EQ
    comp (Bot _) _ = return LT
    comp _ (Bot _) = return GT
    comp (Eql _ _) _ = return LT
    comp _ (Eql _ _) = return GT
    comp (App t1 t2) (App t1' t2') = do
      -- We use the lexicographical ordering monoid append operation.
      c1 <- comp t1 t1'
      c2 <- liftM mconcat (zipWithM comp t2 t2')
      return (c1 ++ c2)
    comp (App {}) _ = return LT
    comp _ (App {}) = return GT
    comp (Fix _ _ t) (Fix _ _ t') = liftTracked (comp t t')
    comp (Fix {}) _ = return LT
    comp _ (Fix {}) = return GT
    comp (Lam _ t) (Lam _ t') = liftTracked (comp t t')
    comp (Lam {}) _ = return LT
    comp _ (Lam {}) = return GT
    comp (Con con) (Con con') = return (compare con con')
    comp (Con {}) _ = return LT
    comp _ (Con {}) = return GT
    comp (Case t1 alts1) (Case t2 alts2) = do
      -- We use the lexicographical ordering monoid
      ct <- comp t1 t2
      calts <- liftM mconcat (zipWithM compAlts alts1 alts2)
      return (ct ++ calts)
      where 
      compAlts (Alt con1 bs1 t1) (Alt con2 bs2 t2) = 
        liftTrackedMany (length bs1) (comp t1 t2)
      
  alphaEq t t'
    | Just u1 <- Unifier.find t t'
    , Just u2 <- Unifier.find t' t = 
      all isVar (Map.elems u1 ++ Map.elems u2)
  alphaEq _ _ = False

        
instance Indexed Constraint where
  free = free . get constrainedTerm
  shift f = modify constrainedTerm (shift f)
      
instance Substitutable Constraint where 
  type Inner Constraint = Term
  substAt x t = 
    modify constrainedTerm (substAt x t)
  
instance Unifiable Constraint where
  apply uni =
    modify constrainedTerm (Unifier.apply uni)
    
  find (Constraint con1 t1) (Constraint con2 t2) = do
    Fail.unless (con1 == con2)
    Unifier.find t1 t2
    
  gcompare (Constraint con1 t1) (Constraint con2 t2) =
    compare con1 con2 ++ Unifier.gcompare t1 t2
    
  alphaEq (Constraint con1 t1) (Constraint con2 t2) =
    con1 == con2 && Unifier.alphaEq t1 t2

