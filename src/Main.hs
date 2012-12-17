
module Main where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import qualified Data.ByteString.Lazy.Char8 as L
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Map as Map

import System.Environment (getArgs)
import Control.Concurrent
import Control.Concurrent.STM
import Network.WebSockets
import System.Posix.Syslog
import qualified Data.Configurator as Cfg

import Avaya.Actions
import Avaya.MessageLoop
import Avaya.DeviceMonitoring
import qualified Avaya.Messages.Response as Rs
import qualified Avaya.Messages.Request as Rq


data Config = Config
  {listenPort :: Int
  ,aesAddr    :: String
  ,aesPort    :: Int
  ,aesUser    :: Text
  ,aesPass    :: Text
  ,aesSwitch  :: Text
  }


main :: IO ()
main = getArgs >>= \case
  [config] -> realMain config
  _ -> putStrLn "Usage: avaya-ws <path to config>"


realMain :: FilePath -> IO ()
realMain config = do
  c <- Cfg.load [Cfg.Required config]
  cfg@(Config{..}) <- Config
      <$> Cfg.require c "listen-port"
      <*> Cfg.require c "aes-addr"
      <*> Cfg.require c "aes-port"
      <*> Cfg.require c "aes-user"
      <*> Cfg.require c "aes-pass"
      <*> Cfg.require c "aes-switch"

  withSyslog "avaya-ws" [PID] USER $ do
    syslog Notice $ "Starting server on port " ++ show listenPort
    connMap <- newTVarIO Map.empty
    runServer "0.0.0.0" listenPort $ rqHandler cfg connMap


type AvayaMap = TVar (Map.Map (Text,Text) (LoopHandle,MonitoringHandle))


chkRequestPath :: Request -> WebSockets Hybi00 (Text,Text)
chkRequestPath rq
  = case T.splitOn "/" rqPath of
    ["", "avaya", ext, pwd] -> return (ext, pwd)
    _ -> do
      liftIO $ syslog Warning $ "Invalid request: " ++ show rqPath
      rejectRequest rq "401"
  where
    rqPath = T.decodeUtf8 $ requestPath rq


getSession
  :: AvayaMap -> Config -> Text -> Text
  -> WebSockets Hybi00 (Either String (LoopHandle,MonitoringHandle))
getSession cMapVar cfg ext pwd = do
  cMap <- liftIO $ readTVarIO cMapVar
  -- check if session for (ext,pwd) already exists
  case Map.lookup (ext,pwd) cMap of
    Just hm -> return $ Right hm
    Nothing -> liftIO -- create new session
      $ startMonitoring cfg ext pwd
        >>= \case
          Left err -> return $ Left err
          Right (h,m) -> do -- update session map
            atomically $ writeTVar cMapVar -- FIXME: race condition
              $! Map.insert (ext,pwd) (h,m) cMap
            return $ Right (h,m)


rqHandler :: Config -> AvayaMap -> Request -> WebSockets Hybi00 ()
rqHandler cfg cMapVar rq = do
  (ext,pwd) <- chkRequestPath rq

  (h,m) <- getSession cMapVar cfg ext pwd
        >>= either
          (\err -> liftIO (syslog Warning err) >> rejectRequest rq "501")
          return

  acceptRequest rq
  s <- getSink
  o <- liftIO $ attachObserver h $ evHandler s

  let loop
        = receive >>= \case
          DataMessage (Text t) -> liftIO $ runCommand h m t
          _ -> return () -- FIXME: log

  let shutdown e = liftIO $ do
        syslog Notice $ "WsError catched: " ++ show e
        detachObserver h o

  catchWsError (forever loop) shutdown


runCommand :: LoopHandle -> MonitoringHandle -> L.ByteString -> IO ()
runCommand h m t = do
  syslog Notice $ "User command: " ++ show (t, deviceId m)
  case L.split ':' t of
    ["dial", number] -> do
      sendRequestSync h
        $ Rq.SetHookswitchStatus
          {acceptedProtocol = actualProtocolVersion m
          ,device = deviceId m
          ,hookswitchOnhook = False
          }
      dialNumber h (actualProtocolVersion m) (deviceId m) (L.unpack number)

    ["acceptCall"] -> do
      sendRequestAsync h
        $ Rq.SetHookswitchStatus
          {acceptedProtocol = actualProtocolVersion m
          ,device = deviceId m
          ,hookswitchOnhook = False
          }
    _ -> return ()


evHandler :: Sink Hybi00 -> LoopEvent -> IO ()
evHandler ws ev = case ev of
  AvayaRsp rsp -> case rsp of
    Rs.RingerStatusEvent{..} -> do
      syslog Notice $ show rsp
      sendSink ws $ textData $ L.fromChunks
        ["{\"type\":\"ringer\",\"ringer\":\""
        ,T.encodeUtf8 ringMode
        ,"\"}"
        ]
    Rs.DisplayUpdatedEvent{..} -> do
      syslog Notice $ show rsp
      sendSink ws $ textData $ L.fromChunks
        ["{\"type\":\"display\",\"display\":\""
        ,T.encodeUtf8 contentsOfDisplay
        ,"\"}"
        ]
    _ -> return ()
  _ -> return ()


startMonitoring
  :: Config -> Text -> Text
  -> IO (Either String (LoopHandle,MonitoringHandle))
startMonitoring (Config{..}) ext pwd
  = startMessageLoop aesAddr aesPort
    >>= \case
      Left err -> return $ Left "Can't start session"
      Right h  ->
        startDeviceMonitoring h aesUser aesPass aesSwitch ext pwd
          >>= \case
            Left err -> do
              shutdownLoop h
              return $ Left $ "Can't register device: " ++ show err
            Right m  -> do
              syslog Notice $ "Just started new session for " ++ show (ext,pwd)
              return $ Right (h,m)
