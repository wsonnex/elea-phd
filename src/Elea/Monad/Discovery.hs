-- | Useful instances for the monad classes in "Elea.Monad.Discovery".
module Elea.Monad.Discovery
(
  module Elea.Monad.Discovery.Class,
  
  IgnoreT, Ignore,
  ignoreT, ignore,
  
  ListenerT, Listener,
  listener, listenerT,
  mapListenerT,
  trace,
)
where

import Elea.Prelude hiding ( tell, listen, trace )
import Elea.Term
import Elea.Monad.Discovery.Class
import Elea.Monad.Discovery.EquationSet ( EqSet )
import qualified Elea.Monad.Discovery.EquationSet as EqSet
import qualified Elea.Prelude as Prelude
import qualified Elea.Monad.Env as Env
import qualified Elea.Monad.Definitions.Class as Defs
import qualified Elea.Monad.Definitions.Data as Defs
import qualified Control.Monad.Writer as Writer

-- | A monad which ignores discoveries it is passed
newtype IgnoreT m a 
  = IgnoreT { ignoreT :: m a }
  deriving ( Functor, Applicative, Monad )
  
type Ignore = IgnoreT Identity

ignore :: Ignore a -> a
ignore = runIdentity . ignoreT

instance MonadTrans IgnoreT where 
  lift = IgnoreT

instance Tells Ignore where
  tell _ = return ()

-- | A monad to record discoveries
newtype ListenerT m a 
  = ListenerT { runListenerT :: WriterT EqSet m a }
  deriving ( Functor, Applicative, Monad, MonadTrans )
  
type Listener = ListenerT Identity
  
listenerT :: Monad m => ListenerT m a -> m (a, [Prop])
listenerT = liftM (second EqSet.toList) . runWriterT . runListenerT

listener :: Listener a -> (a, [Prop])
listener = runIdentity . listenerT

trace :: forall m a . Listens m
  => m a -> m a
trace run = do
  (x, eqs) <- listen run
  if null eqs
  then return x
  else return
    . Prelude.trace "[Discovered Equations]"
    $ foldr traceEq x eqs
  where
  traceEq :: Prop -> a -> a
  traceEq eq x =
    Prelude.trace ("\n" ++ show eq) x
    
mapListenerT :: Monad m 
  => (m (a, EqSet) -> n (b, EqSet)) 
  -> ListenerT m a -> ListenerT n b
mapListenerT f = ListenerT . mapWriterT f . runListenerT

instance Monad m => Tells (ListenerT m) where
  tell = id
    . ListenerT 
    . Writer.tell 
    . EqSet.singleton
  
instance Monad m => Listens (ListenerT m) where
  listen = id
    . ListenerT 
    . liftM (second EqSet.toList) 
    . Writer.listen 
    . runListenerT
  
instance Env.Write m => Env.Write (ListenerT m) where
  bindAt at b = mapListenerT (Env.bindAt at b)
  matched m = mapListenerT (Env.matched m)
  forgetMatches w = mapListenerT (Env.forgetMatches w)
 
instance Env.Read m => Env.Read (ListenerT m) where
  bindings = lift Env.bindings

instance Defs.Read m => Defs.Read (ListenerT m) where
  lookupTerm n = lift . Defs.lookupTerm n
  lookupType n = lift . Defs.lookupType n
  lookupName = lift . Defs.lookupName
  
instance Defs.Write m => Defs.Write (ListenerT m) where
  defineTerm n = lift . Defs.defineTerm n
  defineType n = lift . Defs.defineType n
