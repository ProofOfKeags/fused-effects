{-# LANGUAGE DeriveFunctor, ExistentialQuantification, FlexibleContexts, FlexibleInstances, MultiParamTypeClasses, StandaloneDeriving, TypeOperators, UndecidableInstances #-}
module Control.Effect.Error where

import Control.Effect
import Control.Monad ((<=<))

data Error exc m k
  = Throw exc
  | forall b . Catch (m b) (exc -> m b) (b -> k)

deriving instance Functor (Error exc m)

instance Effect (Error exc) where
  hfmap _ (Throw exc)   = Throw exc
  hfmap f (Catch m h k) = Catch (f m) (f . h) k

  handle _     _       (Throw exc)   = Throw exc
  handle state handler (Catch m h k) = Catch (handler (m <$ state)) (handler . (<$ state) . h) (handler . fmap k)

throw :: (Subset (Error exc) sig, TermMonad m sig) => exc -> m a
throw = send . Throw

catch :: (Subset (Error exc) sig, TermMonad m sig) => m a -> (exc -> m a) -> m a
catch m h = send (Catch m h pure)


runError :: TermMonad m sig => Eff (ErrorH exc m) a -> m (Either exc a)
runError = runErrorH . runEff var

newtype ErrorH e m a = ErrorH { runErrorH :: m (Either e a) }

instance Carrier (Either e) (ErrorH e) where
  joinl mf = ErrorH (mf >>= runErrorH)

  suspend f = f (Right ())

  resume = either (pure . Left) runErrorH

  wrap = ErrorH

instance TermMonad m sig => TermAlgebra (ErrorH e m) (Error e :+: sig) where
  var a = ErrorH (pure (Right a))
  con = alg \/ (ErrorH . con . handle (Right ()) (either (pure . Left) runErrorH))
    where alg (Throw e)     = ErrorH (pure (Left e))
          alg (Catch m h k) = ErrorH (runErrorH m >>= either (either (pure . Left) (runErrorH . k) <=< runErrorH . h) (runErrorH . k))
