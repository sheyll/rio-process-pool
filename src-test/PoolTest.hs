module PoolTest (test) where

import qualified Data.Atomics.Counter as Atomic
import RIO
import RIO.ProcessPool
import Test.Tasty
import Test.Tasty.HUnit
import Utils

test :: TestTree
test =
  let expectedException = stringException "expected exception"
   in testGroup
        "Pool"
        [ testGroup
            "empty pool"
            [ testCase
                "when broker creation throws an exception, the process doesn't\
                \ block and returns an error"
                $ runTestApp $ do
                  let badPoolBox =
                        MkMockBoxInit
                          ( return
                              ( MkMockBox
                                  (throwIO expectedException)
                                  (error "unexpected invokation: receive")
                                  (error "unexpected invokation: tryReceive")
                              )
                          )
                          Nothing
                  e <-
                    fromLeft (error "error expected")
                      <$> spawnPool @Int @() @(MockBoxInit (MockBox NoOpInput))
                        badPoolBox
                        BlockingUnlimited
                        MkPoolWorkerCallback
                          { runPoolWorkerCallback = const (const (return ()))
                          }
                  liftIO $
                    assertEqual "error expected" (show expectedException) (show e),
              testCase
                "when receiving from the pool input throws an exception,\
                \ the pool exits with that exception"
                $ runTestApp $ do
                  let badPoolBox =
                        MkMockBoxInit
                          ( return
                              ( MkMockBox
                                  ( return
                                      (OnDeliver (error "unexpected invokation: OnDeliver"))
                                  )
                                  (throwIO expectedException)
                                  (error "unexpected invokation: tryReceive")
                              )
                          )
                          Nothing
                  pool <-
                    fromRight (error "failed to start pool")
                      <$> spawnPool @Int @()
                        badPoolBox
                        BlockingUnlimited
                        MkPoolWorkerCallback
                          { runPoolWorkerCallback = const (const (return ()))
                          }
                  e <-
                    fromLeft (error "error expected")
                      <$> waitCatch (poolAsync pool)
                  liftIO $
                    assertEqual "error expected" (show expectedException) (show e),
              testCase
                "when receiving from the pool input throws an exception,\
                \ the pool exits with that exception"
                $ runTestApp $ do
                  let badPoolBox =
                        MkMockBoxInit
                          ( return
                              ( MkMockBox
                                  ( return
                                      (OnDeliver (error "unexpected invokation: OnDeliver"))
                                  )
                                  (throwIO expectedException)
                                  (error "unexpected invokation: tryReceive")
                              )
                          )
                          Nothing
                  pool <-
                    fromRight (error "failed to start pool")
                      <$> spawnPool @Int @()
                        badPoolBox
                        BlockingUnlimited
                        MkPoolWorkerCallback
                          { runPoolWorkerCallback = const (const (return ()))
                          }
                  e <-
                    fromLeft (error "error expected")
                      <$> waitCatch (poolAsync pool)
                  liftIO $
                    assertEqual
                      "error expected"
                      (show expectedException)
                      (show e)
            ],
          testGroup
            "non-empty pool"
            [ testCase
                "when delivering an Initialize,\
                \ the worker callback is executed in a new process"
                $ runTestApp $ do
                  workerIdRef <- newEmptyMVar
                  let cb = MkPoolWorkerCallback $ \_k _box ->
                        myThreadId >>= putMVar workerIdRef
                  pool <-
                    either (error . show) id
                      <$> spawnPool @Int BlockingUnlimited BlockingUnlimited cb
                  deliver_ (poolInput pool) (Initialize 777 (Just (Just ())))
                  workerId <- takeMVar workerIdRef
                  cancel (poolAsync pool)
                  liftIO $
                    assertBool
                      "worker and broker threadIds must be different"
                      (asyncThreadId (poolAsync pool) /= workerId),
              testCase
                "when delivering an Initialize and the worker message box creation fails,\
                \ the worker will be cleaned up and not be in the pool"
                $ runTestApp $ do
                  workerIdRef <- newEmptyMVar
                  let badWorkerBox =
                        MkMockBoxInit
                          ( do
                              myThreadId >>= putMVar workerIdRef
                              throwIO expectedException
                          )
                          Nothing
                  let cb = MkPoolWorkerCallback $ \_k _box ->
                        error "unexpected invokation: callback"
                  pool <-
                    fromRight (error "failed to start pool")
                      <$> spawnPool @Int @_ @_ @(MockBoxInit (MockBox NoOpInput))
                        BlockingUnlimited
                        badWorkerBox
                        cb
                  deliver_ (poolInput pool) (Initialize 777 (Just (Just ())))
                  workerId1 <- takeMVar workerIdRef
                  deliver_ (poolInput pool) (Initialize 777 (Just (Just ())))
                  workerId2 <- takeMVar workerIdRef
                  cancel (poolAsync pool)
                  liftIO $
                    assertBool
                      "the broken worker must be removed from the pool"
                      (workerId1 /= workerId2),
              testCase
                "when delivering an Initialize and the worker message box input creation fails,\
                \ the worker will be cleaned up and not be in the pool"
                $ runTestApp $ do
                  workerIdRef <- newEmptyMVar
                  let badWorkerBox =
                        MkMockBoxInit
                          ( return
                              ( MkMockBox
                                  ( do
                                      myThreadId >>= putMVar workerIdRef
                                      throwIO expectedException
                                  )
                                  (error "unexpected invokation: receive")
                                  (error "unexpected invokation: tryReceive")
                              )
                          )
                          Nothing
                  let cb = MkPoolWorkerCallback $ \_k _box ->
                        error "unexpected invokation: callback"
                  pool <-
                    fromRight (error "failed to start pool")
                      <$> spawnPool @Int @_ @_ @(MockBoxInit (MockBox NoOpInput))
                        BlockingUnlimited
                        badWorkerBox
                        cb
                  deliver_ (poolInput pool) (Initialize 777 (Just (Just ())))
                  workerId1 <- takeMVar workerIdRef
                  deliver_ (poolInput pool) (Initialize 777 (Just (Just ())))
                  workerId2 <- takeMVar workerIdRef
                  cancel (poolAsync pool)
                  liftIO $
                    assertBool
                      "the broken worker must be removed from the pool"
                      (workerId1 /= workerId2),
              testCase
                "when delivering an 'Initialize (Just Nothing)',\
                \ the worker will be cleaned up and not be in the pool"
                $ runTestApp $ do
                  counter <- liftIO $ Atomic.newCounter 0
                  let cb = MkPoolWorkerCallback $ \_k box -> do
                        liftIO $ Atomic.incrCounter_ 1 counter
                        receive box
                          >>= maybe
                            (return ())
                            (either id (`putMVar` ()))
                  pool <-
                    fromRight (error "failed to start pool")
                      <$> spawnPool @Int
                        BlockingUnlimited
                        BlockingUnlimited
                        cb
                  deliver_ (poolInput pool) (Initialize 777 (Just Nothing))
                  threadDelay 1000
                  -- must not happen:
                  failed <- newEmptyMVar
                  deliver_ (poolInput pool) (Dispatch 777 (Just (Left (putMVar failed ()))))
                  timeout 10000 (takeMVar failed)
                    >>= liftIO
                      . assertBool "the worker should not be running"
                      . isNothing
                  deliver_ (poolInput pool) (Initialize 777 Nothing)
                  done <- newEmptyMVar
                  deliver_ (poolInput pool) (Dispatch 777 (Just (Right done)))
                  takeMVar done
                  liftIO
                    ( Atomic.readCounter counter
                        >>= assertEqual "invalid number of pool worker callback invokations" 2
                    )
                  cancel (poolAsync pool),
              testCase
                "when several workers are initialized with different keys,\
                \ all are created and available in the pool."
                $ runTestApp $ do
                  startedRef <- newEmptyMVar
                  let cb = MkPoolWorkerCallback $ \k box -> do
                        putMVar startedRef k
                        fix $ \again -> do
                          m <- receive box
                          case m of
                            Nothing -> return ()
                            Just ref -> do
                              putMVar ref k
                              again

                  pool <-
                    fromRight (error "failed to start pool")
                      <$> spawnPool @Int
                        BlockingUnlimited
                        BlockingUnlimited
                        cb

                  liftIO $ do
                    deliver_ (poolInput pool) (Initialize 0 Nothing)
                    takeMVar startedRef >>= assertEqual "wrong startedRef value" 0
                    deliver_ (poolInput pool) (Initialize 1 Nothing)
                    takeMVar startedRef >>= assertEqual "wrong startedRef value" 1
                    deliver_ (poolInput pool) (Initialize 2 Nothing)
                    takeMVar startedRef >>= assertEqual "wrong startedRef value" 2
                    deliver_ (poolInput pool) (Initialize 3 Nothing)
                    takeMVar startedRef >>= assertEqual "wrong startedRef value" 3

                    workRef <- newEmptyMVar
                    deliver_ (poolInput pool) (Dispatch 0 (Just workRef))
                    takeMVar workRef >>= assertEqual "wrong workRef value" 0
                    deliver_ (poolInput pool) (Dispatch 1 (Just workRef))
                    takeMVar workRef >>= assertEqual "wrong workRef value" 1
                    deliver_ (poolInput pool) (Dispatch 2 (Just workRef))
                    takeMVar workRef >>= assertEqual "wrong workRef value" 2
                    deliver_ (poolInput pool) (Dispatch 3 (Just workRef))
                    takeMVar workRef >>= assertEqual "wrong workRef value" 3

                    cancel (poolAsync pool),
              testCase
                "when 'Dispatch k (Just x)' is delivered, and a worker k exists,\
                \ the worker will receive the message x, otherwise it will silently be dropped."
                $ runTestApp $ do
                  startedRef <- newEmptyMVar
                  let cb = MkPoolWorkerCallback $ \k box -> do
                        putMVar startedRef k
                        fix $ \again -> do
                          m <- receive box
                          case m of
                            Nothing -> return ()
                            Just ref -> do
                              putMVar ref k
                              again

                  pool <-
                    fromRight (error "failed to start pool")
                      <$> spawnPool @Int
                        BlockingUnlimited
                        BlockingUnlimited
                        cb
                  liftIO $ do
                    deliver_ (poolInput pool) (Initialize 0 Nothing)
                    takeMVar startedRef >>= assertEqual "wrong startedRef value" 0
                    deliver_ (poolInput pool) (Initialize 1 Nothing)
                    takeMVar startedRef >>= assertEqual "wrong startedRef value" 1

                    workRef <- newEmptyMVar
                    deliver_ (poolInput pool) (Dispatch 0 (Just workRef))
                    takeMVar workRef >>= assertEqual "wrong workRef value" 0

                    deliver_ (poolInput pool) (Dispatch 666 (Just workRef))
                    timeout 10000 (takeMVar workRef)
                      >>= assertEqual "wrong workRef value" Nothing

                    cancel (poolAsync pool),
              testCase
                "when Dispatch k Nothing is delivered, and a worker k exists,\
                \ the worker will be cleaned up and removed from the pool"
                $ runTestApp $ do
                  startedRef <- newEmptyMVar
                  let cb = MkPoolWorkerCallback $ \k box -> do
                        putMVar startedRef k
                        fix $ \again -> do
                          m <- receive box
                          case m of
                            Nothing -> return ()
                            Just ref -> do
                              putMVar ref k
                              again

                  pool <-
                    fromRight (error "failed to start pool")
                      <$> spawnPool @Int
                        BlockingUnlimited
                        BlockingUnlimited
                        cb
                  liftIO $ do
                    deliver_ (poolInput pool) (Initialize 0 Nothing)
                    takeMVar startedRef >>= assertEqual "wrong startedRef value" 0
                    deliver_ (poolInput pool) (Initialize 1 Nothing)
                    takeMVar startedRef >>= assertEqual "wrong startedRef value" 1

                    workRef <- newEmptyMVar
                    deliver_ (poolInput pool) (Dispatch 0 (Just workRef))
                    takeMVar workRef >>= assertEqual "wrong workRef value" 0

                    deliver_ (poolInput pool) (Dispatch 1 Nothing)

                    deliver_ (poolInput pool) (Dispatch 1 (Just workRef))
                    timeout 10000 (takeMVar workRef)
                      >>= assertEqual "wrong workRef value" Nothing

                    deliver_ (poolInput pool) (Dispatch 0 (Just workRef))
                    takeMVar workRef >>= assertEqual "wrong workRef value" 0

                    cancel (poolAsync pool),
              testCase
                "when 'deliver' to a worker message box returns False,\
                \ the worker is removed (and cancelled)"
                $ runTestApp $ do
                  startedRef <- newEmptyMVar
                  let cb = MkPoolWorkerCallback $ \k box -> do
                        putMVar startedRef k
                        fix $ \again -> do
                          m <- receive box
                          case m of
                            Nothing -> return ()
                            Just (Left ref) -> do
                              putMVar ref k
                              again
                            Just (Right ()) -> do
                              threadDelay 100000000

                  pool <-
                    fromRight (error "failed to start pool")
                      <$> spawnPool @Int
                        BlockingUnlimited
                        (NonBlockingBoxLimit MessageLimit_2)
                        cb

                  liftIO $ do
                    deliver_ (poolInput pool) (Initialize 0 Nothing)
                    takeMVar startedRef >>= assertEqual "wrong startedRef value" 0

                    deliver_ (poolInput pool) (Initialize 1 Nothing)
                    takeMVar startedRef >>= assertEqual "wrong startedRef value" 1

                    workRef <- newEmptyMVar

                    deliver_ (poolInput pool) (Dispatch 0 (Just (Left workRef)))
                    takeMVar workRef >>= assertEqual "wrong workRef value" 0

                    -- Now overflow the input by first sending a Right message and then
                    -- so many messages, that the message limit will cause 'deliver'
                    -- to return 'False':
                    replicateM_
                      16
                      (deliver_ (poolInput pool) (Dispatch 0 (Just (Right ()))))

                    -- Now the process should be dead:
                    deliver_ (poolInput pool) (Dispatch 0 (Just (Left workRef)))
                    timeout 10000 (takeMVar workRef)
                      >>= assertEqual "wrong workRef value" Nothing

                    -- ... while the other process should be alive:
                    deliver_ (poolInput pool) (Dispatch 1 (Just (Left workRef)))
                    takeMVar workRef >>= assertEqual "wrong workRef value" 1

                    cancel (poolAsync pool)
            ]
        ]
