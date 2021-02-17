{-# LANGUAGE Strict #-}

-- | A broker extracts a /key/ value from incoming messages
--  and creates, keeps and destroys a /resource/ for each key.
--
-- The demultiplexed messages and their resources are passed to
-- a custom 'MessageHandler'/
--
-- The user provides a 'Demultiplexer' is a pure function that
-- returns a key for the resource associated
-- to the message and potientially changes the
-- message.
--
-- The demultiplexer may also return a value indicating that
-- a new resource must be created, or that a message
-- shall be ignored.
--
-- The broker is run in a seperate process using 'async'.
-- The usual way to stop a broker is to 'cancel' it.
--
-- When cancelling a broker, the resource cleanup
-- actions for all resources will be called with
-- async exceptions masked.
--
-- In order to prevent the resource map filling up with
-- /dead/ resources, the user of this module has to ensure
-- that whenever a resource is not required anymore, a message
-- will be sent to the broker, that will cause the 'MessageHandler'
-- to be executed for the resource, which will in turn return,
-- return 'RemoveResource'.
module RIO.ProcessPool.Broker
  ( spawnBroker,
    BrokerConfig (..),
    BrokerResult (..),
    ResourceCreator,
    Demultiplexer,
    ResourceCleaner,
    MessageHandler,
    Multiplexed (..),
    ResourceUpdate (..),
  )
where

import qualified Data.Map.Strict as Map
import RIO
import UnliftIO.MessageBox
  ( IsMessageBox (Input, newInput, receive),
    IsMessageBoxArg (MessageBox, newMessageBox),
  )
import Control.Concurrent.Async(AsyncCancelled)  

-- | Spawn a broker with a new 'MessageBox',
--  and return its message 'Input' channel as well as
-- the 'Async' handle of the spawned process, needed to
-- stop the broker process.
--
-- * @k@ is the /key/ for the resource associated to an incoming
--   message
-- * @w'@ is the type of incoming messages.
-- * @w@ is the type of the demultiplexed messages.
-- * @a@ specifies the resource type.
-- * @m@ is the base monad
spawnBroker ::
  forall brokerBoxArg k w' w a m.
  ( HasLogFunc m,
    Ord k,
    Display k,
    IsMessageBoxArg brokerBoxArg
  ) =>
  brokerBoxArg ->
  BrokerConfig k w' w a m ->
  RIO
    m
    ( Either
        SomeException
        ( Input (MessageBox brokerBoxArg) w',
          Async BrokerResult
        )
    )
spawnBroker brokerBoxArg config = do
  brokerA <- async $ do
    mBrokerBox <-
      tryAny
        ( do
            b <- newMessageBox brokerBoxArg
            i <- newInput b
            return (b, i)
        )
    case mBrokerBox of
      Left er -> return (Left er)
      Right (brokerBox, brokerInp) -> do
        aInner <- mask_ $
          asyncWithUnmask $ \unmaskInner ->
            brokerLoop unmaskInner brokerBox config Map.empty
        return (Right (brokerInp, aInner))
  join <$> waitCatch brokerA

-- | This is just what the 'Async' returned from
-- 'spawnBroker' returns, it's current purpose is to
-- make code easier to read.
--
-- Instead of some @Async ()@ that could be anything,
-- there is @Async BrokerResult@.
data BrokerResult = MkBrokerResult
  deriving stock (Show, Eq)

-- | The broker configuration, used by 'spawnBroker'.
--
-- * @k@ is the /key/ for the resource associated to an incoming
--   message
-- * @w'@ is the type of incoming messages.
-- * @w@ is the type of the demultiplexed messages.
-- * @a@ specifies the resource type.
-- * @m@ is the base monad
data BrokerConfig k w' w a m = MkBrokerConfig
  { demultiplexer :: !(Demultiplexer w' k w),
    messageDispatcher :: !(MessageHandler k w a m),
    resourceCreator :: !(ResourceCreator k w a m),
    resourceCleaner :: !(ResourceCleaner k a m)
  }

-- | User supplied callback to extract the key and the 'Multiplexed'
--  from a message.
--  (Sync-) Exceptions thrown from this function are caught and lead
--  to dropping of the incoming message, while the broker continues.
--
-- * @k@ is the /key/ for the resource associated to an incoming
--   message
-- * @w'@ is the type of incoming messages.
-- * @w@ is the type of the demultiplexed messages.
type Demultiplexer w' k w = w' -> Multiplexed k w

-- | User supplied callback to use the 'Multiplexed' message and
--  the associated resource.
--  (Sync-) Exceptions thrown from this function are caught and lead
--  to immediate cleanup of the resource but the broker continues.
--
-- * Type @k@ is the /key/ for the resource associated to an incoming
--   message
-- * Type @w@ is the type of incoming, demultiplexed, messages.
-- * Type @a@ specifies the resource type.
-- * Type @m@ is the base monad
type MessageHandler k w a m = k -> w -> a -> RIO m (ResourceUpdate a)

-- | This value indicates in what state a worker is in after the
--  'MessageHandler' action was executed.
data ResourceUpdate a
  = -- | The resources is still required.
    KeepResource
  | -- | The resource is still required but must be updated.
    UpdateResource a
  | -- | The resource is obsolete and can
    --   be removed from the broker.
    --   The broker will call 'ResourceCleaner' either
    --   on the current, or an updated resource value.
    RemoveResource !(Maybe a)

-- | The action that the broker has to take for in incoming message.
--
-- * @k@ is the /key/ for the resource associated to an incoming
--   message
-- * @w@ is the type of the demultiplexed messages.
data Multiplexed k w
  = -- | The message is an initialization message, that requires the
    --   creation of a new resouce for the given key.
    --   When the resource is created, then /maybe/ additionally
    --   a message will also be dispatched.
    Initialize k !(Maybe w)
  | -- | Dispatch a message using an existing resource.
    -- Silently ignore if no resource for the key exists.
    Dispatch k w

-- deriving stock (Show)

-- | User supplied callback to create and initialize a resource.
--  (Sync-) Exceptions thrown from this function are caught,
--  and the broker continues.
--
-- * @k@ is the /key/ for the resource associated to an incoming
--   message
-- * @w@ is the type of the demultiplexed messages.
-- * @a@ specifies the resource type.
-- * @m@ is the monad of the returned action.
type ResourceCreator k w a m = k -> Maybe w -> RIO m a

-- | User supplied callback called _with exceptions masked_
-- when the 'MessageHandler' returns 'RemoveResource'
-- (Sync-) Exceptions thrown from this function are caught,
-- and do not prevent the removal of the resource, also the
-- broker continues.
--
-- * @k@ is the /key/ for the resource associated to an incoming
--   message
-- * @a@ specifies the resource type.
-- * @m@ is the monad of the returned action.
type ResourceCleaner k a m = k -> a -> RIO m ()

type BrokerState k a = Map k a

{-# NOINLINE brokerLoop #-}
brokerLoop ::
  ( HasLogFunc m,
    Ord k,
    Display k,
    IsMessageBox msgBox
  ) =>
  (forall x. RIO m x -> RIO m x) ->
  msgBox w' ->
  BrokerConfig k w' w a m ->
  BrokerState k a ->
  RIO m BrokerResult
brokerLoop unmask brokerBox config brokerState =
  withException
    ( unmask (receive brokerBox)
        >>= traverse (tryAny . onIncoming unmask config brokerState)
    )
    ( \(ex :: SomeException) -> do      
        case fromException ex of
          Just (_cancelled :: AsyncCancelled) ->
            logDebug "broker loop: cancelled"
          _ ->
            logError
              ( "broker loop: exception while \
                \receiving and dispatching messages: "
                  <> display ex
              )
        cleanupAllResources config brokerState
    )
    >>= maybe
      ( do
          logError "broker loop: failed to receive next message"
          cleanupAllResources config brokerState
          return MkBrokerResult
      )
      ( \res -> do
          next <-
            either
              ( \err -> do
                  logWarn
                    ( "broker loop: Handling the last message\
                      \ caused an exception:"
                        <> display err
                    )
                  return brokerState
              )
              return
              res
          brokerLoop unmask brokerBox config next
      )

{-# NOINLINE onIncoming #-}
onIncoming ::
  (Ord k, HasLogFunc m, Display k) =>
  (forall x. RIO m x -> RIO m x) ->
  BrokerConfig k w' w a m ->
  BrokerState k a ->
  w' ->
  RIO m (BrokerState k a)
onIncoming unmask config brokerState w' =
  case demultiplexer config w' of
    Initialize k mw ->
      onInitialize unmask k config brokerState mw
    Dispatch k w ->
      onDispatch unmask k w config brokerState

onInitialize ::
  (Ord k, HasLogFunc m, Display k) =>
  (forall x. RIO m x -> RIO m x) ->
  k ->
  BrokerConfig k w' w a m ->
  BrokerState k a ->
  Maybe w ->
  RIO m (BrokerState k a)
onInitialize unmask k config brokerState mw =
  case Map.lookup k brokerState of
    Just _ -> do
      logError
        ( "cannot initialize a new worker, a worker with that ID exists: "
            <> display k
        )
      return brokerState
    Nothing ->
      tryAny (unmask (resourceCreator config k mw))
        >>= either
          ( \err -> do
              logError
                ( "the resource creator for worker "
                    <> display k
                    <> " threw an exception: "
                    <> display err
                )
              return brokerState
          )
          ( \res ->
              let brokerState1 = Map.insert k res brokerState
               in case mw of
                    Nothing ->
                      return brokerState1
                    Just w ->
                      onException
                        (onDispatch unmask k w config brokerState1)
                        ( do
                            logError
                              ( "exception while dispatching the "
                                  <> "post-initialization message for worker: "
                                  <> display k
                              )
                            resourceCleaner config k res
                        )
          )

onDispatch ::
  (Ord k, HasLogFunc m, Display k) =>
  (forall x. RIO m x -> RIO m x) ->
  k ->
  w ->
  BrokerConfig k w' w a m ->
  BrokerState k a ->
  RIO m (BrokerState k a)
onDispatch unmask k w config brokerState =
  maybe notFound dispatch (Map.lookup k brokerState)
  where
    notFound = do
      logWarn
        ( "cannot dispatch message, worker not found: "
            <> display k
        )
      return brokerState
    dispatch res =
      tryAny (unmask (messageDispatcher config k w res))
        >>= either
          ( \err -> do

              logError
                ( "the message dispatcher callback for worker "
                    <> display k
                    <> " threw: "
                    <> display err
                )
              cleanupResource
                k
                config
                brokerState
          )
          ( \case
              KeepResource ->
                return brokerState
              UpdateResource newRes ->
                return (Map.insert k newRes brokerState)
              RemoveResource mNewRes ->
                cleanupResource
                  k
                  config
                  ( maybe
                      brokerState
                      ( \newRes ->
                          Map.insert k newRes brokerState
                      )
                      mNewRes
                  )
          )

cleanupAllResources ::
  BrokerConfig k w' w a m ->
  BrokerState k a ->
  RIO m ()
cleanupAllResources config brokerState =
  traverse_
    ( uncurry
        (tryResourceCleaner config)
    )
    (Map.assocs brokerState)

cleanupResource ::
  (Ord k) =>
  k ->
  BrokerConfig k w' w a m ->
  Map k a ->
  RIO m (Map k a)
cleanupResource k config brokerState = do
  traverse_ (tryResourceCleaner config k) (Map.lookup k brokerState)
  return (Map.delete k brokerState)

tryResourceCleaner ::
  BrokerConfig k w' w a m ->
  k ->
  a ->
  RIO m ()
tryResourceCleaner config k res = do
  void $ tryAny (resourceCleaner config k res)
