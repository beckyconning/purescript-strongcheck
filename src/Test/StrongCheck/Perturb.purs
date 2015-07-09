module Test.StrongCheck.Perturb
  ( Attempts(..)
  , Perturb
  , Perturber(..)
  , PerturberRec(..)
  , (</\>)
  , (<\/>)
  , bounded
  , boundedInt
  , dist
  , dims
  , enumerated
  , nonPerturber
  , perturb
  , perturber
  , searchIn'
  , searchIn
  , unPerturber
  ) where

import Prelude

import Test.StrongCheck.Gen
import Test.StrongCheck

import Data.Traversable (sequence)
import Data.Foldable (Foldable, find, sum)
import Data.Tuple (Tuple(..), fst, snd)
import Data.Monoid (mempty)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Enum (Cardinality(..), Enum, cardinality)
import Data.Int (fromNumber, toNumber) 
import Data.Functor.Invariant (Invariant)
import qualified Data.String as S
import qualified Data.Array as A
import qualified Data.List as L

import Math

newtype Attempts = Attempts Int

newtype Perturber a = Perturber (PerturberRec a)

type PerturberRec a =
  { perturb :: Number -> a -> Gen a
  , dist    :: a -> a -> Number
  , dims    :: a -> Number
  }

unPerturber :: forall a. Perturber a -> PerturberRec a
unPerturber (Perturber v) = v

instance perturberInvariant :: Invariant Perturber where
  imap f g (Perturber p) =
    Perturber { perturb: \n b -> f <$> p.perturb n (g b)
              , dist: \b1 b2 -> p.dist (g b1) (g b2)
              , dims: \b -> p.dims (g b)
              }

-- | The class for things which can be perturbed.
-- |
-- | Laws:
-- |   forall a, 0 >= n <= 1:
-- |   ((>=) n) <<< dist a <$> (perturb n a) must be an infinite generator of `true` values.
class Perturb a where
  perturber :: Perturber a

perturb :: forall a. (Perturb a) => Number -> a -> Gen a
perturb = (unPerturber perturber).perturb

dist :: forall a. (Perturb a) => a -> a -> Number
dist = (unPerturber perturber).dist

dims :: forall a. (Perturb a) => a -> Number
dims = (unPerturber perturber).dims

-- | Creates a perturber that perturbs nothing.
nonPerturber :: forall a. Perturber a
nonPerturber = Perturber {
  perturb : const pure,
  dist    : const $ const zero,
  dims    : const zero }

-- | Given one example, searches for other examples that satisfy a provided
-- | boolean predicate.
-- |
-- | The search operates out-to-in, in an attempt to find examples that are
-- | as far removed from the provided example as possible. The sampling size
-- | parameter determines how many samples to take at every level of
-- | searching, while the attempts parameter determines how many levels.
searchIn' :: forall a. (Perturb a) => Attempts -> Int -> (a -> Boolean) -> a -> Gen a
searchIn' (Attempts k) n f a = search0 k 1.0
  where
  search0 :: Int -> Number -> Gen a 
  search0 k d = if k <= 0
                then mempty
                else do
                  a' <- find f <$> (takeGen 1 $ chunked n (perturb d a))
                  fromMaybe mempty (pure <$> a') <> search0 (k - 1) (d / 2.0)


-- | The same as search', but uses defaults for attempt count and sample size.
-- | Will search a total of 10,000 examples before giving up.
searchIn :: forall a. (Perturb a) => (a -> Boolean) -> a -> Gen a
searchIn = searchIn' (Attempts 1000) 10

infixr 6 </\>

-- | Combines two perturbers to produce a perturber of the product
(</\>) :: forall a b. Perturber a -> Perturber b -> Perturber (Tuple a b)
(</\>) (Perturber l) (Perturber r) = Perturber { perturb : perturb', dist : dist', dims : dims' }
  where perturb' d (Tuple a b) =
          let dx = delta (l.dims a + r.dims b) d
              dx2 = dx * dx
              ld = sqrt $ dx2 * l.dims a
              rd = sqrt $ dx2 * r.dims b
          in Tuple <$> l.perturb ld a <*> r.perturb rd b

        dist' (Tuple a1 b1) (Tuple a2 b2) = toDist [l.dist a1 a2, r.dist b1 b2]

        dims' (Tuple a b) = l.dims a + r.dims b

infixr 6 <\/>

-- | Combines two perturbers to produce a perturber of the sum
(<\/>) :: forall a b. Perturber a -> Perturber b -> Perturber (Either a b)
(<\/>) (Perturber l) (Perturber r) = Perturber { perturb : perturb', dist : dist', dims : dims' }
  where perturb' d (Left  a) = Left <$> l.perturb d a
        perturb' d (Right b) = Right <$> r.perturb d b

        dist' (Left  a1) (Left  a2) = l.dist a1 a2
        dist' (Right b1) (Right b2) = r.dist b1 b2
        dist' _ _                   = 1.0 -- FIXME: underconstrained

        dims' (Left  a) = l.dims a
        dims' (Right b) = r.dims b

-- | Creates a perturber for numbers that fall within the specified range.
bounded :: Number -> Number -> Perturber Number
bounded a b =
  let l = min a b
      u = max a b

      length = u - l

      clamp n = max l (min u n)

      perturb' d v = do dx <- arbitrary
                        return <<< clamp $ dx * length * d + v

      dist' a b = abs (a - b)

      dims' = const 1.0

  in  Perturber { perturb : perturb', dist : dist', dims : dims' }

-- | Creates a perturber for integers that fall within the specified range.
boundedInt :: Int -> Int -> Perturber Int
boundedInt aInt bInt =
  let a = toNumber aInt
      b = toNumber bInt
      
      l = floor $ min a b
      u = ceil $ max a b

      length = u - l

      clamp n = max l (min u n)

      perturb' :: Number -> Int -> Gen Int
      perturb' d v = do
        dx <- arbitrary
        let n :: Number
            n = round $ clamp (toNumber v + d * length * dx)

            i :: Int
            i = fromMaybe (aInt + one) $ fromNumber n
        pure i

      dist' :: Int -> Int -> Number
      dist' a b = abs $ toNumber (a - b)

      dims' = const 1.0

  in  Perturber { perturb : perturb', dist : dist', dims : dims' }

enumerated :: forall a. (Eq a) => a -> Array a -> Perturber a
enumerated x xs = Perturber { perturb : perturb', dist : dist', dims : dims' }
  where len = 1 + A.length xs
        cutoff = 1.0 / (2.0 * toNumber len)

        perturb' n a = if n < cutoff then pure a else elements x $ L.toList xs
        dist' a1 a2 = if a2 == a2 then 0.0 else cutoff
        dims' a = if len > 0 then 1.0 else 0.0

instance perturbArbEnum :: (Enum a, Eq a) => Perturb (ArbEnum a) where
  perturber = Perturber { perturb : perturb', dist : dist', dims : dims' }
    where perturb' n e = cardPerturb1 (cardPerturb1F e n)

          dist' a b = cardDist1 f a b where
            f (Cardinality sz) a b = if runArbEnum a == runArbEnum b then 0.0 else 1.0 / (2.0 * toNumber sz)

          dims' e = enumDims f e where
            f (Cardinality sz) e = if sz <= 0 then 0.0 else 1.0

instance perturbNumber :: Perturb Number where
  perturber = Perturber { perturb : perturb', dist : dist', dims : dims' }
    where pertrub' :: Number -> Number -> Gen Number
          perturb' 0.0 n = pure n
          perturb' d n = do
            u <- uniform -- 'up to' d
            s <- runSignum <$> arbitrary
            return $ toNumber s * (Math.exp(k0 * (u * d)) - 1.0) + n

          dist' :: Number -> Number -> Number
          dist' a b =
            let from y = Math.log(y + 1.0) / k0
            in  (Math.min 1.0) <<< Math.abs <<< from $ Math.abs (a - b)
                
          dims' :: Number -> Number
          dims' = const 1.0

instance perturbInt :: Perturb Int where
  perturber = Perturber {perturb: perturb', dist: dist', dims: dims'}
    where perturb' 0.0 n = pure n
          perturb' d n = do
            u <- uniform 
            s <- runSignum <$> arbitrary
            pure $ fromMaybe n $ fromNumber $ Math.round (toNumber s * (Math.exp (k0 * (u * d)) - 1.0) + toNumber n)

          dist' a b =
            let from y = Math.log(y + 1.0) / k0
            in (Math.min 1.0) <<< Math.abs <<< from $ Math.abs (toNumber a - toNumber b)

          dims' = const 1.0

instance perturbList :: (Perturb a) => Perturb (L.List a) where
  perturber = Perturber {perturb: perturb', dist: dist', dims: dims'}
    where perturb' d L.Nil = pure $ L.Nil
          perturb' 0.0 a = sequence $ perturb 0.0 <$> a
          perturb' d a = let dx = delta (toNumber $ L.length a) d
                         in sequence $ perturb dx <$> a

          dist' a b = toDist $ L.zipWith dist a b

          dims' = toNumber <<< L.length
            
instance perturbChar :: Perturb Char where
  perturber = Perturber { perturb : perturb', dist : dist', dims : dims' }
    where
    pertrub' :: Number -> Char -> Gen Char
    perturb' n e = if n < 1.0 / (2.0 * 65536.0) then pure e else (arbitrary :: Gen Char)

    dist' a b = if a == b then 0.0 else 1.0 / (2.0 * 65536.0)

    dims' = const 1.0

instance perturbBoolean :: Perturb Boolean where
  perturber = Perturber { perturb : perturb', dist : dist', dims : dims' }
    where perturb' n e = runArbEnum <$> perturb n (ArbEnum e)

          dist' a b = dist (ArbEnum a) (ArbEnum b)

          dims' = const 1.0

instance perturbString :: Perturb String where
  perturber = Perturber { perturb : perturb', dist : dist', dims : dims' }
    where perturb' d s = (S.fromCharArray <<< L.fromList) <$> perturb d (L.toList (S.toCharArray s))

          dist' s1 s2 = dist (L.toList $ S.toCharArray s1) (L.toList $ S.toCharArray s2)

          dims' = dims <<< L.toList <<< S.toCharArray

-- magical constants
maxNumber :: Number
maxNumber = 9007199254740992.0

-- math
k0 :: Number
k0 = Math.log(maxNumber + 1.0)

square :: Number -> Number
square = flip Math.pow 2.0

toDist :: forall f. (Foldable f, Functor f) => f Number -> Number
toDist xs = Math.sqrt (sum $ square <$> xs)

delta :: Number -> Number -> Number
delta n d = Math.sqrt (d * d / n)

-- ScopedTypeVariables
enumDims :: forall a. (Enum a) => (Cardinality a -> a -> Number) -> a -> Number
enumDims f = f cardinality

-- ScopedTypeVariables
cardPerturb1 :: forall f a. (Enum a) => (Cardinality a -> f a) -> f a
cardPerturb1 f = f cardinality

-- ScopedTypeVariables
cardDist1 :: forall a. (Enum a) => (Cardinality a -> a -> a -> Number) -> a -> a -> Number
cardDist1 f = f cardinality

-- workaround to avoid:
-- Attempted to unify a constrained type (Test.StrongCheck.Arbitrary u15286) =>
-- Test.StrongCheck.Gen.Gen<u15286> with another type.
cardPerturb1F :: forall a. (Enum a) => a -> Number -> Cardinality a -> Gen a
cardPerturb1F a n (Cardinality sz) = if n < 1.0 / (2.0 * toNumber sz) then pure a else (runArbEnum <$> arbitrary)

