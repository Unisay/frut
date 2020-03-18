{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE Rank2Types #-}

module Language.Frut.Parser.Monad
  ( -- * Parsing monad
    P,
    execParser,
    execParser',
    initPos,
    PState (..),

    -- * Monadic operations
    getPState,
    setPState,
    getPosition,
    setPosition,
    getInput,
    setInput,
    popToken,
    pushToken,
    swapToken,

    -- * Error reporting
    ParseFail (..),
    parseError,
  )
where

import Control.Exception (Exception)
import Control.Monad.Fail as Fail
import Data.Maybe (listToMaybe)
import Data.String (unwords)
import Data.Typeable (Typeable)
import GHC.Show (showParen, showString, showsPrec)
import Language.Frut.Data.InputStream (InputStream)
import Language.Frut.Data.Position
  ( Position,
    Spanned,
    initPos,
    prettyPosition,
  )
import Language.Frut.Syntax.Tok (Tok)
import Prelude hiding (unwords)

-- | Parsing and lexing monad. A value of type @'P' a@ represents a parser that can be run (using
-- 'execParser') to possibly produce a value of type @a@.
newtype P a
  = P
      { unParser ::
          forall r.
          PState -> -- State being passed along
          (a -> PState -> r) -> -- Successful parse continuation
          (String -> Position -> r) -> -- Failed parse continuation
          r -- Final output
      }

-- | State that the lexer and parser share
data PState
  = PState
      { -- | position at current input location
        curPos :: !Position,
        -- | the current input
        curInput :: !InputStream,
        -- | position at previous input location
        prevPos :: Position,
        -- | tokens manually pushed by the user
        pushedTokens :: [Spanned Tok],
        -- | function to swap token
        swapFunction :: Tok -> Tok
      }

instance Functor P where
  fmap f m = P $ \ !s pOk pFailed -> unParser m s (pOk . f) pFailed

instance Applicative P where
  pure x = P $ \ !s pOk _ -> pOk x s

  m <*> k = P $ \ !s pOk pFailed ->
    let pOk' x s' = unParser k s' (pOk . x) pFailed
     in unParser m s pOk' pFailed

instance Monad P where
  return = pure

  m >>= k = P $ \ !s pOk pFailed ->
    let pOk' x s' = unParser (k x) s' pOk pFailed
     in unParser m s pOk' pFailed

instance Fail.MonadFail P where
  fail msg = P $ \ !s _ pFailed -> pFailed msg (curPos s)

-- | Exceptions that occur during parsing
data ParseFail = ParseFail Position String
  deriving (Eq, Typeable)

instance Show ParseFail where
  showsPrec p (ParseFail pos msg) =
    showParen (p >= 11) (showString err)
    where
      err =
        unwords
          [ "parse failure at",
            prettyPosition pos,
            "(" ++ msg ++ ")"
          ]

instance Exception ParseFail

-- | Execute the given parser on the supplied input stream at the given start position, returning
-- either the position of an error and the error message, or the value parsed.
execParser :: P a -> InputStream -> Position -> Either ParseFail a
execParser p input pos = execParser' p input pos id

-- | Generalized version of 'execParser' that expects an extra argument that lets you hot-swap a
-- token that was just lexed before it gets passed to the parser.
execParser' :: P a -> InputStream -> Position -> (Tok -> Tok) -> Either ParseFail a
execParser' parser input pos swapFunc =
  unParser
    parser
    initialState
    (\result _ -> Right result)
    (\message errPos -> Left (ParseFail errPos message))
  where
    initialState =
      PState
        { curPos = pos,
          curInput = input,
          prevPos = error "ParseMonad.execParser: Touched undefined position!",
          pushedTokens = [],
          swapFunction = swapFunc
        }

-- | Swap a token using the swap function.
swapToken :: Tok -> P Tok
swapToken t = P $ \ !s@PState {swapFunction = f} pOk _ -> pOk (f $! t) s

-- | Extract the state stored in the parser.
getPState :: P PState
getPState = P $ \ !s pOk _ -> pOk s s

-- | Update the state stored in the parser.
setPState :: PState -> P ()
setPState s = P $ \_ pOk _ -> pOk () s

-- | Modify the state stored in the parser.
modifyPState :: (PState -> PState) -> P ()
modifyPState f = P $ \ !s pOk _ -> pOk () (f $! s)

-- | Retrieve the current position of the parser.
getPosition :: P Position
getPosition = curPos <$> getPState

-- | Update the current position of the parser.
setPosition :: Position -> P ()
setPosition pos = modifyPState $ \s -> s {curPos = pos}

-- | Retrieve the current 'InputStream' of the parser.
getInput :: P InputStream
getInput = curInput <$> getPState

-- | Update the current 'InputStream' of the parser.
setInput :: InputStream -> P ()
setInput i = modifyPState $ \s -> s {curInput = i}

-- | Manually push a @'Spanned' 'Tok'@. This turns out to be useful when parsing tokens that need
-- to be broken up. For example, when seeing a 'Language.Rust.Syntax.GreaterEqual' token but only
-- expecting a 'Language.Rust.Syntax.Greater' token, one can consume the
-- 'Language.Rust.Syntax.GreaterEqual' token and push back an 'Language.Rust.Syntax.Equal' token.
pushToken :: Spanned Tok -> P ()
pushToken tok = modifyPState $ \s@PState {pushedTokens = toks} -> s {pushedTokens = tok : toks}

-- | Manually pop a @'Spanned' 'Tok'@ (if there are no tokens to pop, returns 'Nothing'). See
-- 'pushToken' for more details.
popToken :: P (Maybe (Spanned Tok))
popToken = P $ \ !s@PState {pushedTokens = toks} pOk _ -> pOk (listToMaybe toks) s {pushedTokens = drop 1 toks}

-- | Signal a syntax error.
parseError :: Show b => b -> P a
parseError b = Fail.fail ("Syntax error: the symbol `" ++ show b ++ "' does not fit here")
