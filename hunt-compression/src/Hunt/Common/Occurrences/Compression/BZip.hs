{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeSynonymInstances       #-}

-- ----------------------------------------------------------------------------
{- |
  'Occurrences' compression using the bzip2 library:
    <http://www.bzip.org/>

  Haskell-Bindings:
    <http://hackage.haskell.org/package/bzlib>
-}
-- ----------------------------------------------------------------------------

module Hunt.Common.Occurrences.Compression.BZip
  (
  -- * Compression types
    CompressedOccurrences
  , OccCompression (..)
  )
where

import qualified Codec.Compression.BZip.Smart        as ZIP

import           Control.Applicative                 ((<$>))
import           Control.DeepSeq

import           Data.Binary                         (Binary (..))
import qualified Data.Binary                         as B
import qualified Data.ByteString.Lazy                as BL
import           Data.ByteString.Short               (ShortByteString)
import qualified Data.ByteString.Short               as Short
import           Data.Typeable

import qualified Hunt.Common.DocIdMap                as DM
import           Hunt.Common.Occurrences
import           Hunt.Common.Occurrences.Compression

-- ------------------------------------------------------------

-- ShortByteString: It has a lower memory overhead than a ByteString and and does not contribute to
-- heapfragmentation. It can be converted to or from a ByteString (at the cost of copying the string
-- data).
-- https://hackage.haskell.org/package/bytestring/docs/Data-ByteString-Short.html#g:1


-- | Bzip-compressed 'Occurrences'.
--   Use 'mkComprOccs' to create.
--   The Document can be retrieved with 'decompressOcc'.
--   The corresponding bijection is defined in 'DocumentWrapper'.
--
--   Using 'ShortByteString' saves 5 machine words per value.
--   It also eliminates issues with sharing and fragmentation due to 'ByteString's being pinned.
--   <https://hackage.haskell.org/package/bytestring/docs/Data-ByteString-Short.html#g:1>
newtype CompressedOccurrences
  = ComprOccs { unComprOccs :: ShortByteString }
  deriving (Eq, Show, Typeable)

-- | Make 'CompressedOccurrences' using bzip-compression.
--
--   Deeply evaluates the value.
mkComprOccs :: ShortByteString -> CompressedOccurrences
mkComprOccs b = ComprOccs $!! b

-- ------------------------------------------------------------

instance NFData CompressedOccurrences where
-- use default implementation: eval to WHNF, and that's sufficient

-- ------------------------------------------------------------

instance OccCompression CompressedOccurrences where
  compressOcc   = compress
  decompressOcc = decompress
  differenceWithKeySet ks = compress . (flip DM.diffWithSet) ks . decompress

-- ------------------------------------------------------------

instance Binary CompressedOccurrences where
  put = put . Short.fromShort . unComprOccs
  get = mkComprOccs . Short.toShort <$> get

-- to avoid sharing the data with the input the ByteString is physically copied
-- before return. This should be the single place where sharing is introduced,
-- else the copy must be moved to mSBs

-- ------------------------------------------------------------

--compress :: Binary a => a -> CompressedOccurrences
compress :: Occurrences -> CompressedOccurrences
compress = mkComprOccs . Short.toShort . BL.toStrict . ZIP.compress . B.encode

--decompress :: Binary a => CompressedOccurrences -> a
decompress :: CompressedOccurrences -> Occurrences
decompress = B.decode . ZIP.decompress . BL.fromStrict . Short.fromShort . unComprOccs

-- ------------------------------------------------------------
