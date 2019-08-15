{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE StrictData                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
--------------------------------------------------------------------------------
-- |
-- Module    :  Database.EventStore.Internal.Driver
-- Copyright :  (C) 2019 Yorick Laupa
-- License   :  (see the file LICENSE)
-- Maintainer:  Yorick Laupa <yo.eight@gmail.com>
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------------------
module Database.EventStore.Internal.Driver where

--------------------------------------------------------------------------------
import Control.Monad (forever, when, foldM, filterM)
import Data.ByteString (ByteString)
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Hashable (Hashable)
import Data.Int (Int32)
import Data.Maybe (fromMaybe)
import Data.ProtocolBuffers (Decode, encodeMessage, decodeMessage, getField)
import Data.Serialize (runPut, runGet)
import Data.Text (Text)
import Data.Time (NominalDiffTime)
import Data.UUID (UUID)
import Prelude
import Polysemy
import Polysemy.Input
import Polysemy.Output
import Polysemy.Reader
import Polysemy.State
import Data.String.Interpolate.IsString (i)

--------------------------------------------------------------------------------
import Database.EventStore.Internal.Command
import Database.EventStore.Internal.EndPoint
import Database.EventStore.Internal.Effect.Driver
import Database.EventStore.Internal.Operation (Operation, OperationError(..))
import qualified Database.EventStore.Internal.Operation.Identify as Identify
import Database.EventStore.Internal.Settings
import Database.EventStore.Internal.Types

--------------------------------------------------------------------------------
data BadNews =
  BadNews
  { badNewsId :: UUID
  , badNewsError :: OperationError
  } deriving (Show)

--------------------------------------------------------------------------------
data Exchange =
  Exchange
  { exchangeCount :: Int
  , exchangeStarted :: NominalDiffTime
  , exchangeRequest :: Package
  }

--------------------------------------------------------------------------------
type Reg = HashMap UUID Exchange

--------------------------------------------------------------------------------
data ConfirmationState
  = Authentication
  | Identification

--------------------------------------------------------------------------------
data ConnectedStage
  = Confirming [Package] NominalDiffTime UUID ConfirmationState
  | Active Reg

--------------------------------------------------------------------------------
data DriverState
  = Init
  | Awaiting [Package] ConnectingState
  | Connected ConnectionId ConnectedStage
  | Closed

--------------------------------------------------------------------------------
data Transmission
  = Send Package
  | Ignored Package
  | Recv (Either BadNews Package)
  deriving (Show)

--------------------------------------------------------------------------------
type ClientVersion = Int32
type ConnectionName = Text

--------------------------------------------------------------------------------
data Msg
  = SystemInit
  | EstablishConnection EndPoint
  | ConnectionEstablished ConnectionId
  | PackageArrived ConnectionId Package
  | SendPackage Package

----------------------------------------------------------------------------------
process :: forall r. Members [Reader Settings, Input Msg, Output Transmission, Driver] r
        => Sem r ()
process = go Init
  where
    go :: Members [Reader Settings, Input Msg, Output Transmission, Driver] r
       => DriverState
       -> Sem r ()
    go cur = do msg <- input
                go =<< react cur msg

--------------------------------------------------------------------------------
react :: Members '[Reader Settings, Output Transmission, Driver] r
      => DriverState
      -> Msg
      -> Sem r DriverState
react s SystemInit = discovery s
react s (EstablishConnection ept) = establish s ept
react s (ConnectionEstablished cid) = established s cid
react s (PackageArrived connId pkg) = packageArrived s connId pkg

--------------------------------------------------------------------------------
discovery :: Members '[Driver] r
          => DriverState
          -> Sem r DriverState
discovery = \case
  Init ->
    discovery (Awaiting [] Reconnecting)

  Awaiting pkgs Reconnecting ->
    Awaiting pkgs EndpointDiscovery <$ discover

  s -> pure s

--------------------------------------------------------------------------------
establish :: Members '[Driver] r
          => DriverState
          -> EndPoint
          -> Sem r DriverState
establish (Awaiting pkgs EndpointDiscovery) ept =
  Awaiting pkgs . ConnectionEstablishing <$> connect ept
establish s _ = pure s

--------------------------------------------------------------------------------
established :: Members '[Reader Settings, Driver, Output Transmission] r
            => DriverState
            -> ConnectionId
            -> Sem r DriverState
established s@(Awaiting pkgs (ConnectionEstablishing known)) cid
  | cid == known = do
    setts <- ask
    elapsed <- getElapsedTime

    case s_defaultUserCredentials setts of
      Just cred -> do
        pkg <- createAuthenticatePkg cred

        let uuid = packageCorrelation pkg

        output (Send pkg)
        pure $ Connected cid (Confirming pkgs elapsed uuid Authentication)

      Nothing -> do
        pkg <- identifyClient setts

        let uuid = packageCorrelation pkg

        output (Send pkg)
        pure $ Connected cid (Confirming pkgs elapsed uuid Identification)

  | otherwise = pure s
established s _ = pure s

--------------------------------------------------------------------------------
identifyClient :: Members '[Output Transmission, Driver] r
               => Settings
               -> Sem r Package
identifyClient setts = do
  uuid <- generateId
  let defName = [i|ES-#{uuid}|]
      connName = fromMaybe defName (s_defaultConnectionName setts)

  createIdentifyPkg clientVersion connName

  where
    clientVersion = 1

--------------------------------------------------------------------------------
createAuthenticatePkg :: Member Driver r => Credentials -> Sem r Package
createAuthenticatePkg cred = do
  uuid <- generateId
  let pkg = Package { packageCmd         = authenticateCmd
                    , packageCorrelation = uuid
                    , packageData        = ""
                    , packageCred        = Just cred
                    }
  pure pkg

--------------------------------------------------------------------------------
createIdentifyPkg :: Member Driver r
                  => ClientVersion
                  -> ConnectionName
                  -> Sem r Package
createIdentifyPkg version name = do
  uuid <- generateId
  let msg = Identify.newRequest version name
      pkg = Package { packageCmd         = identifyClientCmd
                    , packageCorrelation = uuid
                    , packageData        = runPut $ encodeMessage msg
                    , packageCred        = Nothing
                    }

  pure pkg

--------------------------------------------------------------------------------
-- | I'm bad at naming thing however, we are going to use that datastructure
--  so we could lookup and delete in one single pass.
data Blob a b = Blob a b

--------------------------------------------------------------------------------
instance Functor (Blob a) where
  fmap f (Blob a b) = Blob a (f b)

--------------------------------------------------------------------------------
removeExchange :: UUID -> Reg -> (Maybe Exchange, Reg)
removeExchange key reg =
  let Blob result newReg = HashMap.alterF go key reg in (result, newReg)
  where
    go Nothing  = Blob Nothing Nothing
    go (Just e) = Blob (Just e) Nothing

--------------------------------------------------------------------------------
packageArrived :: Members '[Reader Settings, Output Transmission, Driver] r
               => DriverState
               -> ConnectionId
               -> Package
               -> Sem r DriverState
packageArrived s@(Connected known stage) connId pkg
  | known /= connId = ignored s
  | otherwise =
    case () of
      _ | cmd == heartbeatResponseCmd -> pure s
        | cmd == heartbeatRequestCmd -> s <$ output (Send heartbeatResponse)
        | otherwise ->
          case stage of
            Confirming pkgs started pkgId state
              | correlation /= pkgId -> pure s
              | otherwise ->
                case state of
                  Authentication
                    | cmd == authenticatedCmd || cmd == notAuthenticatedCmd
                      -> do setts <- ask
                            idPkg <- identifyClient setts
                            elapsed <- getElapsedTime

                            let uuid = packageCorrelation idPkg

                            output (Send idPkg)
                            pure $ Connected known (Confirming pkgs elapsed uuid Identification)
                    | otherwise -> pure s

                  Identification
                    | cmd == clientIdentifiedCmd -> do
                      reg <- sendAwaitingPkgs pkgs
                      pure (Connected known (Active reg))
                    | otherwise -> pure s
            Active reg -> do
              let (excMaybe, newReg) = removeExchange correlation reg

              case excMaybe of
                Nothing -> ignored s
                Just exc -> do
                  case () of
                    _ | cmd == badRequestCmd -> do
                        let reason = packageDataAsText pkg
                            badNews =
                              BadNews
                              { badNewsId = correlation
                              , badNewsError = ServerError reason
                              }

                        output $ Recv (Left badNews)
                        pure (Connected known (Active newReg))

                      | cmd == notAuthenticatedCmd -> do
                        let badNews =
                              BadNews
                              { badNewsId = correlation
                              , badNewsError = NotAuthenticatedOp
                              }

                        output $ Recv (Left badNews)
                        pure (Connected known (Active newReg))

                      | cmd == notHandledCmd -> do
                        let Just msg = maybeDecodeMessage (packageData pkg)
                            reason   = getField $ notHandledReason msg

                        case reason of
                          N_NotMaster -> do
                            let Just details = getField $ notHandledAdditionalInfo msg
                                info         = masterInfo details
                                node         = masterInfoNodeEndPoints info

                            newCid <- forceReconnect correlation node
                            setts <- ask

                            -- TODO - We should be better at figuring out what
                            -- operation we should keep.
                            aws <- makeAwaitings setts reg
                            let newState =
                                  Awaiting (exchangeRequest exc : aws)
                                    (ConnectionEstablishing newCid)

                            pure newState

                          -- In this case with just retry the operation.
                          _ -> do
                            output (Send $ exchangeRequest exc)
                            pure s

                      | otherwise -> do
                        output (Recv $ Right pkg)
                        pure $ Connected known (Active newReg)

  where
    cmd = packageCmd pkg
    correlation = packageCorrelation pkg
    heartbeatResponse =
      heartbeatResponsePackage $ packageCorrelation pkg

packageArrived s _ _ = ignored s

--------------------------------------------------------------------------------
ignored :: s -> Sem r s
ignored = pure

--------------------------------------------------------------------------------
sendAwaitingPkgs :: forall r. Members [Output Transmission, Driver] r
                 => [Package]
                 -> Sem r Reg
sendAwaitingPkgs = foldM go HashMap.empty
  where
    go :: Members [Output Transmission, Driver] r
       => Reg
       -> Package
       -> Sem r Reg
    go reg pkg = do
      elapsed <- getElapsedTime

      let exc =
            Exchange
            { exchangeCount = 0
            , exchangeStarted = elapsed
            , exchangeRequest = pkg
            }

      HashMap.insert (packageCorrelation pkg) exc reg
        <$ output (Send pkg)

--------------------------------------------------------------------------------
makeAwaitings :: Member (Output Transmission) r
              => Settings
              -> Reg
              -> Sem r [Package]
makeAwaitings setts reg =
  fmap exchangeRequest
    <$> filterM go (HashMap.elems reg)
  where
    retry = s_operationRetry setts
    seed = fmap exchangeRequest $ HashMap.elems reg

    go exc
      | maxRetryReached retry (exchangeCount exc)
        = let badNews =
                BadNews
                { badNewsId = packageCorrelation (exchangeRequest exc)
                , badNewsError = Aborted
                } in
          False <$ output (Recv $ Left badNews)

      | otherwise = pure True

--------------------------------------------------------------------------------
maxRetryReached :: Retry -> Int -> Bool
maxRetryReached (AtMost n) i = i + 1 >= n
maxRetryReached KeepRetrying _ = False

--------------------------------------------------------------------------------
maybeDecodeMessage :: Decode a => ByteString -> Maybe a
maybeDecodeMessage bytes =
    case runGet decodeMessage bytes of
        Right a -> Just a
        _       -> Nothing
