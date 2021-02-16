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
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Main (main) where

import qualified CommandBenchmark
import Control.Monad (replicateM, unless)
import Criterion.Main (defaultMain)
import Criterion.Types
  ( bench,
    bgroup,
    nfAppIO,
  )
import Data.Semigroup (Semigroup (stimes))
import UnliftIO.MessageBox.CatchAll
  ( CatchAllArg (..),
  )
import UnliftIO.MessageBox.Class
  ( IsInput (..),
    IsMessageBox (..),
    IsMessageBoxArg (..),
    deliver,
    newInput,
    receive,
  )
import qualified UnliftIO.MessageBox.Limited as L
import qualified UnliftIO.MessageBox.Unlimited as U
import UnliftIO (MonadUnliftIO, conc, runConc)

main =
  defaultMain
    [ CommandBenchmark.benchmark,
      bgroup
        "Pool"
        [ bench
            ( mboxImplTitle <> " "
                <> show noMessages
                <> " "
                <> show senderNo
                <> " : "
                <> show receiverNo
            )
            ( nfAppIO
                impl
                (senderNo, noMessages, receiverNo)
            )
          | noMessages <- [100_000],
            (isNonBlocking, mboxImplTitle, impl) <-
              [ let x = U.BlockingUnlimited
                 in (False, "Unlimited", unidirectionalMessagePassing mkTestMessage x),
                let x = CatchAllArg U.BlockingUnlimited
                 in (False, "CatchUnlimited", unidirectionalMessagePassing mkTestMessage x),
                -- let x = L.BlockingBoxLimit L.MessageLimit_1
                --  in (False, show x, unidirectionalMessagePassing mkTestMessage x),
                -- let x = L.BlockingBoxLimit L.MessageLimit_16
                --  in (False, show x, unidirectionalMessagePassing mkTestMessage x),
                -- let x = L.BlockingBoxLimit L.MessageLimit_32
                --  in (False, show x, unidirectionalMessagePassing mkTestMessage x),
                -- let x = L.BlockingBoxLimit L.MessageLimit_64
                --  in (False, show x, unidirectionalMessagePassing mkTestMessage x),
                -- let x = L.BlockingBoxLimit L.MessageLimit_128
                --  in (False, show x, unidirectionalMessagePassing mkTestMessage x),
                let x = L.BlockingBoxLimit L.MessageLimit_256
                 in (False, "Blocking256", unidirectionalMessagePassing mkTestMessage x),
                -- ,
                -- let x = L.BlockingBoxLimit L.MessageLimit_512
                --  in (False, show x, unidirectionalMessagePassing mkTestMessage x),
                -- let x = L.BlockingBoxLimit L.MessageLimit_4096
                --  in (False, show x, unidirectionalMessagePassing mkTestMessage x),
                let x = L.NonBlockingBoxLimit L.MessageLimit_128
                  in (True, show x, unidirectionalMessagePassing mkTestMessage x),
                -- let x = L.WaitingBoxLimit Nothing 5_000_000 L.MessageLimit_128
                --  in (False, show x, unidirectionalMessagePassing mkTestMessage x),
                let x = L.WaitingBoxLimit (Just 60_000_000) 5_000_000 L.MessageLimit_256
                 in (True, "Waiting256", unidirectionalMessagePassing mkTestMessage x)
                -- let x = CatchAllArg (L.BlockingBoxLimit L.MessageLimit_128)
                --  in (False, show x, unidirectionalMessagePassing mkTestMessage x)
              ],
            (senderNo, receiverNo) <-
              [ -- (1, 1000),
                (10, 100),
                (1, 1),
                (1000, 1)
              ],
            not isNonBlocking || senderNo == 1 && receiverNo > 1
        ]
    ]

mkTestMessage :: Int -> TestMessage
mkTestMessage !i =
  MkTestMessage
    ( "The not so very very very very very very very very very very very very very very very very very very very very very very very very " ++ show i,
      "large",
      "meeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeessssssssssssssssssssssssssssssssss" ++ show i,
      ( "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        even i,
        123423421111111111111111111123234 * toInteger i
      )
    )

newtype TestMessage = MkTestMessage (String, String, String, (String, String, Bool, Integer))
  deriving newtype (Show)

unidirectionalMessagePassing ::
  (MonadUnliftIO m, IsMessageBoxArg cfg) =>
  (Int -> TestMessage) ->
  cfg ->
  (Int, Int) ->
  m ()
unidirectionalMessagePassing !msgGen !impl (!nM, !nC) = do
  allStopped <- newEmptyMVar
  pool <- startPool impl BlockingUnlimited (MkPoolWorkerCallback (consume allStopped nM))
  producer pool 
  awaitAllStopped allStopped
  cancel (poolAsync pool)  
  where
    producer pool = do 
      mapM_ 
        ( \msg@(Dispatch k v) -> do
            !ok <- deliver (poolInput pool) msg
            unless ok (error ("producer failed to deliver: " <> show k <> " " <> show v))
        )
        ((`Initialize` Nothing) <$> [0 .. cM - 1])
      mapM_
        ( \msg@(Dispatch k v) -> do
            !ok <- deliver (poolInput pool) msg
            unless ok (error ("producer failed to deliver: " <> show k <> " " <> show v))
        )
        (Dispatch <$> [0 .. cM - 1] <*> (msgGen <$> [0 .. nM - 1]))
      mapM_ 
        ( \msg@(Dispatch k v) -> do
            !ok <- deliver (poolInput pool) msg
            unless ok (error ("producer failed to deliver: " <> show k <> " " <> show v))
        )
        ((`Dispatch` Nothing) <$> [0 .. cM - 1])        
    consume allStopped 0 k _inBox = putMVar allStopped k
    consume allStopped workLeft k inBox = do
      receive inBox
        >>= maybe
          (error "consumer failed to receive")
          (const (consume allStopped (workLeft - 1) k inBox))
    awaitAllStopped allStopped = 
      replicateM_ nC (void $ takeMVar allStopped)
