module Elea.Show 
( 
  ShowM (..)
) 
where

import Prelude ()
import Elea.Prelude
import Elea.Index
import Elea.Term
import Elea.Context ( Context )
import qualified Elea.Env as Env
import qualified Elea.Type as Type
import qualified Elea.Context as Context
import qualified Elea.Foldable as Fold
import qualified Elea.Definitions as Defs
import qualified Data.Map as Map

-- | A monadic variant of 'show'.
class Monad m => ShowM m a where
  showM :: a -> m String
    
instance Show Term where
  show = emptyEnv . showM
    where
    emptyEnv :: ReaderT [Bind] Defs.DBReader a -> a
    emptyEnv = Defs.readEmpty . flip runReaderT [] 
    
bracketIfNeeded :: String -> String
bracketIfNeeded s 
  | ' ' `elem` s = "(" ++ s ++ ")"
  | otherwise = s

instance Show (Term' String) where
  show (Absurd' ty) = "_|_ " ++ show ty
  show (App' f xs) = f' ++ " " ++ xs'
    where 
    xs' = intercalate " " (map bracketIfNeeded xs)
    f' | "->" `isInfixOf` f || "end" `isInfixOf` f = "(" ++ f ++ ")"
       | otherwise = f
  show (Fix' _ (show -> b) t) =
    indent $ "\nfix " ++ b ++ " -> " ++ t
  show (Lam' (show -> b) t) =
    indent $ "\nfun " ++ b ++ " -> " ++ t
  show (Con' (Type.Ind _ cons) idx) =
    fst (cons !! fromEnum idx)
  show (Case' (Type.unfold -> cons) cse_t f_alts) = id 
     . indent
     $ "\nmatch " ++ cse_t ++ " with"
    ++ concat alts_s
    ++ "\nend"
    where
    alts_s = zipWith showAlt cons f_alts
    
    showAlt :: Bind -> Alt' String -> String
    showAlt (Bind con_name _) (Alt' alt_bs alt_t) =
      "\n| " ++ pat_s ++ " -> " ++ alt_t
      where
      pat_s = intercalate " " ([con_name] ++ map show alt_bs)
    
instance (Env.Read m, Defs.Read m) => ShowM m Term where
  showM = Fold.paraM fshow
    where
    fshow :: Term' (String, Term) -> m String
    fshow (Var' idx) = do
      bs <- Env.bindings
      if idx >= enum (length bs)
      -- If we don't have a binding for this index 
      -- just display the index itself
      then return (show idx)
      else do
        Bind lbl _ <- Env.boundAt idx
        let lbl' | ' ' `elem` lbl = "\"" ++ lbl ++ "\""
                 | otherwise = lbl
                 
        -- Count the number of bindings before this one
        -- which have the same label
        let same_lbl_count = id
              . length
              . filter (== lbl)
              . map (get Type.boundLabel)
              $ take (fromEnum idx) bs
              
        -- Append this count to the end of the variable label, so we know
        -- exactly which variable we are considering
        if same_lbl_count > 0
        then return (lbl' ++ "[" ++ show (same_lbl_count + 1) ++ "]")
        else return lbl'

    fshow term' = do
      -- Attempt to find an alias for this function in our definition database
      mby_name <- Defs.lookupName (Fold.recover term')
      case mby_name of
        Just (name, args) -> do
          args' <- mapM showM args
          let args_s = concatMap ((" " ++) . bracketIfNeeded) args'
          return (name ++ args_s) 
          
        Nothing -> 
          -- If we can't find an alias, then default to the 
          -- @Show (Term' String)@ instance
          (return . show . fmap fst) term'
      
      

      
instance (Env.Read m, Defs.Read m) => ShowM m Context where
  showM = showM . get Context.term
  
instance Show Context where
  show = show . get Context.term
  
instance ShowM m a => ShowM m (a, a) where
  showM (x, y) = do
    sx <- showM x
    sy <- showM y
    return ("(" ++ sx ++ ", " ++ sy ++ ")")
    
instance ShowM m a => ShowM m [a] where
  showM xs = do
    sxs <- mapM showM xs
    return 
      $ "[" ++ intercalate ", " sxs ++ "]"
 
instance ShowM m a => ShowM m (Map a a) where
  showM = showM . Map.toList
      
