-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2015-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable
-- 
-- An interval interpretation of types.

{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE BangPatterns #-}

module Cryptol.TypeCheck.Solver.Numeric.Interval where

import Cryptol.TypeCheck.AST
import Cryptol.TypeCheck.Solver.InfNat
import Cryptol.Utils.PP hiding (int)

import           Data.Map ( Map )
import qualified Data.Map as Map
import           Data.Maybe (catMaybes)


-- | Only meaningful for numeric types
typeInterval :: Map TVar Interval -> Type -> Interval
typeInterval varInfo = go
  where
  go ty =
    case ty of
      TUser _ _ t -> go t
      TCon tc ts ->
        case (tc, ts) of
          (TC TCInf, [])      -> iConst Inf
          (TC (TCNum n), [])  -> iConst (Nat n)
          (TF TCAdd, [x,y])   -> iAdd (go x) (go y)
          (TF TCSub, [x,y])   -> iSub (go x) (go y)
          (TF TCMul, [x,y])   -> iMul (go x) (go y)
          (TF TCDiv, [x,y])   -> iDiv (go x) (go y)
          (TF TCMod, [x,y])   -> iMod (go x) (go y)
          (TF TCExp, [x,y])   -> iExp (go x) (go y)
          (TF TCWidth, [x])   -> iWidth (go x)
          (TF TCMin, [x,y])   -> iMin (go x) (go y)
          (TF TCMax, [x,y])   -> iMax (go x) (go y)
          (TF TCLenFromThen, [x,y,z]) ->
            iLenFromThen (go x) (go y) (go z)

          (TF TCLenFromThenTo, [x,y,z]) ->
            iLenFromThenTo (go x) (go y) (go z)
          _ -> iAny

      TVar x -> Map.findWithDefault iAny x varInfo

      _ -> iAny


data IntervalUpdate = NoChange
                    | InvalidInterval TVar
                    | NewIntervals (Map TVar Interval)
                      deriving (Show)

updateInterval :: (TVar,Interval) -> Map TVar Interval -> IntervalUpdate
updateInterval (x,int) varInts =
  case Map.lookup x varInts of
    Just int' ->
      case iIntersect int int' of
        Just val | int' /= val -> NewIntervals (Map.insert x val varInts)
                 | otherwise   -> NoChange
        Nothing                -> InvalidInterval x

    Nothing   -> NewIntervals (Map.insert x int varInts)


computePropIntervals :: Map TVar Interval -> [Prop] -> IntervalUpdate
computePropIntervals ints ps0 = go (3 :: Int) False ints ps0
  where
  go !_n False _ [] = NoChange

  go !n True  is []
    | n > 0     = changed is (go (n-1) False is ps0)
    | otherwise = NewIntervals is

  go !n new   is (p:ps) =
    case foldr (update is) NoChange (propInterval is p) of
      InvalidInterval i -> InvalidInterval i
      NewIntervals is'  -> go n True is' ps
      NoChange          -> go n new  is  ps

  changed a x = case x of
                  NoChange -> NewIntervals a
                  r        -> r

  update is0 int NoChange            = updateInterval int is0
  update _   _   (InvalidInterval i) = InvalidInterval i
  update _   int (NewIntervals is)   = changed is (updateInterval int is)


-- | What we learn about variables from a single prop.
propInterval :: Map TVar Interval -> Prop -> [(TVar,Interval)]
propInterval varInts prop = catMaybes
  [ do ty <- pIsFin prop
       x  <- tIsVar ty
       return (x,iAnyFin)

  , do (l,r) <- pIsEq prop
       x     <- tIsVar l
       return (x,typeInterval varInts r)

  , do (l,r) <- pIsEq prop
       x     <- tIsVar r
       return (x,typeInterval varInts l)

  , do (l,r) <- pIsGeq prop
       x     <- tIsVar l
       let int = typeInterval varInts r
       return (x,int { iUpper = Just Inf })

  , do (l,r) <- pIsGeq prop
       x     <- tIsVar r
       let int = typeInterval varInts l
       return (x,int { iLower = Nat 0 })
  ]

--------------------------------------------------------------------------------

data Interval = Interval
  { iLower :: Nat'          -- ^ lower bound (inclusive)
  , iUpper :: Maybe Nat'    -- ^ upper bound (inclusive)
                            -- If there is no upper bound,
                            -- than all *natural* numbers.
  } deriving (Eq,Show)

ppIntervals :: Map TVar Interval -> Doc
ppIntervals  = vcat . map ppr . Map.toList
  where
  ppr (var,i) = pp var <> char ':' <+> ppInterval i

ppInterval :: Interval -> Doc
ppInterval x = brackets (hsep [ ppr (iLower x)
                              , text ".."
                              , maybe (text "fin") ppr (iUpper x)])
  where
  ppr a = case a of
           Nat n -> integer n
           Inf   -> text "inf"


iIsExact :: Interval -> Maybe Nat'
iIsExact i = if iUpper i == Just (iLower i) then Just (iLower i) else Nothing

iIsFin :: Interval -> Bool
iIsFin i = case iUpper i of
             Just Inf -> False
             _        -> True


-- | Returns 'True' when the intervals definitely overlap, and 'False'
-- otherwise.
iDisjoint :: Interval -> Interval -> Bool
iDisjoint
  (Interval (Nat l1) (Just (Nat h1)))
  (Interval (Nat l2) (Just (Nat h2))) =
    or [ h1 > l2 && h1 < h2, l1 > l2 && l1 < h2 ]
iDisjoint _ _ = False


-- | Intersect two intervals, yielding a new one that describes the space where
-- they overlap.  If the two intervals are disjoint, the result will be
-- 'Nothing'.
iIntersect :: Interval -> Interval -> Maybe Interval
iIntersect i j =
  case (lower,upper) of
    (Nat l, Just (Nat u)) | l <= u -> ok
    (Nat _, Just  Inf)             -> ok
    (Nat _, Nothing)               -> ok
    (Inf,   Just Inf)              -> ok
    _                              -> Nothing
  where

  ok    = Just (Interval lower upper)

  lower = nMax (iLower i) (iLower j)

  upper = case (iUpper i, iUpper j) of
            (Just a, Just b)            -> Just (nMin a b)
            (Nothing,Nothing)           -> Nothing
            (Just l,Nothing) | l /= Inf -> Just l
            (Nothing,Just r) | r /= Inf -> Just r
            _                           -> Nothing


-- | Any value
iAny :: Interval
iAny = Interval (Nat 0) (Just Inf)

-- | Any finite value
iAnyFin :: Interval
iAnyFin = Interval (Nat 0) Nothing

-- | Exactly this value
iConst :: Nat' -> Interval
iConst x = Interval x (Just x)




iAdd :: Interval -> Interval -> Interval
iAdd i j = Interval { iLower = nAdd (iLower i) (iLower j)
                    , iUpper = case (iUpper i, iUpper j) of
                                 (Nothing, Nothing) -> Nothing
                                 (Just x, Just y)   -> Just (nAdd x y)
                                 (Nothing, Just y)  -> upper y
                                 (Just x, Nothing)  -> upper x
                    }
  where
  upper x = case x of
              Inf -> Just Inf
              _   -> Nothing

iMul :: Interval -> Interval -> Interval
iMul i j = Interval { iLower = nMul (iLower i) (iLower j)
                    , iUpper = case (iUpper i, iUpper j) of
                                 (Nothing, Nothing) -> Nothing
                                 (Just x, Just y)   -> Just (nMul x y)
                                 (Nothing, Just y)  -> upper y
                                 (Just x, Nothing)  -> upper x
                    }
  where
  upper x = case x of
              Inf   -> Just Inf
              Nat 0 -> Just (Nat 0)
              _     -> Nothing

iExp :: Interval -> Interval -> Interval
iExp i j = Interval { iLower = nExp (iLower i) (iLower j)
                    , iUpper = case (iUpper i, iUpper j) of
                                 (Nothing, Nothing) -> Nothing
                                 (Just x, Just y)   -> Just (nExp x y)
                                 (Nothing, Just y)  -> upperR y
                                 (Just x, Nothing)  -> upperL x
                    }
  where
  upperL x = case x of
               Inf   -> Just Inf
               Nat 0 -> Just (Nat 0)
               Nat 1 -> Just (Nat 1)
               _     -> Nothing

  upperR x = case x of
               Inf   -> Just Inf
               Nat 0 -> Just (Nat 1)
               _     -> Nothing

iMin :: Interval -> Interval -> Interval
iMin i j = Interval { iLower = nMin (iLower i) (iLower j)
                    , iUpper = case (iUpper i, iUpper j) of
                                 (Nothing, Nothing)   -> Nothing
                                 (Just x, Just y)     -> Just (nMin x y)
                                 (Nothing, Just Inf)  -> Nothing
                                 (Nothing, Just y)    -> Just y
                                 (Just Inf, Nothing)  -> Nothing
                                 (Just x, Nothing)    -> Just x
                    }

iMax :: Interval -> Interval -> Interval
iMax i j = Interval { iLower = nMax (iLower i) (iLower j)
                    , iUpper = case (iUpper i, iUpper j) of
                                 (Nothing, Nothing)   -> Nothing
                                 (Just x, Just y)     -> Just (nMax x y)
                                 (Nothing, Just Inf)  -> Just Inf
                                 (Nothing, Just _)    -> Nothing
                                 (Just Inf, Nothing)  -> Just Inf
                                 (Just _, Nothing)    -> Nothing
                    }

iSub :: Interval -> Interval -> Interval
iSub i j = Interval { iLower = lower, iUpper = upper }
  where
  lower = case iUpper j of
            Nothing -> Nat 0
            Just x  -> case nSub (iLower i) x of
                         Nothing -> Nat 0
                         Just y  -> y


  upper = case iUpper i of
            Nothing -> Nothing
            Just x  -> case nSub x (iLower j) of
                         Nothing -> Just Inf {- malformed subtraction -}
                         Just y  -> Just y


iDiv :: Interval -> Interval -> Interval
iDiv i j = Interval { iLower = lower, iUpper = upper }
  where
  lower = case iUpper j of
            Nothing -> Nat 0
            Just x  -> case nDiv (iLower i) x of
                         Nothing -> Nat 0   -- malformed division
                         Just y  -> y

  upper = case iUpper i of
            Nothing -> Nothing
            Just x  -> case nDiv x (nMax (iLower i) (Nat 1)) of
                         Nothing -> Just Inf
                         Just y  -> Just y


iMod :: Interval -> Interval -> Interval
iMod _ j = Interval { iLower = Nat 0, iUpper = upper }
  where
  upper = case iUpper j of
            Just (Nat n) | n > 0 -> Just (Nat (n - 1))
            _                    -> Nothing


iWidth :: Interval -> Interval
iWidth i = Interval { iLower = nWidth (iLower i)
                    , iUpper = case iUpper i of
                                 Nothing -> Nothing
                                 Just n  -> Just (nWidth n)
                    }

iLenFromThen :: Interval -> Interval -> Interval -> Interval
iLenFromThen i j w
  | Just x <- iIsExact i, Just y <- iIsExact j, Just z <- iIsExact w
  , Just r <- nLenFromThen x y z = iConst r
  | otherwise =
      case iUpper w of
        Just (Nat n) ->
                    Interval { iLower = Nat 0, iUpper = Just (Nat (2^n - 1)) }
        _ -> iAnyFin


iLenFromThenTo :: Interval -> Interval -> Interval -> Interval
iLenFromThenTo i j k
  | Just x <- iIsExact i, Just y <- iIsExact j, Just z <- iIsExact k
  , Just r <- nLenFromThenTo x y z = iConst r
  | otherwise = iAnyFin





