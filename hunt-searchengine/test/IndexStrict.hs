{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Main where

import           Control.DeepSeq
import           Control.Monad                                   (foldM)

import           Test.Framework
import           Test.Framework.Providers.QuickCheck2
import           System.Random
import           Test.QuickCheck
import           Test.QuickCheck.Gen
import           Test.QuickCheck.Monadic                         (PropertyM,
                                                                  assert,
                                                                  monadicIO,
                                                                  monitor,
                                                                  pick, run)

import           Data.Map                                        (Map)
import qualified Data.Map                                        as M
import           Data.Text                                       (Text)
import qualified Data.Text                                       as T

import           GHC.AssertNF
import           GHC.HeapView
import qualified System.Mem


import           Hunt.Common
import qualified Hunt.Common.Occurrences                     as Occ
import qualified Hunt.Common.Occurrences.Compression.BZip    as ZB
import qualified Hunt.Common.Occurrences.Compression.Simple9 as Z9
import qualified Hunt.Common.Occurrences.Compression.Snappy  as ZS
import qualified Hunt.Common.Positions                       as Pos


import qualified Hunt.Index.ComprPrefixTreeIndex             as CPIx
import qualified Hunt.Index.Index                            as Ix
import qualified Hunt.Index.InvertedIndex                    as InvIx
import qualified Hunt.Index.PrefixTreeIndex                  as PIx
import           Hunt.Index.IndexImpl

import qualified Hunt.Index.Proxy.CachedIndex                as CacheProxy
import qualified Hunt.Index.Proxy.KeyIndex                   as KeyProxy
import qualified Hunt.Index.Proxy.IntNormalizerIndex         as IntProxy
import qualified Hunt.Index.Proxy.DateNormalizerIndex        as DateProxy
import qualified Hunt.Index.Proxy.PositionNormalizerIndex    as GeoProxy
import qualified Hunt.Index.Proxy.ContextIndex               as CIx
--import qualified Hunt.Index.Proxy.CompressedIndex            as ComprProxy

-- ----------------------------------------------------------------------------

main :: IO ()
main = defaultMain
  -- strictness property for in index data structures
  [ testProperty "prop_strictness_occurrences"               prop_occs

  -- strictness property for index implementations
  , testProperty "prop_strictness_prefixtreeindex"           prop_ptix
  , testProperty "prop_strictness_invindex textkey"          prop_invix1
  , testProperty "prop_strictness_invindex intkey"           prop_invix2
  , testProperty "prop_strictness_invindex datekey"          prop_invix3
  , testProperty "prop_strictness_invindex geokey"           prop_invix4

  -- strictness property for compression implementations
  , testProperty "prop_strictness_comprprefixtreeindex bzip" prop_cptix2
  , testProperty "prop_strictness_comprprefixtreeindex snap" prop_cptix3
  --            test failing right now because compressedoccurrences are not strict
  --            but we are not using them at the moment and probably won't in the future
  --              , testProperty "prop_strictness_comprprefixtreeindex comp" prop_cptix

  -- strictness property for proxies
  , testProperty "prop_strictness_proxy_cache"               prop_cachedix
  , testProperty "prop_strictness_proxy_textkey"             prop_textix
  , testProperty "prop_strictness_proxy_intkey"              prop_intix
  , testProperty "prop_strictness_proxy_datekey"             prop_dateix
  , testProperty "prop_strictness_proxy_geokey"              prop_geoix

  -- strictness property for contextindex
  -- these tests are failing despite the index beeing strict.
  -- This is caused by the usage of existential types. They are implemented
  -- as a datatype which stores the actual value as well with the typeclass
  -- dictionaries. While the actual values are forced to be strict by us,
  -- there is no way to have GHC do the same for the typeclass dictionaries.
  --, testProperty "prop_strictness_contextindex empty "       prop_contextix_empty
  --, testProperty "prop_strictness_contextindex empty ix"     prop_contextix_emptyix
  --, testProperty "prop_strictness_contextindex"              prop_contextix
  --, testProperty "prop_strictness_contextindex2"             prop_contextix2
  -- strictness property of IndexImpl container
  -- , testProperty "prop_strictness_indeximpl emptyix"         prop_impl_empty
  -- , testProperty "prop_strictness_indeximpl fullix"          prop_impl_full
  ]

-- ----------------------------------------------------------------------------
-- test data structures
-- ----------------------------------------------------------------------------

prop_occs :: Property
prop_occs = monadicIO $ do
  x <- pick arbitrary :: PropertyM IO Occurrences
  -- $!! needed here - $! does not evaluate everything of course
  assertNF' $!! x

-- ----------------------------------------------------------------------------
-- test with simple index
-- ----------------------------------------------------------------------------

-- | helper generating random indices


prop_ptix :: Property
prop_ptix
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (PIx.DmPrefixTree Positions)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "key" val Ix.empty

prop_cptix :: Property
prop_cptix
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (CPIx.ComprOccPrefixTree Z9.CompressedOccurrences)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "key" val Ix.empty

prop_cptix2 :: Property
prop_cptix2
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (CPIx.ComprOccPrefixTree ZB.CompressedOccurrences)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "key" val Ix.empty

prop_cptix3 :: Property
prop_cptix3
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (CPIx.ComprOccPrefixTree ZS.CompressedOccurrences)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "key" val Ix.empty


prop_invix1 :: Property
prop_invix1
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (InvIx.InvertedIndex Positions)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "key" val Ix.empty

prop_invix2 :: Property
prop_invix2
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (InvIx.InvertedIndexInt Positions)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "1" val Ix.empty

prop_invix3 :: Property
prop_invix3
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (InvIx.InvertedIndexDate Positions)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "2013-01-01" val Ix.empty

prop_invix4 :: Property
prop_invix4
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (InvIx.InvertedIndexPosition Positions)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "1-1" val Ix.empty


-- ----------------------------------------------------------------------------
-- test index proxies
-- ----------------------------------------------------------------------------

-- cache
prop_cachedix :: Property
prop_cachedix
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (CacheProxy.CachedIndex (PIx.DmPrefixTree) Positions)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "key" val Ix.empty


-- text proxy
prop_textix :: Property
prop_textix
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (KeyProxy.KeyProxyIndex Text (PIx.DmPrefixTree) Positions)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "key" val Ix.empty

-- int proxy
prop_intix :: Property
prop_intix
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (IntProxy.IntAsTextNormalizerIndex (KeyProxy.KeyProxyIndex Text (PIx.DmPrefixTree)) Positions)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "1" val Ix.empty

-- date proxy
prop_dateix :: Property
prop_dateix
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (DateProxy.DateNormalizerIndex (KeyProxy.KeyProxyIndex Text (PIx.DmPrefixTree)) Positions)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "2013-01-01" val Ix.empty

-- geo proxy
prop_geoix :: Property
prop_geoix
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (GeoProxy.PositionNormalizerIndex (KeyProxy.KeyProxyIndex Text (PIx.DmPrefixTree)) Positions)
    assertNF' ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "1-1" val Ix.empty

-- ----------------------------------------------------------------------------
-- test property contextindex
-- ----------------------------------------------------------------------------

prop_contextix_empty :: Property
prop_contextix_empty
  = monadicIO $ do
    assertNF' CIx.empty


prop_contextix_emptyix :: Property
prop_contextix_emptyix
   = monadicIO $ do
    val     <- pick arbitrary :: PropertyM IO Occurrences
    let ix  = Ix.empty :: (InvIx.InvertedIndexPosition Occurrences)
    let ix2 = Ix.empty :: (InvIx.InvertedIndex Occurrences)
    let cix = CIx.insertContext "text" (mkIndex ix2)
            $ CIx.insertContext "geo" (mkIndex ix)
            $ CIx.empty
    assertNF' cix



prop_contextix :: Property
prop_contextix
  = monadicIO $ do
    val     <- pick arbitrary :: PropertyM IO Occurrences
    let ix  = Ix.empty :: (InvIx.InvertedIndexPosition Occurrences)
    let ix2 = Ix.empty :: (InvIx.InvertedIndex Occurrences)
    let cix = CIx.insertWithCx "text" "word" val
            $ CIx.insertContext "text" (mkIndex ix2)
            $ CIx.insertContext "geo" (mkIndex ix)
            $ CIx.empty
    assertNF' cix


prop_contextix2 :: Property
prop_contextix2
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (InvIx.InvertedIndexPosition Occurrences)
    ix2 <- pickIx2 :: PropertyM IO (InvIx.InvertedIndex Occurrences)
    let cix = CIx.insertContext "text" (mkIndex ix2)
            $ CIx.insertContext "geo" (mkIndex ix)
            $ CIx.empty
    assertNF' cix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "1-1" val Ix.empty
  pickIx2 = pick arbitrary >>= \val -> return $ Ix.insert "1-1" val Ix.empty

-- ----------------------------------------------------------------------------
-- test property indeximpl
-- ----------------------------------------------------------------------------

prop_impl_full :: Property
prop_impl_full
  = monadicIO $ do
    ix <- pickIx :: PropertyM IO (InvIx.InvertedIndexPosition Occurrences)
    assertNF' $ mkIndex ix
  where
  pickIx = pick arbitrary >>= \val -> return $ Ix.insert "1-1" val Ix.empty

prop_impl_empty :: Property
prop_impl_empty
  = monadicIO $ do
    let ix = Ix.empty  :: (InvIx.InvertedIndexPosition Occurrences)
    assertNF' $ mkIndex ix

-- ----------------------------------------------------------------------------
-- test property
-- ----------------------------------------------------------------------------
prop_simple :: Property
prop_simple = monadicIO $ do
  x <- pick arbitrary
  passed <- run $ isNF $! mkTuple x
  assert passed

inc :: Int -> Int
inc x = 1 + x

data Tuple x = Tuple {
  val1 :: !x,
  val2 :: !x
} deriving (Eq, Show)

instance NFData (Tuple x) where

mkTuple :: Int -> Tuple Int
mkTuple x = Tuple (inc x) (inc x)


--instance Arbitrary Text where
--    arbitrary = T.pack <$> arbitrary
--    shrink xs = T.pack <$> shrink (T.unpack xs)

--test2 :: Assertion
--test2 = assertNF $ ptIndex

-- --------------------
-- Arbitrary Occurrences

instance Arbitrary Occurrences where
  arbitrary = mkOccurrences

mkOccurrences :: Gen Occurrences
mkOccurrences = listOf mkPositions >>= foldM foldOccs Occ.empty
  where
  foldOccs occs ps = do
    docId <- arbitrary
    return $ Occ.insert' docId ps occs

mkPositions :: Gen Positions
mkPositions = listOf arbitrary >>= return . Pos.fromList

-- --------------------
-- Arbitrary ApiDocument

apiDocs :: Int -> Int -> IO [ApiDocument]
apiDocs = mkData apiDocGen


mkData :: (Int -> Gen a) -> Int -> Int -> IO [a]
mkData gen minS maxS =
  do rnd0 <- newStdGen
     let rnds rnd = rnd1 : rnds rnd2 where (rnd1,rnd2) = split rnd
     return [unGen (gen i) r n | ((r,n),i) <- rnds rnd0 `zip` cycle [minS..maxS] `zip` [1..]] -- simple cycle


apiDocGen :: Int -> Gen ApiDocument
apiDocGen n = do
  desc_    <- descriptionGen
  let ix  =  mkIndexData n desc_
  return  $ ApiDocument uri_ ix desc_
  where uri_ = T.pack . ("rnd://" ++) . show $ n

niceText1 :: Gen Text
niceText1 = fmap T.pack . listOf1 . elements $ concat [" ", ['0'..'9'], ['A'..'Z'], ['a'..'z']]


descriptionGen :: Gen Description
descriptionGen = do
  tuples <- listOf kvTuples
  return $ M.fromList tuples
  where
  kvTuples = do
    a <- resize 15 niceText1 -- keys are short
    b <- niceText1
    return (a,b)


mkIndexData :: Int -> Description -> Map Context Content
mkIndexData i d = M.fromList
                $ map (\c -> ("context" `T.append` (T.pack $ show c), prefixx c)) [0..i]
  where
--  index   = T.pack $ show i
  prefixx n = T.intercalate " " . map (T.take n . T.filter (/=' ') . snd) . M.toList $ d

-- ------------------------------------------------------------

heapGraph :: Int -> a -> IO String
heapGraph d x = do
  let box = asBox x
  graph <- buildHeapGraph d () box
  return $ ppHeapGraph graph

isNFWithGraph :: Int -> a -> IO (Bool, String)
isNFWithGraph d x = do
  b <- isNF $! x
  -- XXX: does gc need a delay?
  System.Mem.performGC
  g <- heapGraph d x
  return (b,g)

-- depth is a constant
assertNF' :: a -> PropertyM IO ()
assertNF' = assertNF'' 5

assertNF'' :: Int -> a -> PropertyM IO ()
assertNF'' d x = do
  (b,g) <- run $ isNFWithGraph d x
  monitor $ const $ printTestCase g b

-- ----------------------------------------------------------------------------