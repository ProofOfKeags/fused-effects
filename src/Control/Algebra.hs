{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The 'Algebra' class is the mechanism with which effects are interpreted.

An instance of the 'Algebra' class defines an interpretation of an effect signature atop a given monad.

@since 1.0.0.0
-}
module Control.Algebra
( Handler
, Algebra(..)
, thread
, run
, Has
, send
  -- * Re-exports
, (:+:) (..)
) where

import           Control.Effect.Catch.Internal
import           Control.Effect.Choose.Internal
import           Control.Effect.Empty.Internal
import           Control.Effect.Error.Internal
import           Control.Effect.Lift.Internal
import           Control.Effect.NonDet.Internal
import           Control.Effect.Reader.Internal
import           Control.Effect.State.Internal
import           Control.Effect.Sum ((:+:)(..), Member(..), Members)
import           Control.Effect.Throw.Internal
import           Control.Effect.Writer.Internal
import qualified Control.Monad.Trans.Except as Except
import qualified Control.Monad.Trans.Identity as Identity
import qualified Control.Monad.Trans.Reader as Reader
import qualified Control.Monad.Trans.RWS.Lazy as RWS.Lazy
import qualified Control.Monad.Trans.RWS.Strict as RWS.Strict
import qualified Control.Monad.Trans.State.Lazy as State.Lazy
import qualified Control.Monad.Trans.State.Strict as State.Strict
import qualified Control.Monad.Trans.Writer.Lazy as Writer.Lazy
import qualified Control.Monad.Trans.Writer.Strict as Writer.Strict
import           Data.Functor.Compose
import           Data.Functor.Identity
import           Data.List.NonEmpty (NonEmpty)
import           Data.Monoid
import qualified Data.Semigroup as S
import           Data.Tuple (swap)

-- | Handlers take an action in @m@ bundled up with some state in some context functor @ctx@, and return an action in @n@ producing a derived state in @ctx@.
--
-- These are expected to be well-behaved /distributive laws/, and are required to adhere to the following laws:
--
-- @
-- handler '.' 'fmap' 'pure' = 'pure'
-- @
-- @
-- handler '.' 'fmap' (k '=<<') = handler '.' 'fmap' k 'Control.Monad.<=<' handler
-- @
--
-- respectively expressing that the handler does not alter the context of pure computations, and that the handler distributes over monadic composition.
--
-- Handlers compose with handlers, using e.g. "Data.Functor.Compose".'Compose' to ensure that the result is itself well-typed as a 'Handler':
--
-- @
-- 'fmap' 'Compose' '.' handler1 '.' 'fmap' handler2 '.' 'getCompose'
-- @
--
-- with monad homomorphisms on the left and right:
--
-- @
-- hom '.' handler
-- @
-- @
-- handler '.' 'fmap' hom
-- @
type Handler ctx m n = forall x . ctx (m x) -> n (ctx x)

-- | The class of carriers (results) for algebras (effect handlers) over signatures (effects), whose actions are given by the 'alg' method.
--
-- @since 1.0.0.0
class Monad m => Algebra sig m | m -> sig where
  -- | Interpret an effect, running any nested actions using a 'Handler' starting from an initial state in @ctx@.
  alg :: Functor ctx => Handler ctx n m -> ctx () -> sig n a -> m (ctx a)

thread
  :: ( Functor ctx1
     , Functor ctx2
     , Algebra sig m
     )
  => Handler ctx1 n m
  -> Handler ctx2 o n
  -> ctx1 (ctx2 ())
  -> sig o a
  -> m (ctx1 (ctx2 a))
thread hdl1 hdl2 ctx = fmap getCompose . alg (fmap Compose . hdl1 . fmap hdl2 . getCompose) (Compose ctx)
{-# INLINE thread #-}


-- | Run an action exhausted of effects to produce its final result value.
--
-- @since 1.0.0.0
run :: Identity a -> a
run = runIdentity
{-# INLINE run #-}


-- | @m@ is a carrier for @sig@ containing @eff@.
--
-- Note that if @eff@ is a sum, it will be decomposed into multiple 'Member' constraints. While this technically allows one to combine multiple unrelated effects into a single 'Has' constraint, doing so has two significant drawbacks:
--
-- 1. Due to [a problem with recursive type families](https://gitlab.haskell.org/ghc/ghc/issues/8095), this can lead to significantly slower compiles.
--
-- 2. It defeats @ghc@’s warnings for redundant constraints, and thus can lead to a proliferation of redundant constraints as code is changed.
type Has eff sig m = (Members eff sig, Algebra sig m)

-- | Construct a request for an effect to be interpreted by some handler later on.
send :: (Member eff sig, Algebra sig m) => eff m a -> m a
send = fmap runIdentity . alg (fmap Identity . runIdentity) (Identity ()) . inj
{-# INLINE send #-}


-- base

instance Algebra (Lift IO) IO where
  alg hdl ctx (LiftWith with k) = with hdl ctx >>= hdl . fmap k

instance Algebra (Lift Identity) Identity where
  alg hdl ctx (LiftWith with k) = with hdl ctx >>= hdl . fmap k

instance Algebra Choose NonEmpty where
  alg hdl ctx (Choose m) = hdl (m True <$ ctx) S.<> hdl (m False <$ ctx)

instance Algebra Empty Maybe where
  alg _ _ Empty = Nothing

instance Algebra (Error e) (Either e) where
  alg hdl ctx = \case
    L (Throw e)     -> Left e
    R (Catch m h k) -> either (hdl . (<$ ctx) . h) pure (hdl (m <$ ctx)) >>= hdl . fmap k

instance Algebra (Reader r) ((->) r) where
  alg hdl ctx = \case
    Ask       k -> \ r -> hdl (k r <$ ctx) r
    Local f m k -> \ r -> hdl (fmap k (hdl (m <$ ctx) (f r))) r

instance Algebra NonDet [] where
  alg hdl ctx = \case
    L Empty      -> []
    R (Choose k) -> hdl (k True <$ ctx) ++ hdl (k False <$ ctx)

instance Monoid w => Algebra (Writer w) ((,) w) where
  alg hdl ctx = \case
    Tell w     k -> let (w', k') = hdl (k <$ ctx) in (mappend w w', k')
    Listen m   k -> let (w, a) = hdl (m <$ ctx) ; (w', a') = hdl (fmap (k w) a) in (mappend w w', a')
    Censor f m k -> let (w, a) = hdl (m <$ ctx) ; (w', a') = hdl (fmap k a) in (mappend (f w) w', a')


-- transformers

instance Algebra sig m => Algebra (Error e :+: sig) (Except.ExceptT e m) where
  alg hdl ctx = \case
    L (L (Throw e))     -> Except.throwE e
    L (R (Catch m h k)) -> Except.catchE (hdl (m <$ ctx)) (hdl . (<$ ctx) . h) >>= hdl . fmap k
    R other             -> Except.ExceptT $ thread (either (pure . Left) Except.runExceptT) hdl (Right ctx) other

deriving instance Algebra sig m => Algebra sig (Identity.IdentityT m)

#if MIN_VERSION_base(4,12,0)
-- | This instance permits effectful actions to be lifted into the 'Ap' monad
-- given a monoidal return type, which can provide clarity when chaining calls
-- to 'mappend'.
--
-- > mappend <$> act1 <*> (mappend <$> act2 <*> act3)
--
-- is equivalent to
--
-- > getAp (act1 <> act2 <> act3)
--
-- @since 1.0.1.0
deriving instance Algebra sig m => Algebra sig (Ap m)
#endif

-- | This instance permits effectful actions to be lifted into the 'Alt' monad,
-- which eases the invocation of repeated alternation with 'Control.Applicative.<|>':
--
-- > a <|> b <|> c <|> d
--
-- is equivalent to
--
-- > getAlt (mconcat [a, b, c, d])
--
-- @since 1.0.1.0
deriving instance Algebra sig m => Algebra sig (Alt m)

instance Algebra sig m => Algebra (Reader r :+: sig) (Reader.ReaderT r m) where
  alg hdl ctx = \case
    L (Ask       k) -> Reader.ask >>= hdl . (<$ ctx) . k
    L (Local f m k) -> Reader.local f (hdl (m <$ ctx)) >>= hdl . fmap k
    R other         -> Reader.ReaderT $ \ r -> alg ((`Reader.runReaderT` r) . hdl) ctx other

newtype RWSTF w s a = RWSTF { unRWSTF :: (a, s, w) }
  deriving (Functor)

toRWSTF :: Monoid w => w -> (a, s, w) -> RWSTF w s a
toRWSTF w (a, s, w') = RWSTF (a, s, mappend w w')
{-# INLINE toRWSTF #-}

instance (Algebra sig m, Monoid w) => Algebra (Reader r :+: Writer w :+: State s :+: sig) (RWS.Lazy.RWST r w s m) where
  alg hdl ctx = \case
    L (Ask       k)      -> RWS.Lazy.ask >>= hdl . (<$ ctx) . k
    L (Local f m k)      -> RWS.Lazy.local f (hdl (m <$ ctx)) >>= hdl . fmap k
    R (L (Tell w k))     -> RWS.Lazy.tell w *> hdl (k <$ ctx)
    R (L (Listen m k))   -> RWS.Lazy.listen (hdl (m <$ ctx)) >>= hdl . uncurry (fmap . k) . swap
    R (L (Censor f m k)) -> RWS.Lazy.censor f (hdl (m <$ ctx)) >>= hdl . fmap k
    R (R (L (Get   k)))  -> RWS.Lazy.get >>= hdl . (<$ ctx) . k
    R (R (L (Put s k)))  -> RWS.Lazy.put s *> hdl (k <$ ctx)
    R (R (R other))      -> RWS.Lazy.RWST $ \ r s -> unRWSTF <$> thread (\ (RWSTF (x, s, w)) -> toRWSTF w <$> RWS.Lazy.runRWST x r s) hdl (RWSTF (ctx, s, mempty)) other

instance (Algebra sig m, Monoid w) => Algebra (Reader r :+: Writer w :+: State s :+: sig) (RWS.Strict.RWST r w s m) where
  alg hdl ctx = \case
    L (Ask       k)      -> RWS.Strict.ask >>= hdl . (<$ ctx) . k
    L (Local f m k)      -> RWS.Strict.local f (hdl (m <$ ctx)) >>= hdl . fmap k
    R (L (Tell w k))     -> RWS.Strict.tell w *> hdl (k <$ ctx)
    R (L (Listen m k))   -> RWS.Strict.listen (hdl (m <$ ctx)) >>= hdl . uncurry (fmap . k) . swap
    R (L (Censor f m k)) -> RWS.Strict.censor f (hdl (m <$ ctx)) >>= hdl . fmap k
    R (R (L (Get   k)))  -> RWS.Strict.get >>= hdl . (<$ ctx) . k
    R (R (L (Put s k)))  -> RWS.Strict.put s *> hdl (k <$ ctx)
    R (R (R other))      -> RWS.Strict.RWST $ \ r s -> unRWSTF <$> thread (\ (RWSTF (x, s, w)) -> toRWSTF w <$> RWS.Strict.runRWST x r s) hdl (RWSTF (ctx, s, mempty)) other

instance Algebra sig m => Algebra (State s :+: sig) (State.Lazy.StateT s m) where
  alg hdl ctx = \case
    L (Get   k) -> State.Lazy.get >>= hdl . (<$ ctx) . k
    L (Put s k) -> State.Lazy.put s *> hdl (k <$ ctx)
    R other     -> State.Lazy.StateT $ \ s -> swap <$> thread (\ (s, x) -> swap <$> State.Lazy.runStateT x s) hdl (s, ctx) other

instance Algebra sig m => Algebra (State s :+: sig) (State.Strict.StateT s m) where
  alg hdl ctx = \case
    L (Get   k) -> State.Strict.get >>= hdl . (<$ ctx) . k
    L (Put s k) -> State.Strict.put s *> hdl (k <$ ctx)
    R other     -> State.Strict.StateT $ \ s -> swap <$> thread (\ (s, x) -> swap <$> State.Strict.runStateT x s) hdl (s, ctx) other

instance (Algebra sig m, Monoid w) => Algebra (Writer w :+: sig) (Writer.Lazy.WriterT w m) where
  alg hdl ctx = \case
    L (Tell w k)     -> Writer.Lazy.tell w *> hdl (k <$ ctx)
    L (Listen m k)   -> Writer.Lazy.listen (hdl (m <$ ctx)) >>= hdl . uncurry (fmap . k) . swap
    L (Censor f m k) -> Writer.Lazy.censor f (hdl (m <$ ctx)) >>= hdl . fmap k
    R other          -> Writer.Lazy.WriterT $ swap <$> thread (\ (s, x) -> swap . fmap (mappend s) <$> Writer.Lazy.runWriterT x) hdl (mempty, ctx) other

instance (Algebra sig m, Monoid w) => Algebra (Writer w :+: sig) (Writer.Strict.WriterT w m) where
  alg hdl ctx = \case
    L (Tell w k)     -> Writer.Strict.tell w *> hdl (k <$ ctx)
    L (Listen m k)   -> Writer.Strict.listen (hdl (m <$ ctx)) >>= hdl . uncurry (fmap . k) . swap
    L (Censor f m k) -> Writer.Strict.censor f (hdl (m <$ ctx)) >>= hdl . fmap k
    R other          -> Writer.Strict.WriterT $ swap <$> thread (\ (s, x) -> swap . fmap (mappend s) <$> Writer.Strict.runWriterT x) hdl (mempty, ctx) other
