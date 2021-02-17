module BrokerTest (test) where

import Control.Exception (throw)
import Data.List (sort)
import RIO
import RIO.ProcessPool.Broker
import Test.Tasty
import Test.Tasty.HUnit
import UnliftIO.MessageBox.Class
import UnliftIO.MessageBox.Unlimited
import Utils
  ( MockBox (MkMockBox),
    MockBoxInit (MkMockBoxInit),
    NoOpArg (..),
    NoOpBox,
    NoOpInput (..),
    runTestApp,
  )

noBrokerConfig :: BrokerConfig k w' w a m
noBrokerConfig =
  MkBrokerConfig
    { demultiplexer = const $ error "unexpected invokation: demultiplexer",
      messageDispatcher = const $ error "unexpected invokation: messageDispatcher",
      resourceCreator = const $ error "unexpected invokation: resourceCreator",
      resourceCleaner = const $ error "unexpected invokation: resourceCleaner"
    }

expectedException :: StringException
expectedException = stringException "Test"

test :: HasCallStack => TestTree
test =
  testGroup
    "BrokerTests"
    [ testCase
        "the show instance of BrokerResult makes sense"
        (assertEqual "" "MkBrokerResult" (show MkBrokerResult)),
      testCase
        "when a broker message box creation throws an exception, \
        \ the exception is returned in a Left..."
        $ do
          Just (Left a) <-
            runTestApp $
              timeout 1000000 $
                spawnBroker @_ @Int @() @() @NoOpArg
                  ( MkMockBoxInit @NoOpBox
                      (throwIO expectedException)
                      Nothing
                  )
                  noBrokerConfig
          assertEqual
            "exception expected"
            (show (SomeException expectedException))
            (show a),
      testCase
        "when a broker message box input creation throws an exception,\
        \ the exception is returned in a Left..."
        $ do
          Just (Left a) <-
            runTestApp $
              timeout 1000000 $
                spawnBroker @_ @Int @() @() @NoOpArg
                  ( MkMockBoxInit
                      ( return
                          ( MkMockBox @NoOpInput
                              (throwIO expectedException)
                              (error "unexpected invokation: receive")
                              (error "unexpected invokation: tryReceive")
                          )
                      )
                      Nothing
                  )
                  noBrokerConfig
          assertEqual
            "exception expected"
            (show (SomeException expectedException))
            (show a),
      testCase
        "when the receive function throws a synchronous exception,\
        \ then waiting on the broker will return the exception"
        $ do
          Just (Right (_, a)) <-
            runTestApp $
              timeout 1000000 $
                spawnBroker @_ @Int @() @() @NoOpArg
                  ( MkMockBoxInit
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
                  )
                  noBrokerConfig
          r <- runTestApp $ waitCatch a
          assertEqual
            "exception expected"
            ( show
                ( Left (SomeException expectedException) ::
                    Either SomeException ()
                )
            )
            (show r),
      testCase
        "when evaluation of an incoming message causes an exception,\
        \ then the broker ignores the error and continues"
        $ runTestApp $ do
          spRes <-
            spawnBroker
              ( MkMockBoxInit
                  ( return
                      ( MkMockBox
                          ( return
                              (OnDeliver (const (pure True)))
                          )
                          (return (Just (throw expectedException)))
                          (error "unexpected invokation: tryReceive")
                      )
                  )
                  Nothing
              )
              ( MkBrokerConfig
                  { demultiplexer = Dispatch (777 :: Int),
                    messageDispatcher =
                      const (error "unexpected invokation: messageDispatcher"),
                    resourceCreator =
                      const (error "unexpected invokation: resourceCreator"),
                    resourceCleaner =
                      const (error "unexpected invokation: resourceCleaner")
                  }
              )
          case spRes of
            Left err -> error (show err)
            Right (brokerIn, brokerA) -> do
              deliver_ brokerIn ()
              cancel brokerA
              r <- waitCatch brokerA
              liftIO $
                assertEqual
                  "exception expected"
                  "Left AsyncCancelled"
                  (show r),
      testCase
        "when evaluation of the first incoming message causes an async\
        \ exception, then the broker exits with that exception"
        $ runTestApp $ do
          spawnBroker
            ( MkMockBoxInit
                ( return
                    ( MkMockBox
                        ( return
                            (OnDeliver (const (pure True)))
                        )
                        (return (Just (throw (AsyncExceptionWrapper expectedException))))
                        (error "unexpected invokation: tryReceive")
                    )
                )
                Nothing
            )
            ( MkBrokerConfig
                { demultiplexer = Dispatch (777 :: Int),
                  messageDispatcher =
                    const (error "unexpected invokation: messageDispatcher"),
                  resourceCreator =
                    const (error "unexpected invokation: resourceCreator"),
                  resourceCleaner =
                    const (error "unexpected invokation: resourceCleaner")
                }
            )
            >>= \case
              Left err -> error (show err)
              Right (brokerIn, brokerA) -> do
                deliver_ brokerIn ()
                r <- waitCatch brokerA
                liftIO $
                  assertEqual
                    "exception expected"
                    ( show
                        ( Left (SomeException (AsyncExceptionWrapper expectedException)) ::
                            Either SomeException ()
                        )
                    )
                    (show r),
      testCase
        "when a broker is cancelled while waiting for the first message,\
        \ then the broker exits with AsyncCancelled"
        $ runTestApp $ do
          goOn <- newEmptyMVar
          spawnBroker @_ @Int @() @()
            ( MkMockBoxInit
                ( return
                    ( MkMockBox
                        ( return
                            (OnDeliver (const (pure True)))
                        )
                        ( do
                            putMVar goOn ()
                            threadDelay 1_000_000
                            return (Just (error "unexpected evaluation"))
                        )
                        (error "unexpected invokation: tryReceive")
                    )
                )
                Nothing
            )
            noBrokerConfig
            >>= \case
              Left err -> error (show err)
              Right (_brokerIn, brokerA) -> do
                takeMVar goOn
                cancel brokerA
                r <- waitCatch brokerA
                liftIO $
                  assertEqual
                    "exception expected"
                    "Left AsyncCancelled"
                    (show r),
      testCase
        "when a broker receives a message for a missing resource,\
        \ it silently drops the message"
        $ runTestApp $ do
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer = Dispatch (777 :: Int),
                    messageDispatcher =
                      const (error "unexpected invokation: messageDispatcher"),
                    resourceCreator =
                      const (error "unexpected invokation: resourceCreator"),
                    resourceCleaner =
                      const (error "unexpected invokation: resourceCleaner")
                  }
          spawnBroker BlockingUnlimited brokerCfg
            >>= \case
              Left err -> error (show err)
              Right (brokerIn, brokerA) -> do
                deliver_ brokerIn ()
                cancel brokerA
                r <- waitCatch brokerA
                liftIO $
                  assertEqual
                    "success expected"
                    "Left AsyncCancelled"
                    (show r),
      testCase
        "when an empty broker receives a start message without payload\
        \ and the creator callback throws an exception,\
        \ a normal message for that key will be ignored,\
        \ no cleanup is performed, and the broker lives on"
        $ runTestApp $ do
          workerInitialized <- newEmptyMVar
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer =
                      \m ->
                        if m
                          then Initialize (777 :: Int) Nothing
                          else Dispatch (777 :: Int) (),
                    messageDispatcher =
                      const (error "unexpected invokation: messageDispatcher"),
                    resourceCreator = \_k _mw -> do
                      putMVar workerInitialized ()
                      throwIO expectedException,
                    resourceCleaner =
                      const (error "unexpected invokation: resourceCleaner")
                  }
          spawnBroker BlockingUnlimited brokerCfg
            >>= \case
              Left err -> error (show err)
              Right (brokerIn, brokerA) -> do
                deliver_ brokerIn True
                timeout 1000000 (takeMVar workerInitialized)
                  >>= liftIO
                    . assertEqual
                      "resourceCreator wasn't executed"
                      (Just ())
                deliver_ brokerIn False
                cancel brokerA
                r <- waitCatch brokerA
                liftIO $
                  assertEqual
                    "exception expected"
                    "Left AsyncCancelled"
                    (show r),
      testCase
        "when an empty broker receives a start message with a payload\
        \ and when the MessageHandler callback throws an exception when\
        \ applied to that payload, cleanup is performed once, and\
        \ incoming messages for that key will be ignored,\
        \ and the broker lives on"
        $ runTestApp $ do
          cleanupCalls <- newEmptyMVar
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer =
                      \isInitPayload ->
                        if isInitPayload
                          then Initialize (777 :: Int) (Just True)
                          else Dispatch (777 :: Int) False,
                    messageDispatcher =
                      \_k isInitPayload _ ->
                        if isInitPayload
                          then throwIO expectedException
                          else error "unexpected invokation: messageDispatcher",
                    resourceCreator = \_k _mw -> do
                      putMVar cleanupCalls (0 :: Int)
                      return (),
                    resourceCleaner =
                      \_k () ->
                        modifyMVar
                          cleanupCalls
                          (\cnt -> return (cnt + 1, ()))
                  }
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn True
          deliver_ brokerIn False
          threadDelay 10_000
          cancel brokerA
          r <- waitCatch brokerA
          liftIO $
            assertEqual
              "exception expected"
              "Left AsyncCancelled"
              (show r)
          takeMVar cleanupCalls
            >>= liftIO . assertEqual "resourceCleaner wasn't executed" 1
          -- prevent GC of msg box input:
          deliver_ brokerIn False,
      testCase
        "when 3 resources are initialized and then the broker is cancelled,\
        \ cleanup is performed foreach resource."
        $ runTestApp $ do
          resourceCreated <- newEmptyMVar
          cleanupCalled <- newTVarIO []
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer = \k -> Initialize k (Just k),
                    messageDispatcher = \k _w _a -> do
                      putMVar resourceCreated k
                      threadDelay 10_000 -- delay here so we make sure to
                      -- be cancelled before we leave this
                      -- function.
                      -- Now if the implementation isn't
                      -- handling async exceptions well,
                      -- the resource isn't in the resource
                      -- map when cleanup is called,
                      -- and hence won't be properly
                      -- cleaned up!
                      return KeepResource,
                    resourceCreator =
                      \k _mw -> return k,
                    resourceCleaner =
                      \k a ->
                        atomically (modifyTVar cleanupCalled ((k, a) :))
                  }
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn (1 :: Int)
          deliver_ brokerIn 2
          deliver_ brokerIn 3
          takeMVar resourceCreated
            >>= liftIO . assertEqual "invalid resource created" 1
          takeMVar resourceCreated
            >>= liftIO . assertEqual "invalid resource created" 2
          takeMVar resourceCreated
            >>= liftIO . assertEqual "invalid resource created" 3
          cancel brokerA
          r <- waitCatch brokerA
          liftIO $
            assertEqual
              "exception expected"
              "Left AsyncCancelled"
              (show r)
          readTVarIO cleanupCalled
            >>= liftIO
              . assertEqual
                "resourceCleaner wasn't executed"
                [(1, 1), (2, 2), (3, 3)]
              . sort
          -- prevent GC of msg box input:
          deliver_ brokerIn 666,
      testCase
        "when 3 resources are initialized and then the broker is cancelled,\
        \ cleanup is performed foreach resource, even if exceptions are thrown\
        \ from the cleanup callbacks"
        $ runTestApp $ do
          resourceCreated <- newEmptyMVar
          cleanupCalled <- newTVarIO []
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer = \k -> Initialize k (Just k),
                    messageDispatcher = \k _w _a -> do
                      putMVar resourceCreated k
                      threadDelay 10_000 -- delay here so we make sure to
                      -- be cancelled before we leave this
                      -- function.
                      -- Now if the implementation isn't
                      -- handling async exceptions well,
                      -- the resource isn't in the resource
                      -- map when cleanup is called,
                      -- and hence won't be properly
                      -- cleaned up!
                      return KeepResource,
                    resourceCreator =
                      \k _mw -> return k,
                    resourceCleaner =
                      \k a -> do
                        atomically (modifyTVar cleanupCalled ((k, a) :))
                        throwIO expectedException
                  }
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn (1 :: Int)
          deliver_ brokerIn 2
          deliver_ brokerIn 3
          takeMVar resourceCreated
            >>= liftIO . assertEqual "invalid resource created" 1
          takeMVar resourceCreated
            >>= liftIO . assertEqual "invalid resource created" 2
          takeMVar resourceCreated
            >>= liftIO . assertEqual "invalid resource created" 3
          cancel brokerA
          r <- waitCatch brokerA
          liftIO $
            assertEqual
              "exception expected"
              "Left AsyncCancelled"
              (show r)
          readTVarIO cleanupCalled
            >>= liftIO
              . assertEqual
                "resourceCleaner wasn't executed"
                [(1, 1), (2, 2), (3, 3)]
              . sort
          -- prevent GC of msg box input:
          deliver_ brokerIn 666,
      testCase
        "when 2 resources are added and\
        \ while adding a 3rd an async exception is thrown\
        \ when handling the initial message,\
        \ then the broker cleans up the 3 resources and exists"
        $ runTestApp $ do
          resourceCreated <- newEmptyMVar
          cleanupCalled <- newTVarIO []
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer = \k -> Initialize k (Just k),
                    messageDispatcher = \k _w _a -> do
                      putMVar resourceCreated k
                      return KeepResource,
                    resourceCreator =
                      \k _mw -> return k,
                    resourceCleaner =
                      \k a -> do
                        atomically (modifyTVar cleanupCalled ((k, a) :))
                  }
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn (1 :: Int)
          deliver_ brokerIn 2
          deliver_ brokerIn 3
          takeMVar resourceCreated
            >>= liftIO . assertEqual "invalid resource created" 1
          takeMVar resourceCreated
            >>= liftIO . assertEqual "invalid resource created" 2
          takeMVar resourceCreated
            >>= liftIO . assertEqual "invalid resource created" 3
          throwTo (asyncThreadId brokerA) expectedException
          r <- either id (error . show) <$> waitCatch brokerA
          readTVarIO cleanupCalled
            >>= liftIO
              . assertEqual
                "resourceCleaner wasn't executed"
                [(1, 1), (2, 2), (3, 3)]
              . sort
          liftIO $
            assertEqual
              "exception expected"
              (show expectedException)
              (show r)
          -- prevent GC of msg box input:
          deliver_ brokerIn 666,
      testCase
        "when adding a new resource with an extra initial message,\
        \ when the messageHandler returns KeepResource,\
        \ then the resource returned from the create callback is passed to\
        \ the cleanup function"
        $ runTestApp $ do
          resourceCreated <- newEmptyMVar
          cleanupCalled <- newEmptyTMVarIO
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer = \_k -> Initialize (777 :: Int) (Just ()),
                    messageDispatcher = \_k _w a -> do
                      putMVar resourceCreated a
                      return KeepResource,
                    resourceCreator =
                      \_k _mw -> return initialResource,
                    resourceCleaner =
                      \_k a -> do
                        atomically (putTMVar cleanupCalled a)
                  }
              initialResource :: Int
              initialResource = 123
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn (1 :: Int)
          takeMVar resourceCreated
            >>= liftIO
              . assertEqual "invalid resource created" initialResource
          cancel brokerA
          r <- either id (error . show) <$> waitCatch brokerA
          liftIO $
            assertEqual
              "exception expected"
              "AsyncCancelled"
              (show r)
          atomically (takeTMVar cleanupCalled)
            >>= liftIO
              . assertEqual
                "resourceCleaner wasn't executed"
                initialResource
          -- prevent GC of msg box input:
          deliver_ brokerIn 666,
      testCase
        "when adding a new resource with an extra initial message,\
        \ when the messageHandler returns (UpdateResource x),\
        \ then x is passed to the cleanup function"
        $ runTestApp $ do
          resourceCreated <- newEmptyMVar
          cleanupCalled <- newEmptyTMVarIO
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer = \_k -> Initialize (787 :: Int) (Just ()),
                    messageDispatcher = \_k _w a -> do
                      void $ async (threadDelay 100000 >> putMVar resourceCreated a)
                      return (UpdateResource x),
                    resourceCreator =
                      \_k _mw -> return initialResource,
                    resourceCleaner =
                      \_k -> atomically . putTMVar cleanupCalled
                  }
              initialResource :: Int
              initialResource = 123
              x :: Int
              x = 234
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn (1 :: Int)
          takeMVar resourceCreated
            >>= liftIO
              . assertEqual
                "invalid resource created"
                initialResource
          cancel brokerA
          r <- either id (error . show) <$> waitCatch brokerA
          liftIO $
            assertEqual
              "exception expected"
              "AsyncCancelled"
              (show r)
          atomically (takeTMVar cleanupCalled)
            >>= liftIO
              . assertEqual
                "resourceCleaner wasn't executed"
                x
          -- prevent GC of msg box input:
          deliver_ brokerIn 666,
      testCase
        "when adding a new resource with an extra initial message,\
        \ when the messageHandler returns (RemoveResource Nothing),\
        \ then the initial resource is passed to the cleanup function"
        $ runTestApp $ do
          resourceCreated <- newEmptyMVar
          readyForCleanup <- newEmptyMVar
          cleanupCalled <- newEmptyTMVarIO
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer = \_k -> Initialize (787 :: Int) (Just ()),
                    messageDispatcher = \_k _w a -> do
                      void . async $ do
                        () <- takeMVar readyForCleanup
                        putMVar resourceCreated a
                      return (RemoveResource Nothing),
                    resourceCreator =
                      \_k _mw -> return initialResource,
                    resourceCleaner =
                      \_k a -> do
                        putMVar readyForCleanup ()
                        atomically (putTMVar cleanupCalled a)
                  }
              initialResource :: Int
              initialResource = 123
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn (1 :: Int)
          takeMVar resourceCreated
            >>= liftIO
              . assertEqual
                "invalid resource created"
                initialResource
          cancel brokerA
          r <- either id (error . show) <$> waitCatch brokerA
          liftIO $
            assertEqual
              "exception expected"
              "AsyncCancelled"
              (show r)
          atomically (takeTMVar cleanupCalled)
            >>= liftIO
              . assertEqual
                "resourceCleaner wasn't executed"
                initialResource
          -- prevent GC of msg box input:
          deliver_ brokerIn 666,
      testCase
        "when adding a new resource with an extra initial message,\
        \ when the messageHandler returns (RemoveResource (Just x)),\
        \ then x is passed to the cleanup function"
        $ runTestApp $ do
          resourceCreated <- newEmptyMVar
          readyForCleanup <- newEmptyMVar
          cleanupCalled <- newEmptyTMVarIO
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer = \_k -> Initialize (787 :: Int) (Just ()),
                    messageDispatcher = \_k _w a -> do
                      void . async $ do
                        () <- takeMVar readyForCleanup
                        putMVar resourceCreated a
                      return (RemoveResource (Just x)),
                    resourceCreator =
                      \_k _mw -> return initialResource,
                    resourceCleaner =
                      \_k a -> do
                        putMVar readyForCleanup ()
                        atomically (putTMVar cleanupCalled a)
                  }
              initialResource :: Int
              initialResource = 123
              x :: Int
              x = 234
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn (1 :: Int)
          takeMVar resourceCreated
            >>= liftIO
              . assertEqual
                "invalid resource created"
                initialResource
          cancel brokerA
          r <- either id (error . show) <$> waitCatch brokerA
          liftIO $
            assertEqual
              "exception expected"
              "AsyncCancelled"
              (show r)
          atomically (takeTMVar cleanupCalled)
            >>= liftIO
              . assertEqual
                "resourceCleaner wasn't executed"
                x
          -- prevent GC of msg box input:
          deliver_ brokerIn 666,
      testCase
        "when adding a new resource without an extra initial message,\
        \ then the initial resource is passed to the cleanup function"
        $ runTestApp $ do
          resourceCreated <- newEmptyMVar
          cleanupCalled <- newEmptyTMVarIO
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer = \_k -> Initialize (787 :: Int) (Just ()),
                    messageDispatcher = \_k _w a -> do
                      void $ async (threadDelay 100000 >> putMVar resourceCreated a)
                      return (UpdateResource x),
                    resourceCreator =
                      \_k _mw -> return initialResource,
                    resourceCleaner =
                      \_k -> atomically . putTMVar cleanupCalled
                  }
              initialResource :: Int
              initialResource = 123
              x :: Int
              x = 234
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn (1 :: Int)
          takeMVar resourceCreated
            >>= liftIO
              . assertEqual
                "invalid resource created"
                initialResource
          cancel brokerA
          r <- either id (error . show) <$> waitCatch brokerA
          liftIO $
            assertEqual
              "exception expected"
              "AsyncCancelled"
              (show r)
          atomically (takeTMVar cleanupCalled)
            >>= liftIO
              . assertEqual
                "resourceCleaner wasn't executed"
                x
          -- prevent GC of msg box input:
          deliver_ brokerIn 666,
      testCase
        "on a broker with two resources a and b with keys 1 and 2,\
        \ for an incoming message with key=1 the MessageDispatcher is\
        \ called with resource a and for key=2 with resource b"
        $ runTestApp $ do
          messageDispatched <- newEmptyMVar
          cleanupCalled <- newTVarIO []
          let brokerCfg =
                MkBrokerConfig
                  { demultiplexer = \(k, isInit) ->
                      if isInit
                        then Initialize k Nothing
                        else Dispatch k k,
                    resourceCreator =
                      \k _mw -> return k,
                    messageDispatcher = \k _w a -> do
                      putMVar messageDispatched (k, a)
                      return KeepResource,
                    resourceCleaner =
                      \k a -> do
                        atomically (modifyTVar cleanupCalled ((k, a) :))
                  }
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn (1 :: Int, True)
          deliver_ brokerIn (2, True)
          deliver_ brokerIn (1, False)
          deliver_ brokerIn (2, False)
          takeMVar messageDispatched
            >>= liftIO
              . assertEqual "invalid resource" (1, 1)
          takeMVar messageDispatched
            >>= liftIO
              . assertEqual "invalid resource" (2, 2)
          throwTo (asyncThreadId brokerA) expectedException
          r <- either id (error . show) <$> waitCatch brokerA
          readTVarIO cleanupCalled
            >>= liftIO
              . assertEqual
                "resourceCleaner wasn't executed"
                [(1, 1), (2, 2)]
              . sort
          liftIO $
            assertEqual
              "exception expected"
              (show expectedException)
              (show r)
          -- prevent GC of msg box input:
          deliver_ brokerIn (666, False),
      testCase
        "When the MessageDispatcher is called with resource x and \
        \ returns (UpdateResource y), then next time it is called with\
        \ resource y"
        $ runTestApp $ do
          messageDispatched <- newEmptyMVar
          let x :: Int
              x = 42
              y = x + 1295
              brokerCfg =
                MkBrokerConfig
                  { demultiplexer = \isInit ->
                      if isInit
                        then Initialize (787 :: Int) Nothing
                        else Dispatch (787 :: Int) (),
                    resourceCreator = \_k _mw ->
                      return x,
                    messageDispatcher = \_k _w a -> do
                      putMVar messageDispatched a
                      return (UpdateResource y),
                    resourceCleaner = \_k _a ->
                      return ()
                  }
          (brokerIn, brokerA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited brokerCfg
          deliver_ brokerIn True
          deliver_ brokerIn False
          deliver_ brokerIn False
          takeMVar messageDispatched
            >>= liftIO . assertEqual "invalid resource" x
          takeMVar messageDispatched
            >>= liftIO . assertEqual "invalid resource" y
          cancel brokerA
          r <- either id (error . show) <$> waitCatch brokerA
          liftIO $
            assertEqual
              "exception expected"
              "AsyncCancelled"
              (show r)
          -- prevent GC of msg box input:
          deliver_ brokerIn False,
      testCase
        "when the receive function throws a synchronous exception x,\
        \ then all resources will be cleaned up and\
        \ the broker will re-throw x"
        $ runTestApp $ do
          cr <- newTVarIO []
          cl <- newTVarIO []
          let bCfg =
                MkBrokerConfig
                  { demultiplexer = (`Initialize` Nothing),
                    resourceCreator = \k _mw -> do
                      atomically $
                        modifyTVar cr (k :)
                      return (),
                    messageDispatcher = \_k _w _a ->
                      return KeepResource,
                    resourceCleaner = \k _a ->
                      atomically $ modifyTVar cl (k :)
                  }
              inter =
                MkInterceptingBoxArg
                  ( MkInterceptor $ do
                      rs <- readTVarIO cr
                      if rs == [3, 2, 1]
                        then throwIO expectedException
                        else return Nothing
                  )
                  (MkInterceptor (return Nothing))
                  BlockingUnlimited
          (b, bA) <-
            either (error . show) id
              <$> spawnBroker inter bCfg
          deliver_ b (1 :: Int)
          deliver_ b (2 :: Int)
          deliver_ b (3 :: Int)
          deliver_ b (4 :: Int)
          ex <- either id (error . show) <$> waitCatch bA
          liftIO $
            assertEqual
              "exception expected"
              (show expectedException)
              (show ex)
          readTVarIO cl
            >>= liftIO
              . assertEqual
                "all resources must be cleaned"
                [3, 2, 1]
          -- prevent GC of msg box input:
          deliver_ b 666,
      testCase
        "when the receive function returns Nothing,\
        \ then all resources will be cleaned up and\
        \ the broker will exit."
        $ runTestApp $ do
          cr <- newTVarIO []
          cl <- newTVarIO []
          let bCfg =
                MkBrokerConfig
                  { demultiplexer = (`Initialize` Nothing),
                    resourceCreator = \k _mw -> do
                      atomically $
                        modifyTVar cr (k :)
                      return (),
                    messageDispatcher = \_k _w _a ->
                      return KeepResource,
                    resourceCleaner = \k _a ->
                      atomically $ modifyTVar cl (k :)
                  }
              inter =
                MkInterceptingBoxArg
                  ( MkInterceptor $ do
                      rs <- readTVarIO cr
                      if rs == [3, 2, 1]
                        then return (Just False)
                        else return Nothing
                  )
                  (MkInterceptor (return Nothing))
                  BlockingUnlimited
          (b, bA) <-
            either (error . show) id
              <$> spawnBroker inter bCfg
          deliver_ b (1 :: Int)
          deliver_ b (2 :: Int)
          deliver_ b (3 :: Int)
          deliver_ b (4 :: Int)
          wait bA
            >>= liftIO
              . assertEqual "exit expected" MkBrokerResult
          readTVarIO cl
            >>= liftIO
              . assertEqual "all resources must be cleaned" [3, 2, 1]
          -- prevent GC of msg box input:
          deliver_ b 666,
      testCase
        "when an initialisation message without payload for an existant resource\
        \ is received, the message is ignored"
        $ runTestApp $ do
          cr <- newTVarIO []
          cl <- newTVarIO []
          let bCfg =
                MkBrokerConfig
                  { demultiplexer = (`Initialize` Nothing),
                    resourceCreator = \k _mw ->
                      atomically $ modifyTVar cr (k :),
                    messageDispatcher = \_k _w _a ->
                      error "unexpected call to messageDispatcher",
                    resourceCleaner = \k _a ->
                      atomically $ modifyTVar cl (k :)
                  }
          (b, bA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited bCfg
          deliver_ b (1 :: Int)
          deliver_ b (1 :: Int)
          deliver_ b (2 :: Int)
          atomically $ do
            crs <- readTVar cr
            checkSTM (crs == [2, 1])
          cancel bA
          waitCatch bA
            >>= liftIO
              . assertEqual
                "exit expected"
                "Left AsyncCancelled"
              . show
          readTVarIO cl
            >>= liftIO
              . assertEqual
                "all resources must be cleaned"
                [2, 1]
          -- prevent GC of msg box input:
          deliver_ b 666,
      testCase
        "when an initialisation message with payload, \
        \ then after the resource creation is done, \
        \ the payload is dispatched to the messageDispatcher"
        $ runTestApp $ do
          done <- newEmptyMVar
          let bCfg =
                MkBrokerConfig
                  { demultiplexer = (`Initialize` Just ()),
                    resourceCreator = \_k mw ->
                      case mw of
                        Just () ->
                          return ()
                        Nothing ->
                          error "now initial message",
                    messageDispatcher = \_k _w _a -> do
                      putMVar done ()
                      return KeepResource,
                    resourceCleaner = \_k _a -> return ()
                  }
          (b, bA) <-
            either (error . show) id
              <$> spawnBroker BlockingUnlimited bCfg
          deliver_ b (1 :: Int)
          deliver_ b (1 :: Int)
          deliver_ b (2 :: Int)
          takeMVar done
          cancel bA
          waitCatch bA
            >>= liftIO
              . assertEqual "exit expected" "Left AsyncCancelled"
              . show
          -- prevent GC of msg box input:
          deliver_ b 666
    ]

newtype Interceptor = MkInterceptor
  { runInterceptor ::
      forall m.
      MonadUnliftIO m =>
      m (Maybe Bool)
  }

data InterceptingBoxArg b
  = MkInterceptingBoxArg
      Interceptor -- receive interceptor
      Interceptor -- deliver interceptor
      b

data InterceptingBox b a
  = MkInterceptingBox
      Interceptor -- receive interceptor
      Interceptor -- deliver interceptor
      (b a)

data InterceptingBoxIn i a
  = MkInterceptingBoxIn
      Interceptor
      (i a)

instance IsMessageBoxArg b => IsMessageBoxArg (InterceptingBoxArg b) where
  type MessageBox (InterceptingBoxArg b) = InterceptingBox (MessageBox b)
  newMessageBox (MkInterceptingBoxArg r i a) =
    MkInterceptingBox r i <$> newMessageBox a
  getConfiguredMessageLimit (MkInterceptingBoxArg _ _ a) =
    getConfiguredMessageLimit a

instance IsMessageBox b => IsMessageBox (InterceptingBox b) where
  type Input (InterceptingBox b) = InterceptingBoxIn (Input b)
  newInput (MkInterceptingBox _ i b) =
    MkInterceptingBoxIn i <$> newInput b
  receive (MkInterceptingBox r _ b) = do
    mi <- runInterceptor r
    case mi of
      Nothing ->
        receive b
      Just True ->
        receive b
      Just False ->
        return Nothing
  tryReceive (MkInterceptingBox r _ b) = do
    -- oh my ... dunno what to do in this case...
    _mi <- runInterceptor r
    tryReceive b

instance IsInput i => IsInput (InterceptingBoxIn i) where
  deliver (MkInterceptingBoxIn interceptIn i) x = do
    mi <- runInterceptor interceptIn
    case mi of
      Nothing ->
        deliver i x
      Just o ->
        return o
