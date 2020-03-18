{-# LANGUAGE TypeApplications #-}

module Language.Frut.LexerTest where

import Language.Frut.Data.InputStream (InputStream, readInputStream)
import Language.Frut.Data.Position (Spanned, initPos)
import Language.Frut.Lexer (lexTokens, lexNonSpace)
import Language.Frut.Parser.Monad (execParser, ParseFail)
import Language.Frut.Syntax.Tok (Tok)
import System.FilePath (replaceExtension, takeBaseName)
import Test.Tasty
import Test.Tasty.Golden (findByExtension, goldenVsString)
import Text.Show.Pretty

test_Lexer :: IO TestTree
test_Lexer = do
  frutFiles <- findByExtension [".frut"] "test/golden"
  pure . testGroup "FRUT lexer" $ do
    frutFile <- frutFiles
    return
      $ goldenVsString (takeBaseName frutFile) (replaceExtension frutFile ".golden.txt")
      $ encodeUtf8 @String @LByteString . ppShow . lex
        <$> readInputStream frutFile

lex :: InputStream -> Either ParseFail [Spanned Tok]
lex inputStream = execParser (lexTokens lexNonSpace) inputStream initPos 
