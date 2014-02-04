{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies               #-}

module Hunt.Index.Proxy.CompressedIndex
( ComprOccIndex (..)
, mkComprIx
)
where

import           Prelude                                 as P

import           Control.Applicative                     ((<$>))
import           Control.Arrow                           (second)
import           Control.DeepSeq
import           Control.Monad

import           Data.Binary                             (Binary (..))

import           Hunt.Common.Occurrences             (Occurrences)
import           Hunt.Common.Occurrences.Compression
import           Hunt.Index.Index
import qualified Hunt.Index.Index                    as Ix

-- ----------------------------------------------------------------------------

newtype ComprOccIndex impl to from
    = ComprIx { comprIx :: impl to }
    deriving (Eq, Show, NFData)

mkComprIx :: impl to -> ComprOccIndex impl to from
mkComprIx v = ComprIx $! v

-- ----------------------------------------------------------------------------

instance Binary (impl v) => Binary (ComprOccIndex impl v from) where
    put = put . comprIx
    get = get >>= return . mkComprIx

-- ----------------------------------------------------------------------------

instance Index (ComprOccIndex impl to) where
    type IKey      (ComprOccIndex impl to) from = IKey impl to
    type IVal      (ComprOccIndex impl to) from = Occurrences
    type ICon      (ComprOccIndex impl to) from =
        ( Index impl
        , ICon impl to
        , OccCompression (IVal impl to)
        )

    insert k v (ComprIx i)
        = liftM mkComprIx $ insert k (compressOcc v) i

    batchDelete ks (ComprIx i)
        = liftM mkComprIx $ batchDelete ks i

    empty
        = mkComprIx $ empty

    fromList l
        = liftM mkComprIx . fromList $ P.map (second compressOcc) l

    toList (ComprIx i)
        = liftM (second decompressOcc <$>) $ toList i

    search t k (ComprIx i)
        = liftM (second decompressOcc <$>) $ search t k i

    lookupRange k1 k2 (ComprIx i)
        = liftM (second decompressOcc <$>) $ lookupRange k1 k2 i

    unionWith op (ComprIx i1) (ComprIx i2)
        = liftM mkComprIx $ unionWith (\o1 o2 -> compressOcc $ op (decompressOcc o1) (decompressOcc o2)) i1 i2

    unionWithConv
        = error "ComprOccIndex unionWithConv: unused atm"
{-
    unionWithConv to f (ComprIx i1) (ComprIx i2)
        = liftM mkComprIx $ unionWithConv to f i1 i2
-}

    map f (ComprIx i)
        = liftM mkComprIx $ Ix.map (compressOcc . f . decompressOcc) i

    keys (ComprIx i)
        = keys i

-- ----------------------------------------------------------------------------
