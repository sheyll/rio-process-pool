{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Utils
  ( MockBoxInit (..),
    MockBox (..),
    NoOpArg (..),
    NoOpBox (..),
    NoOpInput (..),
    runTestApp,
  )
where

import RIO
import UnliftIO.MessageBox.Class
  ( IsInput (..),
    IsMessageBox (Input, newInput, receive, tryReceive),
    IsMessageBoxArg (..),
  )
import UnliftIO.MessageBox.Util.Future (Future (Future))

runTestApp :: MonadUnliftIO m => RIO LogFunc b -> m b
runTestApp x = do
  let isVerbose = True
  logToStdErr <- logOptionsHandle stdout isVerbose
  withLogFunc logToStdErr $ flip runRIO x

-- message box implementation
-- NOTE: Because of parametricity and the existential quantification
-- of the message payload, the receive and deliver methods
-- are only capable of throwing exceptions or bottoming out

data MockBoxInit msgBox = MkMockBoxInit
  { mockBoxNew :: forall m a. MonadUnliftIO m => m (msgBox a),
    mockBoxLimit :: !(Maybe Int)
  }

instance IsMessageBox msgBox => IsMessageBoxArg (MockBoxInit msgBox) where
  type MessageBox (MockBoxInit msgBox) = msgBox
  getConfiguredMessageLimit = mockBoxLimit
  newMessageBox b = mockBoxNew b

data MockBox input a = MkMockBox
  { mockBoxNewInput :: forall m. MonadUnliftIO m => m (input a),
    mockBoxReceive :: forall m. MonadUnliftIO m => m (Maybe a),
    mockBoxTryReceive :: forall m. MonadUnliftIO m => m (Future a)
  }

instance IsInput input => IsMessageBox (MockBox input) where
  type Input (MockBox input) = input
  newInput m = mockBoxNewInput m
  receive m = mockBoxReceive m
  tryReceive m = mockBoxTryReceive m

data NoOpArg
  = NoOpArg
  deriving stock (Show)

newtype NoOpInput a
  = OnDeliver (forall m. MonadUnliftIO m => a -> m Bool)

data NoOpBox a
  = OnReceive (Maybe Int) (Maybe a)
  deriving stock (Show)

instance IsMessageBoxArg NoOpArg where
  type MessageBox NoOpArg = NoOpBox
  newMessageBox NoOpArg = return (OnReceive Nothing Nothing)
  getConfiguredMessageLimit _ = Nothing

instance IsMessageBox NoOpBox where
  type Input NoOpBox = NoOpInput
  newInput _ = return $ OnDeliver (const (return False))
  receive (OnReceive t r) = do
    traverse_ threadDelay t
    return r
  tryReceive (OnReceive t r) = do
    timeoutVar <- traverse registerDelay t
    return
      ( Future
          ( do
              isOver <- fromMaybe True <$> traverse readTVarIO timeoutVar
              if isOver
                then return r
                else return Nothing
          )
      )

instance IsInput NoOpInput where
  deliver (OnDeliver react) m =
    react m
