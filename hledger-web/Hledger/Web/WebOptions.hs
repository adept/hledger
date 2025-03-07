{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Hledger.Web.WebOptions where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.UTF8 (fromString)
import Data.Default (Default(def))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import GitHash (tGitInfoCwdTry)
import System.Environment (getArgs)
import Network.Wai as WAI
import Network.Wai.Middleware.Cors
import Safe (lastMay)

import Hledger.Cli hiding (packageversion, progname, prognameandversion)
import Hledger.Web.Settings (defhost, defport, defbaseurl)
import qualified Data.Text as T
import Data.Char (toLower)
import Data.List (isPrefixOf)

-- cf Hledger.Cli.Version

packageversion :: PackageVersion
packageversion =
#ifdef VERSION
  VERSION
#else
  ""
#endif

-- | The name of this program's executable.
progname :: ProgramName
progname = "hledger-web"

-- | Generate the version string for this program.
-- The template haskell call is here rather than in Hledger.Cli.Version to avoid wasteful recompilation.
prognameandversion :: String
prognameandversion =
  versionStringWith
  $$tGitInfoCwdTry
#ifdef GHCDEBUG
  True
#else
  False
#endif
  progname
  packageversion

webflags :: [Flag RawOpts]
webflags =
  [ flagNone
      ["serve", "server"]
      (setboolopt "serve")
      "serve and log requests, don't browse or auto-exit"
  , flagNone
      ["serve-api"]
      (setboolopt "serve-api")
      "like --serve, but serve only the JSON web API, not the web UI"
  , flagReq
      ["allow"]
      (\s opts -> Right $ setopt "allow" s opts)
      "view|add|edit"
      "set the user's access level for changing data (default: `add`). It also accepts `sandstorm` for use on that platform (reads permissions from the `X-Sandstorm-Permissions` request header)."
  , flagReq
      ["cors"]
      (\s opts -> Right $ setopt "cors" s opts)
      "ORIGIN"
      ("allow cross-origin requests from the specified origin; setting ORIGIN to \"*\" allows requests from any origin")
  , flagReq
      ["host"]
      (\s opts -> Right $ setopt "host" s opts)
      "IPADDR"
      ("listen on this IP address (default: " ++ defhost ++ ")")
  , flagReq
      ["port"]
      (\s opts -> Right $ setopt "port" s opts)
      "PORT"
      ("listen on this TCP port (default: " ++ show defport ++ ")")
  , flagReq
      ["socket"]
      (\s opts -> Right $ setopt "socket" s opts)
      "SOCKET"
      "listen on the given unix socket instead of an IP address and port (unix only; implies --serve)"
  , flagReq
      ["base-url"]
      (\s opts -> Right $ setopt "base-url" s opts)
      "BASEURL"
      "set the base url (default: http://IPADDR:PORT)"
  -- XXX #2139
  -- , flagReq
  --     ["file-url"]
  --     (\s opts -> Right $ setopt "file-url" s opts)
  --     "FILEURL"
  --     "set a different base url for static files (default: `BASEURL/static/`)"
  , flagNone
      ["test"]
      (setboolopt "test")
      "run hledger-web's tests and exit. hspec test runner args may follow a --, eg: hledger-web --test -- --help"
  ]

webmode :: Mode RawOpts
webmode =
  (mode
     "hledger-web"
     (setopt "command" "web" def)
     "start serving the hledger web interface"
     (argsFlag "[PATTERNS]")
     [])
  { modeGroupFlags =
      Group
      { groupUnnamed = webflags
      , groupHidden = hiddenflags
      , groupNamed = mkgeneralflagsgroups1 helpflags
      }
  , modeHelpSuffix = []
  }

-- hledger-web options, used in hledger-web and above
data WebOpts = WebOpts
  { serve_              :: !Bool
  , serve_api_          :: !Bool
  , cors_               :: !(Maybe String)
  , host_               :: !String
  , port_               :: !Int
  , base_url_           :: !String
  , file_url_           :: !(Maybe String)
  , allow_              :: !AccessLevel
  , cliopts_            :: !CliOpts
  , socket_             :: !(Maybe String)
  } deriving (Show)

defwebopts :: WebOpts
defwebopts = WebOpts
  { serve_              = False
  , serve_api_          = False
  , cors_               = Nothing
  , host_               = ""
  , port_               = def
  , base_url_           = ""
  , file_url_           = Nothing
  , allow_              = AddAccess
  , cliopts_            = def
  , socket_             = Nothing
  }

instance Default WebOpts where def = defwebopts

rawOptsToWebOpts :: RawOpts -> IO WebOpts
rawOptsToWebOpts rawopts =
  checkWebOpts <$> do
    cliopts <- rawOptsToCliOpts rawopts
    let
      h = fromMaybe defhost $ maybestringopt "host" rawopts
      p = fromMaybe defport $ maybeposintopt "port" rawopts
      -- Always set a base-url, constructing it from host and port if not specified.
      -- This will be used when opening a web browser, eg.
      -- App.hs approot will use it if it was specified by --base-url,
      -- otherwise it will infer a better one from the request, which browsers prefer.
      b = maybe (defbaseurl h p) stripTrailingSlash $ maybestringopt "base-url" rawopts
      sock = stripTrailingSlash <$> maybestringopt "socket" rawopts
      access =
        case lastMay $ listofstringopt "allow" rawopts of
          Nothing -> AddAccess
          Just t ->
            case parseAccessLevel t of
              Right al -> al
              Left err -> error' ("Unknown access level: " ++ err)  -- PARTIAL:
    return
      defwebopts
      { serve_ = case sock of
          Just _ -> True
          Nothing -> boolopt "serve" rawopts
      , serve_api_ = boolopt "serve-api" rawopts
      , cors_ = maybestringopt "cors" rawopts
      , host_ = h
      , port_ = p
      , base_url_ = b
      , file_url_ = stripTrailingSlash <$> maybestringopt "file-url" rawopts
      , allow_ = access
      , cliopts_ = cliopts
      , socket_ = sock
      }
  where
    stripTrailingSlash = reverse . dropWhile (== '/') . reverse -- yesod don't like it

checkWebOpts :: WebOpts -> WebOpts
checkWebOpts wopts@WebOpts{..}
  | not $ null base_url_ || "http://" `isPrefixOf` base_url_ || "https://" `isPrefixOf` base_url_ =
      error' "please begin the --base-url value with http:// or https://"
  | otherwise = wopts

getHledgerWebOpts :: IO WebOpts
getHledgerWebOpts = do
  args <- fmap (ensureDebugFlagHasVal . replaceNumericFlags) . expandArgsAt =<< getArgs
  rawOptsToWebOpts . either usageError id $ process webmode args

data Permission
  = ViewPermission  -- ^ allow viewing things (read only)
  | AddPermission   -- ^ allow adding transactions, or more generally allow appending text to input files 
  | EditPermission  -- ^ allow editing input files
  deriving (Eq, Ord, Bounded, Enum, Show)

parsePermission :: ByteString -> Either Text Permission
parsePermission "view" = Right ViewPermission
parsePermission "add"  = Right AddPermission
parsePermission "edit" = Right EditPermission
parsePermission x = Left $ T.pack $ BC.unpack x

-- | Convert to the lower case permission name.
showPermission :: Permission -> String
showPermission p = map toLower $ reverse $ drop 10 $ reverse $ show p

-- | For the --allow option: how much access to allow to hledger-web users ?
data AccessLevel =
    ViewAccess       -- ^ view permission only
  | AddAccess        -- ^ view and add permissions
  | EditAccess       -- ^ view, add and edit permissions
  | SandstormAccess  -- ^ the permissions specified by the X-Sandstorm-Permissions HTTP request header
  deriving (Eq, Ord, Bounded, Enum, Show)

parseAccessLevel :: String -> Either String AccessLevel
parseAccessLevel "view"      = Right ViewAccess
parseAccessLevel "add"       = Right AddAccess
parseAccessLevel "edit"      = Right EditAccess
parseAccessLevel "sandstorm" = Right SandstormAccess
parseAccessLevel s = Left $ s <> ", should be one of: view, add, edit, sandstorm"

-- | Convert an --allow access level to the permissions used internally.
-- SandstormAccess generates an empty list, to be filled in later.
accessLevelToPermissions :: AccessLevel -> [Permission]
accessLevelToPermissions ViewAccess      = [ViewPermission]
accessLevelToPermissions AddAccess       = [ViewPermission, AddPermission]
accessLevelToPermissions EditAccess      = [ViewPermission, AddPermission, EditPermission]
accessLevelToPermissions SandstormAccess = []  -- detected from request header

simplePolicyWithOrigin :: Origin -> CorsResourcePolicy
simplePolicyWithOrigin origin =
    simpleCorsResourcePolicy { corsOrigins = Just ([origin], False) }

corsPolicyFromString :: String -> WAI.Middleware
corsPolicyFromString origin =
  let
    policy = case origin of
        "*" -> simpleCorsResourcePolicy
        url -> simplePolicyWithOrigin $ fromString url
  in
    cors (const $ Just policy)

corsPolicy :: WebOpts -> (Application -> Application)
corsPolicy opts =
  maybe id corsPolicyFromString $ cors_ opts
