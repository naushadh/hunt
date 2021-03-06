{-# LANGUAGE MagicHash         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UnboxedTuples     #-}
module Hunt.IO.Write (
    Write (..)
  , word8
  , word64
  , varint32
  , varint64
  , bytestring
  , bytestring'
  , text

  , divided
  , (>$<)
  , (>*<)
  ) where


import           GHC.Exts
import           GHC.Types

import           Data.ByteString                      (ByteString)
import qualified Data.ByteString                      as ByteString
import qualified Data.ByteString.Internal             as ByteString
import           Data.Functor.Contravariant
import           Data.Functor.Contravariant.Divisible
import           Data.Text                            (Text)
import qualified Data.Text.Foreign                    as Text
import           Data.Word
import           Foreign.ForeignPtr.Unsafe
import           Foreign.Ptr
import           Foreign.Storable


-- | A 'Writing' writes as to a buffer. A 'Writing' has a hint function
-- which estimates the maximum needed buffer space.
--
-- The idea is that multiple 'Write's can be combined using '(>*<)' and
-- '>*<' so that GHC is smart enough to float-out the bounds check
-- so we it emits exactly one bound-check per 'Write' instead of
-- one for each component.
data Write a = W (a -> Int) (a -> Ptr Word8 -> IO (Ptr Word8))

instance Contravariant Write where
  contramap f (W hint write) = W (hint . f) (write . f)
  {-# INLINE CONLIKE contramap #-}

instance Divisible Write where
  divide = divideW
  {-# INLINE CONLIKE divide #-}

  conquer = unitW
  {-# INLINE CONLIKE conquer #-}

unitW :: Write a
unitW = W (\_ -> 0) (\_ op -> return op)
{-# INLINE CONLIKE unitW #-}

divideW :: (a -> (b, c)) -> Write b -> Write c -> Write a
divideW f (W hint1 write1) (W hint2 write2) =
  W (\a -> let (x, y) = f a in hint1 x + hint2 y)
    (\a op -> let (x, y) = f a in write1 x op >>= write2 y)
{-# INLINE CONLIKE divideW #-}

(>*<) :: Write a -> Write b -> Write (a, b)
(>*<) = divided
{-# INLINE CONLIKE (>*<) #-}
infixr 5 >*<

word8 :: Write Word8
word8 = W (\_ -> 1) (\w op -> poke op w >> return (op `plusPtr` 1))
{-# INLINE CONLIKE word8 #-}

word64 :: Write Word64
word64 = W (\_ -> 8) (\w op -> poke (castPtr op) w >> return (op `plusPtr` 8))
{-# INLINE CONLIKE word64 #-}

varint32 :: Write Word32
varint32 = fromIntegral >$< varint 5
{-# INLINE CONLIKE varint32 #-}

varint64 :: Write Word64
varint64 = fromIntegral >$< varint 9
{-# INLINE CONLIKE varint64 #-}

varint :: Int -> Write Word
varint n = W (\_ -> n) go
  where
    go (W# w) (Ptr p) = IO $ \s0 -> case loop w p s0 of
                                         (# s1, p' #) -> (# s1, Ptr p' #)
    {-# INLINE go #-}

    loop w p s0
      | isTrue# (ltWord# w (int2Word# 0x80#)) =
          case writeWord8OffAddr# p 0# (narrow8Word# w) s0 of
            s1 -> (# s1, plusAddr# p 1# #)
      | otherwise =
        case writeWord8OffAddr# p 0# ((narrow8Word# (or# w (int2Word# 0x80#)))) s0 of
          s1 -> loop (uncheckedShiftRL# w 7#) (plusAddr# p 1#) s1
    {-# INLINE loop #-}

{-# INLINE varint #-}

bytestring :: Write ByteString
bytestring = W (\(ByteString.PS _ _ len) -> len) go
  where go (ByteString.PS fbs off len) op = do
          ByteString.memcpy op (unsafeForeignPtrToPtr fbs `plusPtr` off) len
          return (op `plusPtr` len)
{-# INLINE CONLIKE bytestring #-}

-- | Similar to 'bytestring' 'Writing' but instead prefixes the
-- given 'ByteString' with its length in 'varint' format.
bytestring' :: Write ByteString
bytestring' = divide f varint64 bytestring
  where f s = ( fromIntegral (ByteString.length s), s)
{-# INLINE CONLIKE bytestring' #-}

text :: Write Text
text = W size write
  where
    W vintSize vintWrite = fromIntegral >$< varint64

    size t = case 2 * Text.lengthWord16 t of
               tsz -> vintSize tsz + tsz

    write t op =  case 2 * Text.lengthWord16 t of
                    tsz -> do op'  <- vintWrite tsz op
                              Text.unsafeCopyToPtr t (castPtr op')
                              return $ op' `plusPtr` tsz
{-# INLINE CONLIKE text #-}
