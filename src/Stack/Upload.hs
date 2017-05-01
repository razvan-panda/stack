{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Provide ability to upload tarballs to Hackage.
module Stack.Upload
    ( -- * Upload
      nopUploader
    , mkUploader
    , Uploader
    , upload
    , uploadBytes
    , uploadRevision
    , UploadSettings
    , defaultUploadSettings
    , setUploadUrl
    , setCredsSource
    , setSaveCreds
      -- * Credentials
    , HackageCreds
    , loadCreds
    , saveCreds
    , FromFile
      -- ** Credentials source
    , HackageCredsSource
    , fromAnywhere
    , fromPrompt
    , fromFile
    , fromMemory
    ) where

import           Control.Applicative
import           Control.Exception                     (bracket)
import qualified Control.Exception                     as E
import           Control.Monad                         (when, void)
import           Data.Aeson                            (FromJSON (..),
                                                        ToJSON (..),
                                                        eitherDecode', encode,
                                                        object, withObject,
                                                        (.:), (.=))
import qualified Data.ByteString.Char8                 as S
import qualified Data.ByteString.Lazy                  as L
import           Data.Conduit                          (ConduitM, runConduit, (.|))
import qualified Data.Conduit.Binary                   as CB
import           Data.Text                             (Text)
import qualified Data.Text                             as T
import           Data.Text.Encoding                    (encodeUtf8)
import qualified Data.Text.IO                          as TIO
import           Data.Typeable                         (Typeable)
import           Network.HTTP.Client                   (Response,
                                                        RequestBody(RequestBodyLBS),
                                                        Request)
import           Network.HTTP.Simple                   (withResponse,
                                                        getResponseStatusCode,
                                                        getResponseBody,
                                                        setRequestHeader,
                                                        parseRequest,
                                                        httpNoBody)
import           Network.HTTP.Client.MultipartFormData (formDataBody, partFileRequestBody,
                                                        partBS, partLBS)
import           Network.HTTP.Client.TLS               (getGlobalManager,
                                                        applyDigestAuth,
                                                        displayDigestAuthException)
import           Path                                  (toFilePath)
import           Prelude -- Fix redundant import warnings
import           Stack.Types.Config
import           Stack.Types.PackageIdentifier         (PackageIdentifier, packageIdentifierString,
                                                        packageIdentifierName)
import           Stack.Types.PackageName               (packageNameString)
import           Stack.Types.StringError
import           System.Directory                      (createDirectoryIfMissing,
                                                        removeFile)
import           System.FilePath                       ((</>), takeFileName)
import           System.IO                             (hFlush, hGetEcho, hSetEcho,
                                                        stdin, stdout)

-- | Username and password to log into Hackage.
--
-- Since 0.1.0.0
data HackageCreds = HackageCreds
    { hcUsername :: !Text
    , hcPassword :: !Text
    }
    deriving Show

instance ToJSON HackageCreds where
    toJSON (HackageCreds u p) = object
        [ "username" .= u
        , "password" .= p
        ]
instance FromJSON HackageCreds where
    parseJSON = withObject "HackageCreds" $ \o -> HackageCreds
        <$> o .: "username"
        <*> o .: "password"

-- | A source for getting Hackage credentials.
--
-- Since 0.1.0.0
newtype HackageCredsSource = HackageCredsSource
    { getCreds :: IO (HackageCreds, FromFile)
    }

-- | Whether the Hackage credentials were loaded from a file.
--
-- This information is useful since, typically, you only want to save the
-- credentials to a file if it wasn't already loaded from there.
--
-- Since 0.1.0.0
type FromFile = Bool

-- | Load Hackage credentials from the given source.
--
-- Since 0.1.0.0
loadCreds :: HackageCredsSource -> IO (HackageCreds, FromFile)
loadCreds = getCreds

-- | Save the given credentials to the credentials file.
--
-- Since 0.1.0.0
saveCreds :: Config -> HackageCreds -> IO ()
saveCreds config creds = do
    fp <- credsFile config
    L.writeFile fp $ encode creds

-- | Load the Hackage credentials from the prompt, asking the user to type them
-- in.
--
-- Since 0.1.0.0
fromPrompt :: HackageCredsSource
fromPrompt = HackageCredsSource $ do
    putStr "Hackage username: "
    hFlush stdout
    username <- TIO.getLine
    password <- promptPassword
    return (HackageCreds
        { hcUsername = username
        , hcPassword = password
        }, False)

credsFile :: Config -> IO FilePath
credsFile config = do
    let dir = toFilePath (configStackRoot config) </> "upload"
    createDirectoryIfMissing True dir
    return $ dir </> "credentials.json"

-- | Load the Hackage credentials from the JSON config file.
--
-- Since 0.1.0.0
fromFile :: Config -> HackageCredsSource
fromFile config = HackageCredsSource $ do
    fp <- credsFile config
    lbs <- L.readFile fp
    case eitherDecode' lbs of
        Left e -> E.throwIO $ Couldn'tParseJSON fp e
        Right creds -> return (creds, True)

-- | Load the Hackage credentials from the given arguments.
--
-- Since 0.1.0.0
fromMemory :: Text -> Text -> HackageCredsSource
fromMemory u p = HackageCredsSource $ return (HackageCreds
    { hcUsername = u
    , hcPassword = p
    }, False)

data HackageCredsExceptions = Couldn'tParseJSON FilePath String
    deriving (Show, Typeable)
instance E.Exception HackageCredsExceptions

-- | Try to load the credentials from the config file. If that fails, ask the
-- user to enter them.
--
-- Since 0.1.0.0
fromAnywhere :: Config -> HackageCredsSource
fromAnywhere config = HackageCredsSource $
    getCreds (fromFile config) `E.catches`
        [ E.Handler $ \(_ :: E.IOException) -> getCreds fromPrompt
        , E.Handler $ \(_ :: HackageCredsExceptions) -> getCreds fromPrompt
        ]

-- | Lifted from cabal-install, Distribution.Client.Upload
promptPassword :: IO Text
promptPassword = do
  putStr "Hackage password: "
  hFlush stdout
  -- save/restore the terminal echoing status
  passwd <- bracket (hGetEcho stdin) (hSetEcho stdin) $ \_ -> do
    hSetEcho stdin False  -- no echoing for entering the password
    fmap T.pack getLine
  putStrLn ""
  return passwd

nopUploader :: Config -> UploadSettings -> IO Uploader
nopUploader _ _ = return (Uploader nop)
  where nop :: String -> L.ByteString -> IO HackageCreds
        nop _ _ = return (HackageCreds "nopUploader" "")

applyCreds :: HackageCreds -> Request -> IO Request
applyCreds creds req0 = do
  manager <- getGlobalManager
  ereq <- applyDigestAuth
    (encodeUtf8 $ hcUsername creds)
    (encodeUtf8 $ hcPassword creds)
    req0
    manager
  case ereq of
      Left e -> do
          putStrLn "WARNING: No HTTP digest prompt found, this will probably fail"
          case E.fromException e of
              Just e' -> putStrLn $ displayDigestAuthException e'
              Nothing -> print e
          return req0
      Right req -> return req

-- | Turn the given settings into an @Uploader@.
--
-- Since 0.1.0.0
mkUploader :: Config -> UploadSettings -> IO Uploader
mkUploader config us = do
    (creds, fromFile') <- loadCreds $ usCredsSource us config
    when (not fromFile' && usSaveCreds us) $ saveCreds config creds
    req0 <- parseRequest $ usUploadUrl us
    let req1 = setRequestHeader "Accept" ["text/plain"] req0
    return Uploader
        { upload_ = \tarName bytes -> do
            let formData = [partFileRequestBody "package" tarName (RequestBodyLBS bytes)]
            req2 <- formDataBody formData req1
            req3 <- applyCreds creds req2
            putStr $ "Uploading " ++ tarName ++ "... "
            hFlush stdout
            withResponse req3 $ \res ->
                case getResponseStatusCode res of
                    200 -> putStrLn "done!"
                    401 -> do
                        putStrLn "authentication failure"
                        cfp <- credsFile config
                        handleIO (const $ return ()) (removeFile cfp)
                        throwString "Authentication failure uploading to server"
                    403 -> do
                        putStrLn "forbidden upload"
                        putStrLn "Usually means: you've already uploaded this package/version combination"
                        putStrLn "Ignoring error and continuing, full message from Hackage below:\n"
                        printBody res
                    503 -> do
                        putStrLn "service unavailable"
                        putStrLn "This error some times gets sent even though the upload succeeded"
                        putStrLn "Check on Hackage to see if your pacakge is present"
                        printBody res
                    code -> do
                        putStrLn $ "unhandled status code: " ++ show code
                        printBody res
                        throwString $ "Upload failed on " ++ tarName
            return creds
        }

printBody :: Response (ConduitM () S.ByteString IO ()) -> IO ()
printBody res = runConduit $ getResponseBody res .| CB.sinkHandle stdout

-- | The computed value from a @UploadSettings@.
--
-- Typically, you want to use this with 'upload'.
--
-- Since 0.1.0.0
newtype Uploader = Uploader
    { upload_ :: String -> L.ByteString -> IO HackageCreds
    }

-- | Upload a single tarball with the given @Uploader@.
--
-- Since 0.1.0.0
upload :: Uploader -> FilePath -> IO HackageCreds
upload uploader fp = upload_ uploader (takeFileName fp) =<< L.readFile fp

-- | Upload a single tarball with the given @Uploader@.  Instead of
-- sending a file like 'upload', this sends a lazy bytestring.
--
-- Since 0.1.2.1
uploadBytes :: Uploader -> String -> L.ByteString -> IO HackageCreds
uploadBytes = upload_

uploadRevision :: HackageCreds
               -> PackageIdentifier
               -> L.ByteString
               -> IO ()
uploadRevision creds ident cabalFile = do
  req0 <- parseRequest $ concat
    [ "https://hackage.haskell.org/package/"
    , packageIdentifierString ident
    , "/"
    , packageNameString $ packageIdentifierName ident
    , ".cabal/edit"
    ]
  req1 <- formDataBody
    [ partLBS "cabalfile" cabalFile
    , partBS "publish" "on"
    ]
    req0
  req2 <- applyCreds creds req1
  void $ httpNoBody req2

-- | Settings for creating an @Uploader@.
--
-- Since 0.1.0.0
data UploadSettings = UploadSettings
    { usUploadUrl   :: !String
    , usCredsSource :: !(Config -> HackageCredsSource)
    , usSaveCreds   :: !Bool
    }

-- | Default value for @UploadSettings@.
--
-- Use setter functions to change defaults.
--
-- Since 0.1.0.0
defaultUploadSettings :: UploadSettings
defaultUploadSettings = UploadSettings
    { usUploadUrl = "https://hackage.haskell.org/packages/"
    , usCredsSource = fromAnywhere
    , usSaveCreds = True
    }

-- | Change the upload URL.
--
-- Default: "https://hackage.haskell.org/packages/"
--
-- Since 0.1.0.0
setUploadUrl :: String -> UploadSettings -> UploadSettings
setUploadUrl x us = us { usUploadUrl = x }

-- | How to get the Hackage credentials.
--
-- Default: @fromAnywhere@
--
-- Since 0.1.0.0
setCredsSource :: (Config -> HackageCredsSource) -> UploadSettings -> UploadSettings
setCredsSource x us = us { usCredsSource = x }

-- | Save new credentials to the config file.
--
-- Default: @True@
--
-- Since 0.1.0.0
setSaveCreds :: Bool -> UploadSettings -> UploadSettings
setSaveCreds x us = us { usSaveCreds = x }

handleIO :: (E.IOException -> IO a) -> IO a -> IO a
handleIO = E.handle
