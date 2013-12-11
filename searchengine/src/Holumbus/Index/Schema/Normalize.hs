module Holumbus.Index.Schema.Normalize
  ( contextNormalizer
  , typeValidator
  , rangeValidator
  )
where

import           Data.Maybe
import           Data.Text                            (Text)
import qualified Data.Text                            as T

import           Holumbus.Common.BasicTypes
import           Holumbus.Index.Schema
import           Holumbus.Utility

import           Holumbus.Index.Schema.Normalize.Date (normalizeDate, isAnyDate')

-- ----------------------------------------------------------------------------

contextNormalizer :: CNormalizer -> Word -> Word
contextNormalizer o = case o of
    NormUpperCase -> T.toUpper
    NormLowerCase -> T.toLower
    NormDate      -> normalizeDate

-- ----------------------------------------------------------------------------

-- | Checks if value is valid for a context type.
typeValidator :: CType -> Text -> Bool
typeValidator t = case t of
    CText -> const True
    CInt  -> const True
    CDate -> isAnyDate' . T.unpack

-- ----------------------------------------------------------------------------

-- | Checks if a range is valid for a context type.
rangeValidator :: CType -> [Text] -> [Text] -> Bool
rangeValidator t = case t of
    _     -> defaultCheck
  where
  defaultCheck xs ys = fromMaybe False $ do
    x <- unboxM xs
    y <- unboxM ys
    return $ x <= y

-- ----------------------------------------------------------------------------