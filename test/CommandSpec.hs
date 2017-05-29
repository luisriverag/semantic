module CommandSpec where

import Command
import Data.Aeson
import Data.Aeson.Types hiding (parse)
import Data.Functor.Both as Both
import Data.Map
import Data.Maybe
import Data.Record
import Data.String
import Info (DefaultFields, HasDefaultFields)
import Language
import Prologue hiding (readFile, toList)
import qualified Data.Vector as V
import qualified Git.Types as Git
import Renderer hiding (errors)
import Source
import Semantic
import Term
import Test.Hspec hiding (shouldBe, shouldNotBe, shouldThrow, errorCall)
import Test.Hspec.Expectations.Pretty

spec :: Spec
spec = parallel $ do
  describe "readFile" $ do
    it "returns a blob for extant files" $ do
      blob <- runCommand (readFile "semantic-diff.cabal" Nothing)
      path blob `shouldBe` "semantic-diff.cabal"

    it "returns a nullBlob for absent files" $ do
      blob <- runCommand (readFile "this file should not exist" Nothing)
      nullBlob blob `shouldBe` True

  describe "readBlobPairsFromHandle" $ do
    let a = sourceBlob "method.rb" (Just Ruby) "def foo; end"
    let b = sourceBlob "method.rb" (Just Ruby) "def bar(x); end"
    it "returns blobs for valid JSON encoded diff input" $ do
      blobs <- blobsFromFilePath "test/fixtures/input/diff.json"
      blobs `shouldBe` [both a b]

    it "returns blobs when there's no before" $ do
      blobs <- blobsFromFilePath "test/fixtures/input/diff-no-before.json"
      blobs `shouldBe` [both (emptySourceBlob "method.rb") b]

    it "returns blobs when there's null before" $ do
      blobs <- blobsFromFilePath "test/fixtures/input/diff-null-before.json"
      blobs `shouldBe` [both (emptySourceBlob "method.rb") b]

    it "returns blobs when there's no after" $ do
      blobs <- blobsFromFilePath "test/fixtures/input/diff-no-after.json"
      blobs `shouldBe` [both a (emptySourceBlob "method.rb")]

    it "returns blobs when there's null after" $ do
      blobs <- blobsFromFilePath "test/fixtures/input/diff-null-after.json"
      blobs `shouldBe` [both a (emptySourceBlob "method.rb")]


    it "returns blobs for unsupported language" $ do
      h <- openFile "test/fixtures/input/diff-unsupported-language.json" ReadMode
      blobs <- runCommand (readBlobPairsFromHandle h)
      let b' = sourceBlob "test.kt" Nothing "fun main(args: Array<String>) {\nprintln(\"hi\")\n}\n"
      blobs `shouldBe` [both (emptySourceBlob "test.kt") b']

    it "detects language based on filepath for empty language" $ do
      blobs <- blobsFromFilePath "test/fixtures/input/diff-empty-language.json"
      blobs `shouldBe` [both a b]

    it "throws on blank input" $ do
      h <- openFile "test/fixtures/input/blank.json" ReadMode
      runCommand (readBlobPairsFromHandle h) `shouldThrow` (== ExitFailure 1)

    it "throws if language field not given" $ do
      h <- openFile "test/fixtures/input/diff-no-language.json" ReadMode
      runCommand (readBlobsFromHandle h) `shouldThrow` (== ExitFailure 1)

  describe "readBlobsFromHandle" $ do
    it "returns blobs for valid JSON encoded parse input" $ do
      h <- openFile "test/fixtures/input/parse.json" ReadMode
      blobs <- runCommand (readBlobsFromHandle h)
      let a = sourceBlob "method.rb" (Just Ruby) "def foo; end"
      blobs `shouldBe` [a]

    it "throws on blank input" $ do
      h <- openFile "test/fixtures/input/blank.json" ReadMode
      runCommand (readBlobsFromHandle h) `shouldThrow` (== ExitFailure 1)

  describe "readFilesAtSHA" $ do
    it "returns blobs for the specified paths" $ do
      blobs <- runCommand (readFilesAtSHA repoPath [] [("methods.rb", Just Ruby)] (Both.snd (shas methodsFixture)))
      blobs `shouldBe` [methodsBlob]

    it "returns emptySourceBlob if path doesn't exist at sha" $ do
      blobs <- runCommand (readFilesAtSHA repoPath [] [("methods.rb", Just Ruby)] (Both.fst (shas methodsFixture)))
      nonExistentBlob <$> blobs `shouldBe` [True]

  describe "readFilesAtSHAs" $ do
    it "returns blobs for the specified paths" $ do
      blobs <- runCommand (readFilesAtSHAs repoPath [] [("methods.rb", Just Ruby)] (shas methodsFixture))
      blobs `shouldBe` expectedBlobs methodsFixture

    it "returns blobs for all paths if none are specified" $ do
      blobs <- runCommand (readFilesAtSHAs repoPath [] [] (shas methodsFixture))
      blobs `shouldBe` expectedBlobs methodsFixture

    it "returns entries for missing paths" $ do
      blobs <- runCommand (readFilesAtSHAs repoPath [] [("this file should not exist", Nothing)] (shas methodsFixture))
      let b = emptySourceBlob "this file should not exist"
      blobs `shouldBe` [both b b]

  describe "fetchDiffs" $ do
    it "generates toc summaries for two shas" $ do
      (errors, summaries) <- fetchDiffsOutput termText "test/fixtures/git/examples/all-languages.git" "dfac8fd681b0749af137aebf3203e77a06fbafc2" "2e4144eb8c44f007463ec34cb66353f0041161fe" [("methods.rb", Just Ruby)] declarationDecorator Renderer.ToCRenderer
      errors `shouldBe` Just (fromList [])
      summaries `shouldBe` Just (fromList [("methods.rb", ["foo"])])

    it "generates toc summaries for two shas inferring paths" $ do
      (errors, summaries) <- fetchDiffsOutput termText "test/fixtures/git/examples/all-languages.git" "dfac8fd681b0749af137aebf3203e77a06fbafc2" "2e4144eb8c44f007463ec34cb66353f0041161fe" [] declarationDecorator Renderer.ToCRenderer
      errors `shouldBe` Just (fromList [])
      summaries `shouldBe` Just (fromList [("methods.rb", ["foo"])])

    it "errors with bad shas" $
      fetchDiffsOutput termText "test/fixtures/git/examples/all-languages.git" "dead" "beef" [("methods.rb", Just Ruby)] declarationDecorator Renderer.ToCRenderer
        `shouldThrow` (== Git.BackendError "Could not lookup dead: Object not found - no match for prefix (dead000000000000000000000000000000000000)")

    it "errors with bad repo path" $
      fetchDiffsOutput termText "test/fixtures/git/examples/not-a-repo.git" "dfac8fd681b0749af137aebf3203e77a06fbafc2" "2e4144eb8c44f007463ec34cb66353f0041161fe" [("methods.rb", Just Ruby)] declarationDecorator Renderer.ToCRenderer
        `shouldThrow` errorCall "Could not open repository \"test/fixtures/git/examples/not-a-repo.git\""

  where repoPath = "test/fixtures/git/examples/all-languages.git"
        methodsFixture = Fixture
          (both "dfac8fd681b0749af137aebf3203e77a06fbafc2" "2e4144eb8c44f007463ec34cb66353f0041161fe")
          [ both (emptySourceBlob "methods.rb") methodsBlob ]
        methodsBlob = SourceBlob (Source "def foo\nend\n") "ff7bbbe9495f61d9e1e58c597502d152bab1761e" "methods.rb" (Just defaultPlainBlob) (Just Ruby)
        blobsFromFilePath path = do
          h <- openFile path ReadMode
          blobs <- runCommand (readBlobPairsFromHandle h)
          pure blobs

data Fixture = Fixture { shas :: Both String, expectedBlobs :: [Both SourceBlob] }

fetchDiffsOutput :: (HasDefaultFields fields, NFData (Record fields)) => (Object -> Text) -> FilePath -> String -> String -> [(FilePath, Maybe Language)] -> (Source -> SyntaxTerm Text DefaultFields -> SyntaxTerm Text fields) -> DiffRenderer fields Summaries -> IO (Maybe (Map Text Value), Maybe (Map Text [Text]))
fetchDiffsOutput f gitDir sha1 sha2 filePaths decorator renderer = do
  blobs <- runCommand $ readFilesAtSHAs gitDir [] filePaths (both sha1 sha2)
  results <- Semantic.diffBlobPairs decorator renderer blobs
  let json = fromJust (decode (toS results))
  pure (errors json, summaries f json)

-- Diff Summaries payloads look like this:
-- {
--  "changes": { "methods.rb": [{ "span":{"insert":{"start":[1,1],"end":[2,4]}}, "summary":"Added the 'foo()' method" }] },
-- "errors":{}
-- }
-- TOC Summaries payloads look like this:
-- {
-- "changes": { "methods.rb": [{ "span":{"start":[1,1],"end":[2,4]}, "category":"Method", "term":"foo", "changeType":"added" }]
-- },
-- "errors":{}
-- }
summaries :: (Object -> Text) -> Object -> Maybe (Map Text [Text])
summaries f = parseMaybe $ \o -> do
                changes <- o .: "changes" :: Parser (Map Text (V.Vector Object))
                xs <- for (toList changes) $ \(path, s) -> do
                  let ys = fmap f s
                  pure (path, V.toList ys)
                pure $ fromList xs

termText :: Object -> Text
termText o = fromMaybe (panic "key 'term' not found") $
  parseMaybe (.: "term") o

errors :: Object -> Maybe (Map Text Value)
errors = parseMaybe (.: "errors")
