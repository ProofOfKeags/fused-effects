{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
-- | Labelled effects, allowing flexible disambiguation and dependency of parametric effects.
--
-- @since 1.0.2.0
module Control.Effect.Labelled
( runLabelled
, Labelled(Labelled)
, LabelledMember(..)
, HasLabelled
, sendLabelled
, runUnderLabel
, UnderLabel(UnderLabel)
, module Control.Algebra
) where

import Control.Algebra
import Control.Applicative (Alternative)
import Control.Monad (MonadPlus)
import Control.Monad.Fail as Fail
import Control.Monad.IO.Class
import Control.Monad.Trans.Class

-- | An effect transformer turning effects into labelled effects, and a carrier transformer turning carriers into labelled carriers for the same (labelled) effects.
--
-- @since 1.0.2.0
newtype Labelled (label :: k) (sub :: (* -> *) -> (* -> *)) m a = Labelled { runLabelled :: sub m a }
  deriving (Alternative, Applicative, Effect, Functor, HFunctor, Monad, Fail.MonadFail, MonadIO, MonadPlus, MonadTrans)

instance (Algebra (eff :+: sig) (sub m), HFunctor eff, HFunctor sig) => Algebra (Labelled label eff :+: sig) (Labelled label sub m) where
  alg = \case
    L eff -> Labelled (send (handleCoercible (runLabelled eff)))
    R sig -> Labelled (send (handleCoercible sig))


-- | The class of labelled types present in a signature.
--
-- @since 1.0.2.0
class LabelledMember label (sub :: (* -> *) -> (* -> *)) sup | label sup -> sub where
  -- | Inject a member of a signature into the signature.
  --
  -- @since 1.0.2.0
  injLabelled :: Labelled label sub m a -> sup m a

-- | Reflexivity: @t@ is a member of itself.
instance LabelledMember label t (Labelled label t) where
  injLabelled = id

-- | Left-recursion: if @t@ is a member of @l1 ':+:' l2 ':+:' r@, then we can inject it into @(l1 ':+:' l2) ':+:' r@ by injection into a right-recursive signature, followed by left-association.
instance {-# OVERLAPPABLE #-}
         LabelledMember label t (l1 :+: l2 :+: r)
      => LabelledMember label t ((l1 :+: l2) :+: r) where
  injLabelled = reassoc . injLabelled where
    reassoc (L l)     = L (L l)
    reassoc (R (L l)) = L (R l)
    reassoc (R (R r)) = R r

-- | Left-occurrence: if @t@ is at the head of a signature, we can inject it in O(1).
instance {-# OVERLAPPABLE #-}
         LabelledMember label l (Labelled label l :+: r) where
  injLabelled = L

-- | Right-recursion: if @t@ is a member of @r@, we can inject it into @r@ in O(n), followed by lifting that into @l ':+:' r@ in O(1).
instance {-# OVERLAPPABLE #-}
         LabelledMember label l r
      => LabelledMember label l (l' :+: r) where
  injLabelled = R . injLabelled


-- | @m@ is a carrier for @sig@ containing @eff@ associated with @label@.
--
-- Note that if @eff@ is a sum, it will /not/ be decomposed into multiple 'LabelledMember' constraints. While this technically is possible, it results in unsolvable constraints, as the functional dependencies in 'Labelled' prevent assocating the same label with multiple distinct effects within a signature.
--
-- @since 1.0.2.0
type HasLabelled label eff sig m = (LabelledMember label eff sig, Algebra sig m)

-- | Construct a request for a labelled effect to be interpreted by some handler later on.
--
-- @since 1.0.2.0
sendLabelled :: forall label eff sig m a . HasLabelled label eff sig m => eff m a -> m a
sendLabelled = alg . injLabelled @label . Labelled
{-# INLINABLE sendLabelled #-}


-- | A transformer to lift effectful actions to labelled effectful actions.
--
-- @since 1.0.2.0
newtype UnderLabel (label :: k) (sub :: (* -> *) -> (* -> *)) (m :: * -> *) a = UnderLabel { runUnderLabel :: m a }
  deriving (Alternative, Applicative, Functor, Monad, Fail.MonadFail, MonadIO, MonadPlus)

instance MonadTrans (UnderLabel sub label) where
  lift = UnderLabel

instance (LabelledMember label sub sig, HFunctor sub, Algebra sig m) => Algebra (sub :+: sig) (UnderLabel label sub m) where
  alg = \case
    L sub -> UnderLabel (sendLabelled @label (handleCoercible sub))
    R sig -> UnderLabel (send (handleCoercible sig))
