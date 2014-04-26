{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
import Control.Arrow
import Control.Monad.Trans.Error
import Data.Traversable (sequenceA)
import Data.String.Utils
import Data.Yaml
import Distribution.Hackage.DB (readHackage)
import Distribution.Package -- TODO Remove
import Distribution.PackageDescription
import Distribution.PackageDescription.Parse
import Distribution.Text
import Distribution.Verbosity
import GHC.Generics
import System.Directory
import System.Environment
import System.FilePath

import qualified Data.List as List

import Distribution.Hackage.Utils

import Codex

-- TODO Add command to clean cache
-- TODO Make dependency resolution depth configurable (and try without limit)
-- TODO Replace Error with EitherT
-- TODO Make Async
-- TODO Make verbosity configurable

retrying :: Int -> IO (Either a b) -> IO (Either [a] b)
retrying n x = retrying' n $ fmap (left (:[])) x where
  retrying' 0 x = x
  retrying' n x = retrying' (n - 1) $ x >>= \res -> case res of
    Left ls -> fmap (left (++ ls)) x
    Right r -> return $ Right r

-- TODO Better error handling and fine grained retry
update :: Codex -> IO ()
update cx = resolve =<< getCurrentProject where
  resolve Nothing = putStrLn "No cabal file found."
  resolve (Just project) = do
    putStrLn $ concat ["Updating ", display . identifier $ project]
    dependencies <- fmap (\db -> resolveDependencies db project) readHackage
    founds <- retrying 4 . runErrorT . sequence $ fmap (getTags . identifier) dependencies 
    failOr (generate dependencies) founds where
      identifier = package . packageDescription
      -- TODO Add println of info (use verbosity)
      getTags i = status cx i >>= \x -> case x of
        (Source Tagged)   -> return ()
        (Source Untagged) -> tags cx i >>= (const $ getTags i)
        (Archive)         -> extract cx i >>= (const $ getTags i)
        (Remote)          -> fetch cx i >>= (const $ getTags i)
      generate xs = do 
        res <- runErrorT $ assembly cx (fmap identifier xs) (joinPath ["codex.tags"])
        failOr (return ()) res
      failOr y x = either (putStrLn . show) (const y) x

getCurrentProject :: IO (Maybe GenericPackageDescription)
getCurrentProject = do
  files <- getDirectoryContents $ joinPath ["."]
  sequenceA . fmap (readPackageDescription silent) $ List.find (endswith ".cabal") files

main :: IO ()
main = do
  cx   <- loadConfig
  args  <- getArgs
  run cx args where
    run cx ["update"] = update cx
    run cx ["set", "tagger", "ctags"]     = encodeConfig $  cx { tagsCmd = taggerCmd Ctags }
    run cx ["set", "tagger", "hasktags"]  = encodeConfig $  cx { tagsCmd = taggerCmd Hasktags }
    run cx _          = putStrLn "Usage: codex [update|set tagger [ctags|hasktags]]"

loadConfig :: IO Codex
loadConfig = decodeConfig >>= maybe defaultConfig return where
  defaultConfig = do
    hp <- getHackagePath
    let cx = Codex (taggerCmd Hasktags) hp
    encodeConfig cx
    return cx

deriving instance Generic Codex
instance ToJSON Codex
instance FromJSON Codex

encodeConfig :: Codex -> IO ()
encodeConfig cx = do
  path <- getConfigPath
  encodeFile path cx

decodeConfig :: IO (Maybe Codex)
decodeConfig = do
  path  <- getConfigPath
  res   <- decodeFileEither path
  return $ either (const Nothing) Just res 

getConfigPath :: IO FilePath
getConfigPath = do
  homedir <- getHomeDirectory
  return $ joinPath [homedir, ".codex"]
