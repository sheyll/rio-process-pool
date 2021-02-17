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
module RIO.ProcessPool.Pool
  ( Pool (..),
    spawnPool,
    PoolWorkerCallback (..),
    removePoolWorkerMessage,
  )
where

import RIO
import RIO.ProcessPool.Broker
  ( BrokerConfig (MkBrokerConfig),
    BrokerResult,
    Multiplexed (Dispatch),
    ResourceUpdate (KeepResource, RemoveResource),
    spawnBroker,
  )
import UnliftIO.MessageBox.Class
  ( IsInput (deliver),
    IsMessageBox (Input, newInput),
    IsMessageBoxArg (MessageBox, newMessageBox),
  )

-- | Start a 'Pool'.
--
-- Start a process that receives messages sent to the
-- 'poolInput' and dispatches them to the 'Input' of
-- __pool member__ processes. If necessary the
-- pool worker processes are started.
--
-- Each pool worker process is started using 'async' and
-- executes the 'PoolWorkerCallback'.
--
-- When the callback returns, the process will exit.
--
-- Internally the pool uses the 'async' function to wrap
-- the callback.
--
-- When a 'Multiplixed' 'Dispatch' message is received with
-- a @Nothing@ then the worker is @'cancel'led@ and the
-- worker is removed from the map.
--
-- Such a message is automatically sent after the 'PoolWorkerCallback'
-- has returned, even when an exception was thrown. See
-- 'finally'.
spawnPool ::
  forall k w poolBox workerBox m.
  ( IsMessageBoxArg poolBox,
    IsMessageBoxArg workerBox,
    Ord k,
    Display k,
    HasLogFunc m
  ) =>
  poolBox ->
  workerBox ->
  PoolWorkerCallback workerBox w k m ->
  RIO
    m
    ( Either
        SomeException
        (Pool poolBox k w)
    )
spawnPool poolBox workerBoxArg poolMemberImpl = do
  brInRef <- newEmptyMVar
  let brCfg =
        MkBrokerConfig
          id
          dispatchToWorker
          (spawnWorker workerBoxArg brInRef poolMemberImpl)
          removeWorker
  spawnBroker poolBox brCfg
    >>= traverse
      ( \(brIn, brA) -> do
          putMVar brInRef brIn
          return MkPool {poolInput = brIn, poolAsync = brA}
      )

-- | This message will 'cancel' the worker
-- with the given key.
-- If the 'PoolWorkerCallback' wants to do cleanup
-- it should use 'finally' or 'onException'.
removePoolWorkerMessage :: k -> Multiplexed k (Maybe w)
removePoolWorkerMessage !k = Dispatch k Nothing

-- | The function that processes a
-- 'MessageBox' of a worker for a specific /key/.
newtype PoolWorkerCallback workerBox w k m = MkPoolWorkerCallback
  { runPoolWorkerCallback :: k -> MessageBox workerBox w -> RIO m ()
  }

-- | A record containing the message box 'Input' of the
-- 'Broker' and the 'Async' value required to 'cancel'
-- the pools broker process.
data Pool poolBox k w = MkPool
  { -- | Message sent to this input are dispatched to workers.
    -- If the message is an 'Initialize' message, a new 'async'
    -- process will be started.
    -- If the message value is 'Nothing', the processes is killed.
    poolInput :: !(Input (MessageBox poolBox) (Multiplexed k (Maybe w))),
    -- | The async of the internal 'Broker'.
    poolAsync :: !(Async BrokerResult)
  }

-- | Internal data structure containing a workers
-- message 'Input' and 'Async' value for cancellation.
data PoolWorker workerBox w = MkPoolWorker
  { poolWorkerIn :: !(Input (MessageBox workerBox) w),
    poolWorkerAsync :: !(Async ())
  }

dispatchToWorker ::
  (HasLogFunc m, IsInput (Input (MessageBox b)), Display k) =>
  k ->
  Maybe w ->
  PoolWorker b w ->
  RIO m (ResourceUpdate (PoolWorker b w))
dispatchToWorker k pMsg pm =
  case pMsg of
    Just w -> helper w
    Nothing -> return (RemoveResource Nothing)
  where
    helper msg = do
      ok <- deliver (poolWorkerIn pm) msg
      if not ok
        then do
          logError ("failed to deliver message to pool worker: " <> display k)
          return (RemoveResource Nothing)
        else return KeepResource

spawnWorker ::
  forall k w poolBoxIn workerBox m.
  ( IsMessageBoxArg workerBox,
    HasLogFunc m,
    IsInput poolBoxIn,
    Display k
  ) =>
  workerBox ->
  MVar (poolBoxIn (Multiplexed k (Maybe w))) ->
  PoolWorkerCallback workerBox w k m ->
  k ->
  Maybe (Maybe w) ->
  RIO m (PoolWorker workerBox w)
spawnWorker workerBox brInRef pmCb this _mw = do
  inputRef <- newEmptyMVar
  a <- async (go inputRef `finally` enqueueCleanup)
  boxInM <- takeMVar inputRef
  case boxInM of
    Nothing -> do
      cancel a
      throwIO (stringException "failed to spawnWorker")
    Just boxIn ->
      return MkPoolWorker {poolWorkerIn = boxIn, poolWorkerAsync = a}
  where
    go inputRef = do
      (b, boxIn) <-
        withException
          ( do
              b <- newMessageBox workerBox
              boxIn <- newInput b
              return (b, boxIn)
          )
          (\(ex :: SomeException) -> do
              logError
                ( "failed to create the message box for the new pool worker: "
                    <> display this
                    <> " exception caught: "
                    <> display ex
                )
              putMVar inputRef Nothing
          )
      putMVar inputRef (Just boxIn)
      runPoolWorkerCallback pmCb this b
    enqueueCleanup =
      tryReadMVar brInRef
        >>= traverse_
          ( \brIn ->
              void (deliver brIn (removePoolWorkerMessage this))
          )

removeWorker ::  
  k ->
  PoolWorker workerBox w ->
  RIO m ()
removeWorker _k =
  void . cancel . poolWorkerAsync
