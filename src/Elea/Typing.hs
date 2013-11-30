-- | Type checking for terms, along with functions to wrap around
-- transformation steps (@Term -> m (Maybe Term)@ functions) 
-- to dynamically check they preserve typing (the type of the argument
-- matches the type of the resulting term).
module Elea.Typing
(
  typeOf, check, checkStep,
)
where

import Prelude ()
import Elea.Prelude
import Elea.Index hiding ( lift )
import Elea.Term
import Elea.Show ( showM )
import qualified Elea.Type as Type
import qualified Elea.Foldable as Fold
import qualified Elea.Env as Env
import qualified Elea.Monad.Error as Err

type TypingMonad m = (Err.Monad m, Env.Readable m)

-- | Throws an error if a term is not correctly typed.
check :: TypingMonad m => Term -> m ()
-- Call 'typeOf' and ignore the argument
check = liftM (const ()) . typeOf

-- | Wrap this around a term transformation step @Term -> m (Maybe Term)@
-- to add a check that the step preserves the type of the term.
checkStep :: forall m . Env.Readable m => 
  (Term -> MaybeT m Term) -> Term -> MaybeT m Term
checkStep step term = do
  result <- step term
  lift . Err.noneM . Err.augmentM (stepErr result) $ do
    t_ty <- typeOf term
    r_ty <- typeOf result
    if t_ty == r_ty
    then return result
    else 
      Err.throw 
        $ "Transformation does not preserve type."
        ++ "\nBefore: [" ++ show t_ty ++ "]"
        ++ "\nAfter: [" ++ show r_ty ++ "]"
  where
  stepErr :: Term -> EitherT Err.Err m Err.Err
  stepErr result = do
    t_s <- showM term
    t_s' <- showM result
    Err.throw
      $ "In the transformation:"
      ++ "\nFrom: [" ++ t_s ++ "]"
      ++ "\nTo: [" ++ t_s' ++ "]"

-- | Returns the type of a given 'Term',
-- within a readable type environment.
-- Can throw type checking errors.
typeOf :: TypingMonad m => Term -> m Type  
typeOf term = id
  . Err.augmentM (termErr term)
  . Fold.paraM doBoth
  $ term
  where
  -- This is added to the existing error 
  -- if a type checking error is thrown.
  termErr :: TypingMonad m => Term -> m Err.Err
  termErr t = do
    t_s <- showM t
    return $ "When type checking: [" ++ t_s ++ "]."
  
  -- Check the term for type errors, then return the type.
  doBoth :: TypingMonad m => Term' (Type, Term) -> m Type
  doBoth ft = 
    Err.augmentM (termErr $ Fold.recover ft)
      $ fcheck ft >> ftype ft
    
  applyArg :: Term' (Type, Term) -> Term' (Type, Term)
  applyArg (App' (Type.Fun _ res_ty, f) ((_, t):ts)) =  
    App' (res_ty, app f [t]) ts
    
  -- Checks the term for any type errors.
  -- Is combined with 'ftype' in 'doBoth'
  -- to get the full monadic Term'-algebra for typing.
  fcheck :: TypingMonad m => Term' (Type, Term) -> m ()

  -- Check that a variable has a type in the environment
  fcheck (Var' idx) = do
    depth <- Env.bindingDepth
    Err.when (fromEnum idx >= depth)
      $ "Found index: " ++ show idx ++ " in an environment which only "
      ++ "has type bindings up to index: " ++ show depth
      
  -- Check that term application has the correct function type on the left
  fcheck app_t@(App' (fun_ty, _) ((arg_ty, _) : args))
    | not (Type.isFun fun_ty) = Err.throw
      $ "Term application with non function type term leftmost."
      
    | Type.Fun arg_ty' _ <- fun_ty
    , arg_ty /= arg_ty' = Err.throw
      $ "Term application with incorrect argument type."
      
    | otherwise =
      fcheck (applyArg app_t)
      
  -- Check that a fixpoint matches the type of its bound variable
  fcheck (Fix' (Bind _ fix_ty) (fix_ty', _))
    | fix_ty /= fix_ty' = Err.throw
      $ "Fixpoint does not match its declared type."
      
  -- Check that an constructor is for an inductive type, and that the 
  -- constructor index is not greater than the number of constructors.
  fcheck (Con' ty n) 
    | nlength (Type.unfold ty) <= n = Err.throw
      $ "The given inductive type does not have that many constructors."
      
  -- Check that the pattern matched branches properly match the 
  -- constructors of the inductive type
  fcheck (Case' ind_ty (ind_ty', _) falts)
    | Type.Base ind_ty /= ind_ty' = Err.throw
      $ "Inductive type of pattern match [" ++ show ind_ty ++ "] does not"
      ++ " match type of matched term [" ++ show ind_ty' ++ "]"
      
    | length falts /= length cons = Err.throw 
      $ "Number of patterns does not match number of constructors."
      
    | not alts_correct = Err.throw 
      $ "Patterns matched do not match the constructors of the inductive type."
    where
    cons = Type.unfold ind_ty
    alts_correct = and . zipWith checkAlt cons $ falts
      where
      checkAlt (Bind _ con_ty) (Alt' bs (res_ty, _)) =
        con_ty == Type.unflatten (map boundType bs ++ [ind_ty'])
        
  fcheck _ = 
    return ()
 
  
  -- | Returns the type of a term, given the type of its subterms.
  ftype :: TypingMonad m => Term' (Type, Term) -> m Type
  ftype (Absurd' ty) =
    return ty
  ftype (Var' idx) =
    liftM boundType (Env.boundAt idx)
  ftype (Lam' (Bind _ ty) (res, _)) = 
    return (Type.Fun ty res)
  ftype (App' (ty, _) []) = 
    return ty
  ftype t@(App' {}) = 
    ftype (applyArg t)
  ftype (Fix' (Bind _ ty) _) = 
    return ty
  ftype (Con' ind_ty n) =
    return
    . boundType
    . (!! fromEnum n)
    $ Type.unfold ind_ty
  ftype (Case' _ _ (Alt' _ (ty, _) : _)) =
    return ty

