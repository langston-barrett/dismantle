{-# LANGUAGE TupleSections #-}
module Dismantle.Testing.ParserTests (parserTests) where

import Control.DeepSeq (deepseq)
import Control.Monad (when)
import qualified Data.Text.IO as TS
import qualified Data.Text.Lazy as TL
import qualified Test.Tasty as T
import qualified Test.Tasty.HUnit as T
import qualified Dismantle.Testing.Regex as RE
import qualified System.FilePath.Glob as G
import System.Directory (canonicalizePath)
import System.Exit (die)
import System.FilePath (takeFileName)
import qualified Text.Regex.TDFA as TDFA

import qualified Dismantle.Tablegen as D
import qualified Dismantle.Tablegen.Parser.Types as D

parserTests :: IO T.TestTree
parserTests = do
  tgenFiles <- requireGlob "tgen files" "data/*.tgen"
  overrideTgenFiles <- mapM canonicalizePath =<< G.namesMatching "data/override/*.tgen"
  return $ T.testGroup "Parser" (map mkTest (tgenFiles <> overrideTgenFiles))

requireGlob :: String -> String -> IO [FilePath]
requireGlob ty pat = do
    paths <- mapM canonicalizePath =<< G.namesMatching pat
    when (null paths) $ do
        die $ "Error: could not find any " <> ty <> " matching " <> show pat
    return paths

mkTest :: FilePath -> T.TestTree
mkTest p = T.testCase (takeFileName p) $ do
  t <- TS.readFile p
  re <- TDFA.makeRegexM "^def "
  let expectedDefCount = RE.countMatches t re
  case D.parseTablegen p (TL.fromStrict t) of
    Left err ->
        let msg = "Error parsing " <> show p <> ": " <> err
        in T.assertFailure msg
    Right rs -> do
        rs `deepseq` return ()
        T.assertEqual ("Number of defs in " <> p) expectedDefCount (length (D.tblDefs rs))
