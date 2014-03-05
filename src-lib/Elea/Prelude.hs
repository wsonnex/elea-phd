module Elea.Prelude
(
  module Prelude,
  
  module Control.Category,
  module Control.Arrow,
  module Control.Applicative,
  module Control.Monad,
  module Control.Monad.State,
  module Control.Monad.Reader,
  module Control.Monad.Writer,
  module Control.Monad.Trans,
  module Control.Monad.List,
  module Control.Monad.RWS,
  module Control.Monad.Identity,
  module Control.Monad.Trans.Identity,
  module Control.Monad.Trans.Either,
  module Control.Monad.Trans.Maybe,
  module Control.Exception,
  
  module Data.Nat,
  module Data.Label.Pure,
  module Data.Label,
  module Data.Maybe,
  module Data.Either,
  module Data.Monoid,
  module Data.Semigroup,
  module Data.Map.Strict,
  module Data.Sequence,
  module Data.Set,
  module Data.Traversable,
  module Data.Foldable,
  module Data.List,
  module Data.String,
  module Data.IORef,
  module Data.IntMap,
  module Data.Char,
  module Data.IntSet,
  module Data.Function,
  module Data.Text,
--  module Data.Generics.Uniplate.Operations,
  module Data.Generics.Str,
  module Data.String.Utils,
  module Data.Key,
  module Data.Proxy,
  
  module Debug.Trace,
  module System.IO.Unsafe,
  
  (++), concat, intercalate, map, void,
  concatMap, concatMapM, partitionM,
  concatEndos, concatEndosM,
  fromJustT, anyM, allM, findM, sortWith, deleteIndices,
  minimalBy, nubOrd, elemOrd, intersectOrd, countOrd,
  fromRight, fromLeft, traceMe, setAt, firstM, 
  takeIndices, isNub, foldl1M, seqStr, strSeq,
  isLeft, isRight, modifyM', modifyM, removeAt,
  insertAt, enum, indent, indentBy, debugNth,
  arrowSum, supremum, (|>), ($>), replaceAt,
  Maximum (..), Minimum (..), sconcatMap,
  intersects, length, liftMaybe, maybeT
)
where

import Prelude hiding ( mapM, foldl, foldl1, mapM_, minimum, 
  maximum, sequence_, zip, zipWith, Read (..), length,
  foldr, foldr1, sequence, Maybe (..), maybe, all, any, elem, product,
  and, concat, notElem, or, concatMap, sum, (++), map, (.), id )

import Control.Category ( (.), id )
import Control.Arrow ( Arrow (..), (>>>), (<<<), (&&&), (***), 
  first, second, Kleisli (..), runKleisli )
import Control.Applicative hiding ( empty )
import Control.Monad ( liftM, ap, replicateM, join, zipWithM_,
  zipWithM, filterM, when, unless, guard, 
  (>=>), (<=<), (>>), MonadPlus (..) )
import Control.Monad.Trans ( MonadTrans (..), lift, liftIO )
import Control.Monad.State ( evalStateT, execState, runState, evalState,
  MonadState, State (..), StateT (..), mapStateT )
import Control.Monad.Reader ( 
  MonadReader (..), Reader (..), ReaderT (..), 
  asks, runReader, mapReaderT, withReaderT, withReader )
import Control.Monad.Writer ( execWriter, runWriter, execWriterT, mapWriterT,
  MonadWriter (..), Writer (..), WriterT (..), censor, listens )
import Control.Monad.List ( ListT (..) )
import Control.Monad.Trans.Maybe
import Control.Monad.RWS ( RWS (..), RWST (..), execRWS, evalRWS, runRWS )
import Control.Monad.Identity ( Identity (..) )
import Control.Monad.Trans.Identity ( IdentityT (..), mapIdentityT )
import Control.Monad.Trans.Either ( EitherT (..), mapEitherT )
import Control.Monad.Fix
import Control.Exception ( assert )

import Data.Nat ( Nat, CoNat )
import Data.Label.Pure
import Data.Label ( mkLabels )
import Data.Label.Maybe ( (:~>) )
import Data.Maybe
import Data.Either ( lefts, rights, partitionEithers )
import Data.Monoid hiding ( Sum, All, (<>) )
import Data.Semigroup ( Semigroup (..) )
import Data.Map.Strict ( Map )
import Data.Sequence ( Seq )
import Data.Set ( Set )
import qualified Data.Set as Set
import Data.IntSet ( IntSet )
import Data.Traversable
import Data.Foldable hiding ( concat, concatMap )
import Data.List ( intersperse, unfoldr, partition,
  isPrefixOf, isSuffixOf, isInfixOf, sort, sortBy, findIndex,
  delete, elemIndices, intersect, union, transpose, groupBy,
  (\\), subsequences, isSuffixOf, deleteBy, findIndices, elemIndex )
import Data.IORef
import Data.Char ( isAlpha, isDigit, isAlphaNum, isSpace, chr, ord )
import Data.IntMap ( IntMap )
import Data.IntSet ( IntSet )
import Data.Function ( on )
import Data.Text ( Text )
import Data.String
-- import Data.Generics.Uniplate.Operations
import Data.Generics.Str
import Data.String.Utils ( replace )
import Data.Key ( Zip (..) )
import Data.Proxy

import Debug.Trace
import System.IO.Unsafe

import qualified Prelude as Pre
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Label.Maybe as Maybe
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Nat as Nat

infixr 6 ++

(|>) :: a -> (a -> b) -> b
(|>) = flip ($)

($>) :: Monad m => m a -> (a -> b) -> m b
($>) = flip liftM 

void :: Functor f => f a -> f ()
void = fmap (const ())

(++) :: Monoid m => m -> m -> m
(++) = mappend

map :: Functor f => (a -> b) -> f a -> f b
map = fmap

concat :: Monoid m => [m] -> m
concat = mconcat

sconcatMap :: (Semigroup m, Foldable f) => (a -> m) -> f a -> m
sconcatMap f = sconcat . map f . NonEmpty.fromList . toList
  
instance Monad m => Monoid (Kleisli m a a) where
  mempty = arr id
  mappend = (>>>)

concatMap :: (Monoid m, Foldable f) => (a -> m) -> f a -> m
concatMap f = concat . map f . toList

concatMapM :: (Monoid b, Monad m, Foldable f) => (a -> m b) -> f a -> m b
concatMapM f = liftM concat . mapM f . toList

intercalate :: Monoid m => m -> [m] -> m
intercalate x = concat . intersperse x

-- | A more usefully typed 'length' function.
length :: (Foldable f, Enum n) => f a -> n
length = enum . Pre.length . toList

partitionM :: Monad m => (a -> m Bool) -> [a] -> m ([a], [a])
partitionM f = foldrM f' ([], [])  
  where
  f' a (xs, ys) = do
    p <- f a
    return $
      if p then (a : xs, ys) else (xs, a : ys)
      
fromJustT :: Monad m => MaybeT m a -> m a
fromJustT = liftM fromJust . runMaybeT

liftMaybe :: MonadPlus m => Maybe a -> m a
liftMaybe Nothing = mzero
liftMaybe (Just x) = return x

maybeT :: Monad m => m b -> (a -> m b) -> MaybeT m a -> m b 
maybeT x f m = do
  mby_a <- runMaybeT m
  if isNothing mby_a
  then x
  else f (fromJust mby_a)

anyM :: (Monad f, Traversable t) => (a -> f Bool) -> t a -> f Bool
anyM f = liftM or . mapM f

allM :: (Monad f, Traversable t) => (a -> f Bool) -> t a -> f Bool
allM f = liftM and . mapM f

findM :: Monad m => (a -> m Bool) -> [a] -> m (Maybe a)
findM p [] = return Nothing
findM p (x:xs) = do
  found <- p x
  if found
    then return (Just x)
    else findM p xs
    
-- | Returns the first element which is 'Just'. 
-- Ignores all monadic effects after this element.
firstM :: Monad m => [m (Maybe a)] -> m (Maybe a)
firstM [] = return Nothing
firstM (mx:mxs) = do
  mby_x <- mx
  maybe (firstM mxs) (return . Just) mby_x
  
foldl1M :: (Monad m, Foldable f) => (a -> a -> m a) -> f a -> m a
foldl1M f (toList -> xs) = foldlM f (head xs) (tail xs)
    
sortWith :: Ord b => (a -> b) -> [a] -> [a]
sortWith f = sortBy (compare `on` f)

concatEndos :: Foldable f => f (a -> a) -> a -> a
concatEndos = appEndo . mconcat . map Endo . toList

concatEndosM :: (Monad m, Foldable f) => f (a -> m a) -> a -> m a
concatEndosM = runKleisli . mconcat . map Kleisli . toList

instance Functor First where
  fmap f = First . fmap f . getFirst

minimalBy :: (a -> a -> Ordering) -> [a] -> [a]
minimalBy _ [] = []
minimalBy ord xs = y : (takeWhile ((== EQ) . ord y) ys)
  where (y:ys) = sortBy ord xs

nubOrd :: Ord a => [a] -> [a]
nubOrd = reverse . fst . foldl nubby ([], Set.empty)
  where
  nubby (acc, set) x 
    | x `Set.member` set = (acc, set)
    | otherwise = (x:acc, Set.insert x set)

isNub :: forall a . Ord a => [a] -> Bool
isNub = isJust . foldrM dupM Set.empty
  where
  dupM :: a -> Set a -> Maybe (Set a)
  dupM x xs = do
    guard (not $ Set.member x xs)
    return (Set.insert x xs)
  
elemOrd :: Ord a => a -> [a] -> Bool
elemOrd x = Set.member x . Set.fromList

countOrd :: Ord a => a -> [a] -> Int
countOrd n = count . sort
  where
  count [] = 0
  count (x:xs) =
    case x `compare` n of
      LT -> count xs
      EQ -> 1 + (count xs)
      GT -> 0

intersectOrd :: Ord a => [a] -> [a] -> [a]
intersectOrd xs ys = Set.toList 
  $ Set.intersection (Set.fromList xs) (Set.fromList ys)
  
-- | Delete a set of indices from a list
deleteIndices :: [Int] -> [a] -> [a]
deleteIndices is xs = d 0 (sort is) xs
  where
  d :: Int -> [Int] -> [a] -> [a]
  d _ [] xs = xs
  d _ _ [] = []
  d i (j:js) (x:xs)
    | i == j = d (i + 1) js xs
    | otherwise = x : d (i + 1) (j:js) xs
    
-- | Only return the given indices of a list
takeIndices :: [Int] -> [a] -> [a]
takeIndices is xs = t 0 (sort is) xs
  where
  t :: Int -> [Int] -> [a] -> [a]
  t _ [] _ = []
  t _ _ [] = []
  t i (j:js) (x:xs) 
    | i == j = x : t (i + 1) js xs
    | otherwise = t (i + 1) (j:js) xs

fromRight :: Either a b -> b
fromRight (Right b) = b

fromLeft :: Either a b -> a
fromLeft (Left a) = a

isLeft (Left _) = True
isLeft _ = False

isRight (Right _) = True
isRight _ = False

traceMe :: Show a => String -> a -> a
traceMe s x = trace (s ++ ": " ++ show x) x

setAt :: Int -> a -> [a] -> [a]
setAt _ x [] = [x]
setAt 0 x xs = x:(tail xs)
setAt i x (y:ys) = y:(setAt (i - 1) x ys)

seqStr :: Seq a -> Str a
seqStr =  listStr . toList

strSeq :: Str a -> Seq a
strSeq = Seq.fromList . strList

modifyM' :: Monad m => (f :~> a) -> (a -> m a) -> f -> m f
modifyM' r g f
  | Just a <- Maybe.get r f = do
      a' <- g a
      return $ fromJust $ Maybe.set r a' f 
  | otherwise = return f
  
modifyM :: Monad m => (f :-> a) -> (a -> m a) -> f -> m f
modifyM r g f = do
  x <- g (get r f)
  return (set r x f)
   
insertAt :: Int -> a -> [a] -> [a]
insertAt 0 x ys = x:ys
insertAt n x (y:ys) = y:(insertAt (n-1) x ys)
insertAt _ _ [] = 
  error "Can't insert past the end of a list"
  
removeAt :: Int -> [a] -> [a]
removeAt _ [] = error "Can't remove past the end of a list"
removeAt 0 (x:xs) = xs
removeAt n (x:xs) = x:(removeAt (n-1) xs)

replaceAt :: Int -> a -> [a] -> [a]
replaceAt 0 x (y:ys) = x:ys
replaceAt n x (y:ys) = y:(replaceAt (n-1) x ys)
replaceAt _ _ [] = 
  error "Can't replace past the end of a list"
  
enum :: (Enum a, Enum b) => a -> b
enum = toEnum . fromEnum

indentBy :: Int -> String -> String
indentBy n = replace "\n" ("\n" ++ replicate n ' ')

indent :: String -> String
indent = indentBy 2

debugNth :: String -> [a] -> Int -> a
debugNth msg xs n 
  | length xs <= n = error msg
  | otherwise = xs !! n
  
arrowSum :: MonadPlus m => [a -> m b] -> a -> m b
arrowSum ms x = msum (map ($ x) ms)

supremum :: Enum a => Set a -> a
supremum set 
  | Set.null set = toEnum 0
  | otherwise = succ . head . Set.toDescList $ set

newtype Minimum a = Minimum { getMinimum :: a }
  deriving ( Eq, Ord, Enum, Num )

instance Ord a => Semigroup (Minimum a) where
  x <> y | x <= y = x
         | otherwise = y
 
newtype Maximum a = Maximum { getMaximum :: a }
  deriving ( Eq, Ord, Enum, Num )

instance Ord a => Semigroup (Maximum a) where
  x <> y | x >= y = x
         | otherwise = y
         
instance Monoid (Maximum Nat) where
  mappend = (<>)
  mempty = toEnum 0
  
instance Monoid (Minimum CoNat) where
  mappend = (<>)
  mempty = Minimum Nat.omega
  
intersects :: Ord a => Set a -> Set a -> Bool
intersects x = not . Set.null . Set.intersection x
