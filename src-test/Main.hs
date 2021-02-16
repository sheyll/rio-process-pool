module Main (main) where

import qualified BrokerTest
import qualified PoolTest
import System.Environment (setEnv)
import Test.Tasty
  ( TestTree,
    defaultIngredients,
    defaultMainWithIngredients,
    testGroup,
  )
import Test.Tasty.Runners.Html (htmlRunner)
import qualified UnlimitedMessageBoxTest

main :: IO ()
main =
  do
    setEnv "TASTY_NUM_THREADS" "1"
    defaultMainWithIngredients (htmlRunner : defaultIngredients) test

test :: TestTree
test =
  testGroup
    "Tests"
    [ BrokerTest.test,
      PoolTest.test
    ]
