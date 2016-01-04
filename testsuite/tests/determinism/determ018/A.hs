{-# LANGUAGE ApplicativeDo #-}
module Test where

-- Test we can also infer the Applicative version of the type
test2 f = do
  x <- f 3
  y <- f 4
  return (x + y)

