{-# LANGUAGE DoAndIfThenElse #-}
-- ----------------------------------------------------------------------------
{- |
  Main module for the executable.
-}
-- ----------------------------------------------------------------------------

module Main where

import           Control.Applicative ((<$>))
import           Control.Monad (when)

import           Data.Aeson (encode, decode)
import           Data.Aeson.Encode.Pretty (encodePretty)
import           Data.ByteString.Lazy (ByteString)
import           Data.Char (toUpper)
import           Data.Map (keys)
import           Data.Maybe (fromJust)
import           Data.String.Conversions (cs)
import           Data.Time.Clock.POSIX (getPOSIXTime)

import           System.Console.Docopt (optionsWithUsage, getArg, isPresent, command, argument, longOption)
import           System.Environment (getArgs)

import qualified Hunt.Common.ApiDocument as H
import qualified Hunt.ClientInterface as H
import qualified Hunt.Server.Client as HC
import qualified Hunt.Converter.CSV as CSV (convert)

usage :: String
usage = unlines [
    "hunt-server-cli"
    , ""
    , "Usage:"
    , "  hunt-server-cli eval [--server SERVER] <file>"
    , "  hunt-server-cli load [--server SERVER] <file>"
    , "  hunt-server-cli store [--server SERVER] <file>"
    , "  hunt-server-cli search <query>"
    , "  hunt-server-cli completion <query>"
    , "  hunt-server-cli make-schema <file>"
    , "  hunt-server-cli from-csv <file>"
    , "  hunt-server-cli (-h | --help)"
    , ""
    , ""
    , "Options:"
    , "  -h --help           Show this screen."
    , "  --server=SERVER     Use this hunt server [default: http://localhost:3000]"
    , "  make-schema <file>  prints a simple schema for this document" ]

-- ------------------------------------------------------------

printTime :: IO a -> IO a
printTime act = do

  start <- getTime
  result <- act
  end <- getTime
  let delta = end - start
  putStrLn $ "took " ++ (show (delta))
  return result
  where
  getTime = getPOSIXTime -- realToFrac `fmap` 

makeSchema :: FilePath -> IO String
makeSchema fileName = do
  file <- readFile fileName
  let doc = (fromJust $ decode $ cs file ) :: H.ApiDocument
      names =  keys $ H.adIndex $ doc
      cmds = (\name -> H.cmdInsertContext name H.mkSchema) <$> names        
  return $ cs $ encodePretty cmds

evalCmd :: String -> H.Command -> IO ByteString
evalCmd server cmd = do
  HC.withHuntServer (HC.eval [cmd]) (cs server)

eval :: String -> FilePath -> IO ByteString
eval server fileName = do
  file <- readFile fileName
  evalCmd server $ fromJust $ decode $ cs file

search :: String -> String -> IO ByteString
search server query = do
  cs <$> (encodePretty :: H.LimitedResult H.ApiDocument -> ByteString) <$> (HC.withHuntServer (HC.query (cs query) 0 ) (cs server))


autocomplete :: String -> String -> IO String
autocomplete server query = do
  show <$> (HC.withHuntServer (HC.autocomplete $ cs query) (cs server))

-- | Main function for the executable.
main :: IO ()
main = do
  args <- optionsWithUsage usage =<< getArgs

  let isCommand str = args `isPresent` (command str)
      fileArgument = args `getArg` (argument "<file>")
      queryArgument = args `getArg` (argument "<query>")

  server <- do
      if (args `isPresent` (longOption "server")) then
          args `getArg` (longOption "server")
      else
          return "http://localhost:3000"

  when (isCommand "eval") $ do
    file <- fileArgument
    putStr =<< (printTime $ cs <$> eval server file)

  when (isCommand "load") $ do
    file <- fileArgument
    putStr =<< cs <$> (evalCmd server $ H.cmdLoadIndex file)

  when (isCommand "store") $ do
    file <- fileArgument
    putStr =<< cs <$> (evalCmd server $ H.cmdStoreIndex file)

  when (isCommand "search") $ do
    query <- queryArgument
    putStr =<< (printTime $ cs <$> search server query)

  when (isCommand "completion") $ do
    query <- queryArgument
    putStr =<< show <$> autocomplete server query 

  when (isCommand "from-csv") $ do
    CSV.convert =<< fileArgument

