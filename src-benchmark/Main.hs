{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Main (main) where

import Criterion.Main (defaultMain)
import Criterion.Types
  ( bench,
    bgroup,
    nfAppIO,
  )
import RIO
import RIO.ProcessPool

main =
  defaultMain
    [ bgroup
        "Pool"
        [ bench
            ( "Sending "
                <> show noMessages
                <> " msgs for "
                <> show receiverNo
                <> " receivers"
            )
            ( nfAppIO
                (runSimpleApp . unidirectionalMessagePassing BlockingUnlimited BlockingUnlimited)
                (noMessages, receiverNo)
            )
          | noMessages <- [10,50],
            receiverNo <- [500, 1000]
        ]
    ]

mkTestMessage :: Int -> TestMessage
mkTestMessage !i =
  MkTestMessage
    ( i,
      ( "The not so very very very very very very very very very very very very very very very very very very very very very very very very "
          <> utf8BuilderToText (displayShow (23 * i)),
        "large",
        "meeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeessssssssssssssssssssssssssssssssss"
          <> utf8BuilderToText (displayShow i),
        ( "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
          even i,
          123423421111111111111111111123234 * toInteger i
        )
      )
    )

newtype TestMessage = MkTestMessage (Int, (Text, Text, Text, (Text, Text, Bool, Integer)))
  deriving newtype (Show)

instance Display TestMessage where
  display (MkTestMessage (x, (a, b, c, (d, e, f, g)))) =
    display x <> display ':'
      <> display a
      <> display ' '
      <> display b
      <> display ' '
      <> display c
      <> display ' '
      <> display d
      <> display ' '
      <> display e
      <> display ' '
      <> displayShow f
      <> display ' '
      <> display g
      <> display '.'

unidirectionalMessagePassing ::
  (IsMessageBoxArg boxPool, IsMessageBoxArg boxWorker) =>
  boxPool ->
  boxWorker ->
  (Int, Int) ->
  RIO SimpleApp ()
unidirectionalMessagePassing !boxPool !boxWorker (!nM, !nC) = do
  allStopped <- newEmptyMVar
  logInfo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ BEGIN ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  spawnPool
    boxPool
    boxWorker
    ( MkPoolWorkerCallback
        ( \k b ->
            ( do
                consume k b
                putMVar allStopped ()
            )
              `withException` ( \(e :: SomeException) ->
                                  logError
                                    ( "consume threw exception: "
                                        <> display e
                                        <> " for worker: "
                                        <> display k
                                    )
                              )
        )
    )
    >>= \case
      Left err -> error (show err)
      Right pool -> do
        forM_ [0..1 :: Int] $ \ !runIndex -> do
          logInfo "                    ~~~ NEXT ROUND ~~~"
          producer runIndex pool
          logInfo "                         ~~ WAITING FOR RESULTS ~~"
          awaitAllStopped allStopped          
          -- sendPoison runIndex pool

        cancel (poolAsync pool)
  where
    producer !runIndex !pool = do
      mapM_
        (deliverOrLog pool)
        ((`Initialize` Nothing) . (+ (nC * runIndex)) <$> [0 .. nC - 1])
      mapM_
        (deliverOrLog pool)
        (Dispatch . (+ (nC * runIndex)) <$> [0 .. nC - 1] <*> (Just . mkTestMessage <$> [0 .. nM - 1]))
    deliverOrLog pool !msg = do
      !ok <- deliver (poolInput pool) msg
      unless
        ok
        ( error
            ( "producer failed to deliver: "
                <> show
                  ( case msg of
                      Dispatch k _ -> k
                      Initialize k _ -> k
                  )
            )
        )
    -- sendPoison !runIndex !pool =     
    --   mapM_
    --       (deliverOrLog pool)
    --       ((`Dispatch` Nothing) . (+ (nC * runIndex)) <$> [0 .. nC - 1])

    consume k inBox = do
      receive inBox
        >>= maybe
          (logError ("consumer: " <> display k <> " failed to receive a message"))
          ( \msg@(MkTestMessage (!x, !_)) -> do
              logDebug ("consumer: " <> display k <> " received: " <> display msg)
              unless
                (x == nM - 1)
                (consume k inBox)
          )

    awaitAllStopped allStopped =
      replicateM_ nC (void $ takeMVar allStopped)
        `withException` ( \(e :: SomeException) ->
                            logError ("exception in awaitAllStopped: " <> display e)
                        )
