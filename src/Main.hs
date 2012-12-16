
module Main where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans
import Control.Error
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Map as Map

import System.Environment (getArgs)
import Control.Concurrent
import Control.Concurrent.STM
import Network.WebSockets
import qualified Data.Configurator as Cfg

import Avaya.Actions
import Avaya.MessageLoop
import Avaya.DeviceMonitoring
import qualified Avaya.Messages.Response as Rs
import qualified Avaya.Messages.Request as Rq


data Config = Config
  {listenPort :: Int
  ,aesAddr    :: Text
  ,aesPort    :: Int
  ,aesUser    :: Text
  ,aesPass    :: Text
  ,aesSwitch  :: Text
  }


main :: IO ()
main = getArgs >>= case of
  [config] -> realMain config
  _ -> putStrLn "Usage: avaya-ws <path to config>"


realMain :: FilePath -> IO ()
realMain config = do
  c <- Cfg.load [Cfg.Required config]
  cfg <- Config
      <$> Cfg.require c "listen-port"
      <*> Cfg.require c "aes-addr"
      <*> Cfg.require c "aes-port"
      <*> Cfg.require c "aes-user"
      <*> Cfg.require c "aes-pass"
      <*> Cfg.require c "aes-switch"

  connMap <- newTVarIO Map.empty
  runServer "0.0.0.0" (listenPort cfg)
    $ rqHandler cfg connMap


type AvayaMap
  = TVar (Map.Map
    (Text,Text)
    (LoopHandle,MonitoringHandle))

rqHandler :: Config -> AvayaMap -> Request -> WebSockets Hybi00 ()
rqHandler cfg cMapVar rq
  = case T.splitOn "/" . T.decodeUtf8 $ requestPath rq of
    ["","avaya",ext,pwd] -> do
      cMap <- liftIO $ readTVarIO cMapVar
      Right (h,m) <- case Map.lookup (ext,pwd) cMap of
        Just hm -> return $ Right hm
        Nothing -> startMonitoring cfg ext pwd rq
      liftIO $ atomically
        $ writeTVar cMapVar $! Map.insert (ext,pwd) (h,m) cMap

      acceptRequest rq
      s <- getSink
      liftIO $ attachObserver h $ evHandler s
      void $ runEitherT $ forever $ do
        msg <- lift receive
        case msg of
          ControlMessage (Close _) -> do
            liftIO $ do
              putStrLn $ "Sutdown session " ++ show (sessionId m)
              atomically $ modifyTVar' cMapVar $ Map.delete (ext,pwd)
              stopDeviceMonitoring h m
              shutdownLoop h
            left ()

          DataMessage (Text t) -> case L.split ':' t of
            ["dial", number] -> liftIO $ do
              sendRequestSync h
                $ Rq.SetHookswitchStatus
                  {acceptedProtocol = actualProtocolVersion m
                  ,device = deviceId m
                  ,hookswitchOnhook = False
                  }
              dialNumber h (actualProtocolVersion m) (deviceId m) (L.unpack number)

            ["acceptCall"]
              -> liftIO $ sendRequestAsync h
                $ Rq.SetHookswitchStatus
                  {acceptedProtocol = actualProtocolVersion m
                  ,device = deviceId m
                  ,hookswitchOnhook = False
                  }
            _ -> return ()
          _ -> return ()

    _ -> rejectRequest rq "401"


evHandler ws ev = case ev of
  AvayaRsp rsp -> case rsp of
    Rs.RingerStatusEvent{..} -> sendSink ws $ textData $ L.fromChunks
      ["{\"type\":\"ringer\",\"ringer\":\""
      ,T.encodeUtf8 ringMode
      ,"\"}"
      ]
    Rs.DisplayUpdatedEvent{..} -> sendSink ws $ textData $ L.fromChunks
      ["{\"type\":\"display\",\"display\":\""
      ,T.encodeUtf8 contentsOfDisplay
      ,"\"}"
      ]
    _ -> return ()
  _ -> return ()


-- startMonitoring :: Config -> Text -> Text -> Int -> Char
startMonitoring (Config{..}) ext pwd rq
  = (liftIO $ startMessageLoop aesAddr aesPort)
    >>= case of
      Left _ -> rejectRequest rq "Can't start session"
      Right h ->
        (liftIO $ startDeviceMonitoring h aesUser aesPass aesSwitch ext pwd)
          >>= case of
            Left _ -> rejectRequest rq "Can't register device"
            Right m -> return $ Right (h,m)
        -- liftIO $ attachObserver h print
