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
import Control.Monad (forever, when)
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
  , exchangeRequest :: Package
  }

--------------------------------------------------------------------------------
type Reg = HashMap UUID Exchange

--------------------------------------------------------------------------------
data DriverState
  = Init
  | Awaiting [Package] ConnectingState
  | Active ConnectionId Reg
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

--------------------------------------------------------------------------------
process :: Members [Reader Settings, Input Msg, Output Transmission, Driver] r => Sem r ()
process = forever (input >>= react)

--------------------------------------------------------------------------------
react :: Members [Reader Settings, Output Transmission, Driver] r => Msg -> Sem r ()
react SystemInit = do
  setStage (Connecting Reconnecting)
  discovery
react (EstablishConnection ept) = establish ept
react (ConnectionEstablished connId) = established connId
react (PackageArrived connId pkg) = packageArrived connId pkg
react (SendPackage pkg) = sendPackage pkg

--------------------------------------------------------------------------------
react' :: Members '[Reader Settings, Output Transmission, Driver] r
       => DriverState
       -> Msg
       -> Sem r DriverState
react' s SystemInit = discovery' s
react' s (EstablishConnection ept) = establish' s ept
react' s (ConnectionEstablished cid) = established' s cid

--------------------------------------------------------------------------------
discovery :: Members '[Driver] r => Sem r ()
discovery = getStage >>= \case
  Connecting state ->
    case state of
      Reconnecting{} -> discover
      _ -> pure ()
  _ -> pure ()

--------------------------------------------------------------------------------
discovery' :: Members '[Driver] r
           => DriverState
           -> Sem r DriverState
discovery' = \case
  Init ->
    discovery' (Awaiting [] Reconnecting)

  Awaiting pkgs Reconnecting ->
    Awaiting pkgs EndpointDiscovery <$ discover

  s -> pure s

--------------------------------------------------------------------------------
establish :: Members '[Driver] r => EndPoint -> Sem r ()
establish ept = getStage >>= \case
  Connecting state ->
    case state of
      EndpointDiscovery -> do
        cid <- connect ept
        setStage $ Connecting (ConnectionEstablishing cid)
      _ -> pure ()
  _ -> pure ()

--------------------------------------------------------------------------------
establish' :: Members '[Driver] r
           => DriverState
           -> EndPoint
           -> Sem r DriverState
establish' (Awaiting pkgs EndpointDiscovery) ept =
  Awaiting pkgs . ConnectionEstablishing <$> connect ept
establish' s _ = pure s

--------------------------------------------------------------------------------
established :: Members '[Reader Settings, Driver] r
            => ConnectionId
            -> Sem r ()
established connId = getStage >>= \case
  Connecting (ConnectionEstablishing known) ->
    when (connId == known) $ do
      setts <- ask
      case s_defaultUserCredentials setts of
        Just cred -> undefined --authenticate cred known
        Nothing   -> undefined --identifyClient known
  _ -> pure ()

--------------------------------------------------------------------------------
established' :: Members '[Reader Settings, Driver, Output Transmission] r
             => DriverState
             -> ConnectionId
             -> Sem r DriverState
established' s@(Awaiting pkgs (ConnectionEstablishing known)) cid
  | cid == known = do
    setts <- ask
    elapsed <- getElapsedTime

    case s_defaultUserCredentials setts of
      Just cred -> do
        pkg <- createAuthenticatePkg cred

        let uuid = packageCorrelation pkg

        output (Send pkg)
        pure (Awaiting pkgs (Authentication cid (PackageId uuid) elapsed))

      Nothing -> do
        pkg <- identifyClient setts

        let uuid = packageCorrelation pkg

        output (Send pkg)
        pure (Awaiting pkgs (Identification cid (PackageId uuid) elapsed))

  | otherwise = pure s
established' s _ = pure s

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
clientIdentified :: Members '[Driver] r
                 => ConnectionId
                 -> Sem r ()
clientIdentified connId = getStage >>= \case
  Connecting (Identification known _ _)
    | known == connId -> do
      setStage (Connected connId)
      -- TODO - OperationCheck !!!!
    | otherwise -> pure ()
  _ -> pure ()

--------------------------------------------------------------------------------
packageArrived :: Members '[Reader Settings, Output Transmission, Driver] r
               => ConnectionId
               -> Package
               -> Sem r ()
packageArrived connId pkg = do
  stage <- getStage

  case lookupConnectionId stage of
    Just known
      | connId /= known -> ignored
      | otherwise ->
        if cmd == heartbeatRequestCmd
          then output (Send heartbeatResponse)
          else if cmd == heartbeatResponseCmd
            then pure ()
            else go stage

    Nothing -> ignored

  where
    cmd = packageCmd pkg
    correlation = packageCorrelation pkg

    heartbeatResponse = heartbeatResponsePackage $ packageCorrelation pkg

    go = \case
      Connecting state ->
        case state of
          Identification _ pkgId _
            | PackageId (packageCorrelation pkg) == pkgId
                && cmd == clientIdentifiedCmd
              -> clientIdentified connId
            | otherwise -> ignored

          Authentication _ pkgId _
            | PackageId (packageCorrelation pkg) == pkgId
                && authPkg -> undefined --identifyClient connId
            | otherwise -> ignored

          _ -> ignored

      Connected{} -> do
        mapped <- isMapped correlation
        if mapped
          then
            case cmd of
              _ | cmd == badRequestCmd -> do
                  let reason = packageDataAsText pkg
                      badNews =
                        BadNews
                        { badNewsId = correlation
                        , badNewsError = ServerError reason
                        }

                  output $ Recv (Left badNews)

                | cmd == notAuthenticatedCmd -> do
                  let badNews =
                        BadNews
                        { badNewsId = correlation
                        , badNewsError = NotAuthenticatedOp
                        }

                  output $ Recv (Left badNews)

                | cmd == notHandledCmd -> do
                  let Just msg = maybeDecodeMessage (packageData pkg)
                      reason   = getField $ notHandledReason msg

                  case reason of
                    N_NotMaster -> do
                      let Just details = getField $ notHandledAdditionalInfo msg
                          info         = masterInfo details
                          node         = masterInfoNodeEndPoints info

                      setStage . Connecting . ConnectionEstablishing =<<
                        forceReconnect correlation node

                    -- In this case with just retry the operation.
                    _ -> restart correlation
                | otherwise -> output $ Recv (Right pkg)
          else ignored

      _ -> ignored

    lookupConnectionId = \case
      Connected cid -> Just cid
      Connecting state ->
        case state of
          Authentication cid _ _ -> Just cid
          Identification cid _ _ -> Just cid
          _ -> Nothing
      _ -> Nothing

    authPkg = cmd == authenticatedCmd || cmd == notAuthenticatedCmd

    ignored = output (Ignored pkg)

--------------------------------------------------------------------------------
sendPackage :: Members '[Driver, Output Transmission] r
            => Package
            -> Sem r ()
sendPackage pkg = getStage >>= \case
  -- Closed ->
  --   let badNews =
  --         BadNews
  --         { badNewsId = packageCorrelation pkg
  --         , badNewsError = Aborted
  --         } in

  --   output $ Recv (Left badNews)

  _ -> register pkg

--------------------------------------------------------------------------------
maybeDecodeMessage :: Decode a => ByteString -> Maybe a
maybeDecodeMessage bytes =
    case runGet decodeMessage bytes of
        Right a -> Just a
        _       -> Nothing
