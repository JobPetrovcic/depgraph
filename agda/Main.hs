{-# LANGUAGE OverloadedStrings, DeriveGeneric, DeriveAnyClass #-}
-- | Agda with one extra backend, @--depgraph@, that writes the dependency
-- graph of the checked modules in the depgraph format (../FORMAT.md).
module Main (main) where

import Control.DeepSeq (NFData)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (object, encode, (.=))
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Char (isSpace)
import Data.List (isPrefixOf, isSuffixOf)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text.Lazy as TL
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing, getCurrentDirectory, listDirectory, removeFile)
import System.FilePath

import Agda.Main (runAgda)
import Agda.Compiler.Backend
import Agda.Compiler.Common (curIF)
import Agda.Interaction.FindFile (findFile)
import Agda.Interaction.Options (ArgDescr (..), OptDescr (..))
import Agda.Syntax.Common.Pretty (prettyShow)
import Agda.Syntax.Internal.Names (namesIn)
import Agda.Syntax.Position
import Agda.Utils.FileName (filePath)
import qualified Agda.Utils.Maybe.Strict as Strict

main :: IO ()
main = runAgda [depgraphBackend]

data Opts = Opts { optEnabled :: Bool, optDir :: FilePath }
  deriving (Generic, NFData)

depgraphBackend :: Backend
depgraphBackend = Backend Backend'
  { backendName           = "depgraph"
  , backendVersion        = Nothing
  , options               = Opts False "_depgraph"
  , commandLineFlags      =
      [ Option [] ["depgraph"] (NoArg $ \o -> pure o { optEnabled = True })
          "write the dependency graph in the depgraph format"
      , Option [] ["depgraph-dir"] (ReqArg (\d o -> pure o { optDir = d }) "DIR")
          "directory for the depgraph files (default: _depgraph)" ]
  , isEnabled             = optEnabled
  , preCompile            = liftIO . start . optDir
  , preModule             = \_ _ _ _ -> pure (Recompile ())
  , compileDef            = \_ _ _ def -> pure def
  , postModule            = \dir _ _ m defs -> writeModule dir m defs
  , postCompile           = \_ _ _ -> pure ()
  , scopeCheckingSuffices = False
  , mayEraseType          = \_ -> pure False
  , backendInteractTop    = Nothing
  , backendInteractHole   = Nothing
  }

-- | Empty the output directory and write the header.
start :: FilePath -> IO FilePath
start dir = do
  createDirectoryIfMissing True dir
  old <- filter (".jsonl" `isSuffixOf`) <$> listDirectory dir
  mapM_ (removeFile . (dir </>)) old
  cwd <- getCurrentDirectory
  libs <- filter (".agda-lib" `isSuffixOf`) <$> listDirectory cwd
  names <- concat <$> mapM (fmap libName . readFile) libs
  let name = foldr const (takeFileName cwd) names
  BL.writeFile (dir </> "_header.jsonl") $
    encode (object ["depgraph" .= (1 :: Int), "library" .= name]) <> "\n"
  pure dir
  where
    libName s = [trim (drop 5 l) | l <- lines s, "name:" `isPrefixOf` l]

-- | Write DIR/<module>.jsonl: the module line and its declarations.
writeModule :: FilePath -> TopLevelModuleName -> [Definition] -> TCM ()
writeModule dir m defs = do
  file <- srcFilePath =<< findFile m
  src <- TL.unpack . iSource <$> curIF
  let modName = prettyShow m
      -- with-functions and lambdas are not shown: their uses count as their users'
      generated d = isWithFunction (theDef d) || isExtendedLambda (theDef d)
                    || isAbsurdLambdaName (defName d)
      helpers = Map.fromList [(defName d, names d) | d <- defs, generated d]
      expand seen = foldMap $ \q -> case Map.lookup q helpers of
        Just s | q `Set.notMember` seen -> expand (Set.insert q seen) s
        Just _  -> Set.empty
        Nothing -> Set.singleton q
      names d = namesIn (defType d) <> namesIn (theDef d) :: Set.Set QName
      uses d = Set.delete (defName d) (expand Set.empty (names d))
      decls = [(d, k) | d <- defs, not (generated d), Just k <- [kind (theDef d)]]
      starts = Map.fromList
        [ (defName d, fromIntegral (posLine p) :: Int)
        | (d, _) <- decls
        , let r = nameBindingSite (qnameName (defName d))
        , Strict.Just rf <- [rangeFile r], rangeFilePath rf == file
        , Just p <- [rStart' r] ]
      ends = declEnds (lines src) (Map.elems starts)
      -- names of local definitions in different (anonymous) where-modules, like
      -- M._.eqn, can print the same: then we add the line, M._.eqn@42
      printed = Map.fromListWith (+) [(prettyShow (defName d), 1 :: Int) | (d, _) <- decls]
      name q = case Map.lookup q starts of
        Just l | Map.lookup (prettyShow q) printed > Just 1 -> prettyShow q ++ "@" ++ show l
        _ -> prettyShow q
      declLine (d, k) = object $
        [ "decl" .= name (defName d), "module" .= modName, "kind" .= (k :: String)
        , "uses" .= Set.toList (Set.map name (uses d)) ]
        ++ case Map.lookup (defName d) starts of
             Just l  -> ["line" .= l, "end" .= Map.findWithDefault l l ends]
             Nothing -> []
      out = object ["module" .= modName, "file" .= filePath file] : map declLine decls
  liftIO $ BL.writeFile (dir </> modName <.> "jsonl") $ BL.unlines (map encode out)

kind :: Defn -> Maybe String
kind d = case d of
  Function{}         -> Just "function"
  Datatype{}         -> Just "data"
  DataOrRecSig{}     -> Just "data"
  Record{}           -> Just "record"
  Constructor{}      -> Just "constructor"
  Axiom{}            -> Just "axiom"
  Primitive{}        -> Just "primitive"
  PrimitiveSort{}    -> Just "sort"
  AbstractDefn{}     -> Just "abstract"
  GeneralizableVar{} -> Nothing

-- | The last line of each declaration, given the lines where they start.
-- A declaration ends before the first later line that
-- * starts a declaration, a keyword such as @module@ or @open@, or a comment,
--   at the same or lower indentation as the declaration's first line,
-- * is less indented (it closes the declaration's layout block), or
-- * ends a literate code block;
-- trailing blank lines are dropped.
declEnds :: [String] -> [Int] -> Map.Map Int Int
declEnds ls starts = Map.fromList [(l, end l) | l <- Set.toList declLines]
  where
    n = length ls
    text = Map.fromList (zip [1 ..] ls)
    line i = Map.findWithDefault "" i text
    indent i = length (takeWhile isSpace (line i))
    blank i = all isSpace (line i)
    declLines = Set.fromList starts
    end l = dropBlank (foldr const (n + 1) [i | i <- [l + 1 .. n], stops i] - 1)
      where
        k = indent l
        stops i = fence (trim (line i)) || not (blank i) &&
          (indent i < k || indent i == k && (i `Set.member` declLines || keyword (line i)))
        dropBlank e = if e > l && blank e then dropBlank (e - 1) else e
    fence t = "```" `isPrefixOf` t || "\\end{code}" `isPrefixOf` t
    keyword s = case words s of
      w : _ -> w `elem` keywords || any (`isPrefixOf` w) ["--", "{-"]
      []    -> False
    keywords =
      [ "module", "open", "import", "field", "private","abstract", "instance", "mutual"
      , "postulate", "variable", "infix", "infixl", "infixr", "syntax", "pattern"
      , "macro", "unquoteDecl", "unquoteDef", "interleaved", "opaque", "unfolding" ]

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
