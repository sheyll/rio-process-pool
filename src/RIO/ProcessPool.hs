-- | Launch- and Dispatch messages to processes.
--
-- A pool has an 'Input' for 'Multiplexed' messages,
-- and dispatches incoming messges to concurrent
-- processes using user defined @'MessageBox'es@.
--
-- The pool starts and stops the processes and
-- creates the message boxes.
--
-- The user supplied 'PoolWorkerCallback'
-- usually runs a loop that @'receive's@ messages
-- from the 'MessageBox' created by the pool for that worker.
--
-- When a worker process dies, e.g. because the
-- 'PoolWorkerCallback' returns, the pool
-- process will also 'cancel' the process (just to make sure...)
-- and cleanup the internal 'Broker'.
module RIO.ProcessPool
  ( -- | A process that receives messages and dispatches them to 
    --   a callback. 
    --   Each message must contain a /key/ that identifies a resource.
    --   That resource is created and cleaned by user supplied 
    --   callback functions.    
    module RIO.ProcessPool.Broker,
    -- | A process that receives messages and dispatches them to 
    --   other processes.
    --   Building directly on "RIO.ProcessPool.Broker", it provides 
    --   a central message box 'Input', from which messages are 
    --   are delivered to the corresponding message box 'Input's.
    module RIO.ProcessPool.Pool,
    -- | Re-export.
    module UnliftIO.MessageBox,
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
