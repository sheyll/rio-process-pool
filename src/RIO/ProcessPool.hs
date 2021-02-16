-- | Pools of Async Workers
--
-- Provide the management of processes running user supplied 
-- callbacks.
--
-- Each worker has its own 'MessageBox'.
--
-- The Pool process has a central message box and where it
-- receives 'Multiplexed' messages.
--
-- The pool process writes the payloads to the corresponding 
-- workers message box.
--
-- This module also re-exports "UnliftIO.MessageBox" which is
-- the foundation of this library, and which is also needed
-- to get most out of this library.
module RIO.ProcessPool
  ( module RIO.ProcessPool.Broker,
    module RIO.ProcessPool.Pool,
    module UnliftIO.MessageBox
  )
where

import RIO.ProcessPool.Broker
  ( BrokerConfig (..),
    BrokerResult (..),
    Demultiplexer,
    MessageHandler,
    Multiplexed (..),
    ResourceCleaner,
    ResourceCreator,
    ResourceUpdate (..),
    spawnBroker,
  )
import RIO.ProcessPool.Pool
  ( Pool (..),
    PoolWorkerCallback (..),
    removePoolWorkerMessage,
    spawnPool,
  )
  
import UnliftIO.MessageBox
