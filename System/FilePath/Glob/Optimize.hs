-- File created: 2008-10-10 13:29:17

module System.FilePath.Glob.Optimize (optimize, simplify) where

import Data.List       (find, sortBy)
import System.FilePath (isPathSeparator)

import System.FilePath.Glob.Base
import System.FilePath.Glob.Utils
   ( isLeft, fromLeft
   , increasingSeq
   , addToRange, overlap)

-- |Simplifies a 'Pattern' object: removes redundant @\"./\"@, for instance.
-- The resulting 'Pattern' matches the exact same input as the original one,
-- with some differences:
--
-- * 'globDir'\'s output will differ: globbing for @\"./*\"@ gives @\"./foo\"@,
--   but after simplification this'll be only @\"foo\"@.
--
--   TODO: not sure if this is actually the case currently: ./foo probably does
--   but what about foo///bar
--
-- * 'show'ing the simplified 'Pattern' will obviously not give the original.
--
-- * The simplified 'Pattern' is a bit faster to match with and uses less
--   memory, since some redundant data is removed.
--
-- For the last of the above reasons, if you're performance-conscious and not
-- using 'globDir', you should always 'simplify' after calling 'compile'.
simplify :: Pattern -> Pattern
simplify = liftP (go . pre)
 where
   -- ./ at beginning -> nothing (any number of /'s)
   pre (ExtSeparator:PathSeparator:xs) = pre (dropWhile isSlash xs)
   pre                             xs  = xs

   go [] = []

   -- /./ -> /
   go (PathSeparator:ExtSeparator:xs@(PathSeparator:_)) = go xs

   go (x:xs) =
      case find ($ x) compressors of
           Just c  -> let (compressed,ys) = span c xs
                       in if null compressed
                             then x : go ys
                             else go (x : ys)
           Nothing -> x : go xs

   compressors = [isStar, isSlash, isStarSlash]

   isStar      AnyNonPathSeparator = True
   isStar      _                   = False
   isSlash     PathSeparator       = True
   isSlash     _                   = False
   isStarSlash AnyDirectory        = True
   isStarSlash _                   = False

optimize :: Pattern -> Pattern
optimize = liftP (fin . go)
 where
   fin [] = []

   -- [.] are ExtSeparators everywhere except at the beginning
   fin (x:Literal '.':xs) = fin (x:ExtSeparator:xs)

   -- Literals to LongLiteral
   -- Has to be done here: we can't backtrack in go, but some cases might
   -- result in consecutive Literals being generated.
   -- E.g. "a[b]".
   fin (x:y:xs) | isLiteral x && isLiteral y =
      let (ls,rest) = span isLiteral xs
       in fin $ LongLiteral (length ls + 2)
                      (foldr (\(Literal a) -> (a:)) [] (x:y:ls))
                : rest

   -- concatenate LongLiterals
   -- Has to be done here because LongLiterals are generated above.
   --
   -- So one could say that we have one pass (go) which flattens everything as
   -- much as it can and one pass (fin) which concatenates what it can.
   fin (LongLiteral l1 s1 : LongLiteral l2 s2 : xs) =
      fin $ LongLiteral (l1+l2) (s1++s2) : xs

   fin (LongLiteral l s : Literal c : xs) =
      fin $ LongLiteral (l+1) (s++[c]) : xs

   fin (x:xs) = x : fin xs

   go [] = []
   go (x@(CharRange _ _) : xs) =
      case optimizeCharRange x of
           x'@(CharRange _ _) -> x' : go xs
           x'                 -> go (x':xs)

   -- <a-a> -> a
   go (OpenRange (Just a) (Just b):xs)
      | a == b = LongLiteral (length a) a : go xs

   -- <a-b> -> [a-b]
   -- a and b are guaranteed non-null
   go (OpenRange (Just [a]) (Just [b]):xs)
      | b > a = go $ CharRange True [Right (a,b)] : xs

   go (x:xs) =
      x : if isAnyNumber x
             then go (dropWhile isAnyNumber xs)
             else go xs

   isLiteral   (Literal _)                 = True
   isLiteral   _                           = False
   isAnyNumber (OpenRange Nothing Nothing) = True
   isAnyNumber _                           = False

optimizeCharRange :: Token -> Token
optimizeCharRange (CharRange b_ rs) = fin b_ . go . sortCharRange $ rs
 where
   -- [/] is interesting, it actually matches nothing at all
   -- [.] can be Literalized though, just don't make it into an ExtSeparator so
   --     that it doesn't match a leading dot
   fin True [Left  c] | not (isPathSeparator c) = Literal c
   fin True [Right r] | r == (minBound,maxBound) = NonPathSeparator
   fin b x = CharRange b x

   go [] = []

   go (x@(Left c) : xs) =
      case xs of
           [] -> [x]
           y@(Left d) : ys
              -- [aaaaa] -> [a]
              | c == d      -> go$ Left c : ys
              | d == succ c ->
                 let (ls,rest)        = span isLeft xs -- start from y
                     (catable,others) = increasingSeq (map fromLeft ls)
                     range            = (c, head catable)

                  in -- three (or more) Lefts make a Right
                     if null catable || null (tail catable)
                        then x : y : go ys
                        -- [abcd] -> [a-d]
                        else go$ Right range : map Left others ++ rest

              | otherwise -> x : go xs

           Right r : ys ->
              case addToRange r c of
                   -- [da-c] -> [a-d]
                   Just r' -> go$ Right r' : ys
                   Nothing -> x : go xs

   go (x@(Right r) : xs) =
      case xs of
           [] -> [x]
           Left c : ys ->
              case addToRange r c of
                   -- [a-cd] -> [a-d]
                   Just r' -> go$ Right r' : ys
                   Nothing -> x : go xs

           Right r' : ys ->
              case overlap r r' of
                   -- [a-cb-d] -> [a-d]
                   Just o  -> go$ Right o : ys
                   Nothing -> x : go xs
optimizeCharRange _ = error "Glob.optimizeCharRange :: internal error"

sortCharRange :: [Either Char (Char,Char)] -> [Either Char (Char,Char)]
sortCharRange = sortBy cmp
 where
   cmp (Left   a)    (Left   b)    = compare a b
   cmp (Left   a)    (Right (b,_)) = compare a b
   cmp (Right (a,_)) (Left   b)    = compare a b
   cmp (Right (a,_)) (Right (b,_)) = compare a b
