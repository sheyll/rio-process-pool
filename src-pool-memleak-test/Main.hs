module Main (main) where

import RIO
import RIO.Partial
import RIO.ProcessPool
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  runSimpleApp $ do
    let (rounds, repetitions, nWorkMessages) =
          case args of
            [n', r', w'] -> (read n', read r', read w')
            [n', r'] -> (read n', read r', 10)
            [n'] -> (read n', 1, 10)
            _ -> (1, 1, 10)
    logInfo
      ( "Benchmark: Running "
          <> display repetitions
          <> " times a benchmark with "
          <> display rounds
          <> " active processes, each processing "
          <> display nWorkMessages
          <> " work messages."
      )
    bench repetitions rounds nWorkMessages

newtype Key = Key Int deriving newtype (Eq, Ord, Show, Display)

data Msg = Start | Work | SyncWork (MVar Int) | Stop

{-# NOINLINE bench #-}

-- | Start @bSize@ clients that work 10000 work units.
bench :: Int -> Int -> Int -> RIO SimpleApp ()
bench repetitions bSize nWorkMessages = do
  resultBox <- newMessageBox BlockingUnlimited
  resultBoxIn <- newInput resultBox
  -- start a pool
  x <-
    spawnPool
      BlockingUnlimited
      BlockingUnlimited
      (MkPoolWorkerCallback (enterWorkLoop resultBoxIn))
  case x of
    Left err ->
      logError ("Error: " <> display err)
    Right pool -> do
      forM_ [1 .. repetitions] $ \ !rep -> do
        logInfo
          ( "================= BEGIN (rep: "
              <> display rep
              <> ") ================"
          )
        do
          let groupSize = 1000
          mapConcurrently_
            (traverse_ (sendWork nWorkMessages (poolInput pool) . Key))
            ( [groupSize * ((bSize - 1) `div` groupSize) .. bSize - 1] :
                [ [groupSize * x0 .. groupSize * x0 + (groupSize - 1)]
                  | x0 <- [0 .. ((bSize - 1) `div` groupSize) - 1]
                ]
            )

          logInfo "Waiting for results"
          printResults bSize resultBox

        logInfo ("================= DONE (rep: " <> display rep <> ") ================")
      cancel (poolAsync pool)

{-# NOINLINE printResults #-}
printResults ::
  (IsMessageBox box) =>
  Int ->
  box (Key, Int) ->
  RIO SimpleApp ()
printResults bSize box
  | bSize <= 0 = return ()
  | otherwise =
    receive box
      >>= maybe
        (logInfo "done!")
        ( \(Key k, v) -> do
            when
              (k `mod` 1000 == 0)
              (logInfo ("Result of " <> display k <> " is: " <> display v))
            printResults (bSize - 1) box
        )

{-# NOINLINE sendWork #-}
sendWork ::
  (IsInput input) =>
  Int ->
  input (Multiplexed Key (Maybe Msg)) ->
  Key ->
  RIO SimpleApp ()
sendWork nWorkMessages poolBoxIn k@(Key x) = do
  when
    (x `mod` 1000 == 0)
    (logInfo ("Delivering Messages for: " <> display k))
  void $ deliver poolBoxIn (Initialize k (Just (Just Start)))
  when
    (x `mod` 1000 == 0)
    (logInfo ("Delivering Sync Work Messages for: " <> display k))
  do
    resRef <- newEmptyMVar
    replicateM_
      nWorkMessages
      ( do
          deliver_ poolBoxIn (Dispatch k (Just (SyncWork resRef)))
          res <- takeMVar resRef
          when
            (x `mod` 1000 == 0 && res `mod` 1000 == 0)
            ( logInfo
                ( "Current counter of: "
                    <> display k
                    <> " is: "
                    <> display res
                )
            )
      )
  when
    (x `mod` 1000 == 0)
    (logInfo ("Delivering Async Work Messages for: " <> display k))
  replicateM_
    nWorkMessages
    ( deliver_ poolBoxIn (Dispatch k (Just Work))
    )

  --  replicateM_ nWorkMessages (deliver poolBoxIn (Dispatch k (Just Work)))
  void $ deliver poolBoxIn (Dispatch k (Just Stop))
  when
    (x `mod` 1000 == 0)
    (logInfo ("Delivered all Messages for: " <> display k))

{-# NOINLINE enterWorkLoop #-}
enterWorkLoop ::
  (IsMessageBox box, IsInput input) =>
  input (Key, Int) ->
  Key ->
  box Msg ->
  RIO SimpleApp ()
enterWorkLoop resultBoxIn (Key k) box =
  tryAny (receive box)
    >>= ( \case
            Left ex ->
              logError
                ( "Receive threw exception for worker: "
                    <> display k
                    <> " "
                    <> display ex
                )
            Right Nothing ->
              logError ("Receive failed for worker: " <> display k)
            Right (Just Start) -> do
              when
                (k `mod` 1000 == 0)
                (logInfo ("Started: " <> display k))
              workLoop 0
            Right (Just Work) ->
              logWarn ("Got unexpected Work: " <> display k)
            Right (Just (SyncWork ref)) -> do
              logWarn ("Got unexpected SyncWork: " <> display k)
              putMVar ref 0
            Right (Just Stop) ->
              logWarn ("Got unexpected Stop: " <> display k)
        )
  where
    workLoop !counter =
      tryAny (receive box)
        >>= \case
          Left ex ->
            logError
              ( "Receive threw exception for worker: "
                  <> display k
                  <> " "
                  <> display ex
              )
          Right Nothing ->
            logWarn ("Receive failed for worker: " <> display k)
          Right (Just Start) -> do
            logWarn ("Re-Start: " <> display k)
            workLoop 0
          Right (Just Work) ->
            workLoop (counter + 1)
          Right (Just (SyncWork ref)) -> do
            putMVar ref counter
            -- timeout 5000000 (putMVar ref counter)
            --   >>= maybe
            --     (liftIO (putStrLn "SyncWork timeout putting the result"))
            --     (const (return ()))
            workLoop (counter + 1)
          Right (Just Stop) -> do
            void (deliver resultBoxIn (Key k, counter))
            when
              (k `mod` 1000 == 0)
              (logInfo ("Stopped: " <> display k))
