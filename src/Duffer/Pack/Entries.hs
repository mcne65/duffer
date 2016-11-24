{-# LANGUAGE RecordWildCards #-}

module Duffer.Pack.Entries where

import qualified Codec.Compression.Zlib as Z
import qualified Data.ByteString        as B
import qualified Data.Map.Strict        as Map

import Data.Byteable
import Data.ByteString.Base16 (decode)
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Bits
import Data.Bool               (bool)
import Data.Digest.CRC32
import Data.List (foldl')
import Data.Word (Word8, Word32)

import Duffer.Loose.Objects (Ref)

data PackIndexEntry = PackIndexEntry Int Ref Word32
    deriving (Show, Eq)

data PackObjectType
    = UnusedPackObjectType0
    | CommitObject
    | TreeObject
    | BlobObject
    | TagObject
    | UnusedPackObjectType5
    | OfsDeltaObject
    | RefDeltaObject
    deriving (Enum, Eq, Show)

data PackDelta
    = OfsDelta Int (PackDecompressed Delta)
    | RefDelta Ref (PackDecompressed Delta)
    deriving (Show, Eq)

data PackedObject =
    PackedObject PackObjectType Ref (PackDecompressed B.ByteString)
    deriving (Show, Eq)

data PackEntry = Resolved PackedObject | UnResolved PackDelta
    deriving (Show, Eq)

{- Packfile entries generated by `git` use one of two different compression
 - levels: best compression or best speed. To perfectly reconstruct a packfile,
 - we need to store the compression level of each section of compressed
 - content. For generating our own packfiles, this is not as important.
 -}
data PackDecompressed a = PackDecompressed
    { packLevel   :: Z.CompressionLevel
    , packContent :: a
    } deriving (Show, Eq)

data DeltaInstruction
    = CopyInstruction   Int Int
    | InsertInstruction B.ByteString
    deriving (Show, Eq)

data Delta = Delta Int Int [DeltaInstruction] deriving (Show, Eq)

data CombinedMap = CombinedMap
    { getOffsetMap :: OffsetMap
    , getRefIndex  :: RefIndex
    } deriving (Show)

data ObjectMap = ObjectMap
    { getObjectMap   :: Map.Map Int PackedObject
    , getObjectIndex :: RefIndex
    }

type OffsetMap = Map.Map Int PackEntry
type RefMap    = Map.Map Ref PackEntry
type RefIndex  = Map.Map Ref Int

instance Byteable PackEntry where
    toBytes (Resolved  packedObject)         = toBytes packedObject
    toBytes (UnResolved ofsD@(OfsDelta _ (PackDecompressed _ d))) = let
        header = encodeTypeLen OfsDeltaObject $ B.length (toBytes d)
        in header `B.append` toBytes ofsD
    toBytes (UnResolved refD@(RefDelta _ (PackDecompressed _ d))) = let
        header = encodeTypeLen RefDeltaObject $ B.length (toBytes d)
        in header `B.append` toBytes refD

instance Byteable PackedObject where
    toBytes (PackedObject t _ packed) = let
        header     = encodeTypeLen t $ B.length $ packContent packed
        compressed = toBytes packed
        in header `B.append` compressed

instance (Byteable a) => Byteable (PackDecompressed a) where
    toBytes (PackDecompressed level content) =
        compressToLevel level $ toBytes content

isResolved :: PackEntry -> Bool
isResolved (Resolved _)   = True
isResolved (UnResolved _) = False

compressToLevel :: Z.CompressionLevel -> B.ByteString -> B.ByteString
compressToLevel level content = toStrict $
    Z.compressWith Z.defaultCompressParams
      { Z.compressLevel = level }
      $ fromStrict content

getCompressionLevel :: Word8 -> Z.CompressionLevel
getCompressionLevel levelByte = case levelByte of
        1   -> Z.bestSpeed
        156 -> Z.defaultCompression
        _   -> error "I can't make sense of this compression level"

instance Functor PackDecompressed where
    fmap f (PackDecompressed level content) =
        PackDecompressed level (f content)

encodeTypeLen :: PackObjectType -> Int -> B.ByteString
encodeTypeLen packObjType len = let
    (last4, rest) = packEntryLenList len
    firstByte     = (fromEnum packObjType `shiftL` 4) .|. last4
    firstByte'    = bool firstByte (setBit firstByte 7) (rest /= "")
    in B.cons (fromIntegral firstByte') rest

packEntryLenList :: Int -> (Int, B.ByteString)
packEntryLenList n = let
    rest   = fromIntegral n `shiftR` 4 :: Int
    last4  = fromIntegral n .&. 15
    last4' = bool last4 (setBit last4 7) (rest > 0)
    restL  = to7BitList rest
    restL' = bool
        []
        (map fromIntegral $ head restL:map (`setBit` 7) (tail restL))
        (restL /= [0])
    in (last4', B.pack $ reverse restL')

instance Byteable PackDelta where
    toBytes packDelta = let
        (encoded, compressed) = case packDelta of
            (RefDelta ref delta) -> (fst $ decode ref, toBytes delta)
            (OfsDelta off delta) -> (encodeOffset off, toBytes delta)
        in B.append encoded compressed

encodeOffset :: Int -> B.ByteString
encodeOffset n = let
    {- Given a = r = 2^7:
     - x           = a((1 - r^n)/(1-r))
     - x - xr      = a - ar^n
     - x + ar^n    = a + xr
     - x + r^(n+1) = r + xr
     - r^(n+1)     = r + xr -x
     - r^(n+1)     = x(r-1) + r
     - n+1         = log128 x(r-1) + r
     - n           = floor ((log128 x(2^7-1) + 2^7) - 1)
     -}
    noTermsLog  = logBase 128 (fromIntegral n * (128 - 1) + 128) :: Double
    noTerms     = floor noTermsLog - 1
    powers128   = map (128^) ([1..] :: [Integer])
    remove      = sum $ take noTerms powers128 :: Integer
    remainder   = n - fromIntegral remove :: Int
    varInt      = to7BitList remainder
    encodedInts = setMSBs $ leftPadZeros varInt (noTerms + 1)
    in B.pack $ map fromIntegral encodedInts

leftPadZeros :: [Int] -> Int -> [Int]
leftPadZeros ints n
    | length ints >= n = ints
    | otherwise        = leftPadZeros (0:ints) n

setMSBs :: [Int] -> [Int]
setMSBs ints = let
    ints'  = reverse ints
    ints'' = head ints' : map (`setBit` 7) ( tail ints')
    in reverse ints''

instance Byteable Delta where
    toBytes (Delta source dest instructions) = let
        sourceEncoded = toLittleEndian $ to7BitList source
        destEncoded   = toLittleEndian $ to7BitList dest
        instrsBS      = B.concat (map toBytes instructions)
        in B.concat [sourceEncoded, destEncoded, instrsBS]

toLittleEndian :: (Bits t, Integral t) => [t] -> B.ByteString
toLittleEndian nums = case nums of
    (n:ns) -> B.pack $ map fromIntegral $ reverse $ n:map (`setBit` 7) ns
    []     -> ""

instance Byteable DeltaInstruction where
    toBytes (InsertInstruction content) =
        B.singleton (fromIntegral $ B.length content) `B.append` content
    toBytes (CopyInstruction offset 0x10000) =
        toBytes $ CopyInstruction offset 0
    toBytes (CopyInstruction offset size) = let
        offsetBytes = toByteList offset
        lenBytes    = toByteList size
        offsetBits  = map (>0) offsetBytes
        lenBits     = map (>0) lenBytes
        bools       = True:padFalse lenBits 3 ++ padFalse offsetBits 4
        firstByte   = fromIntegral $ boolsToByte 0 bools
        encodedOff  = encode offsetBytes
        encodedLen  = encode lenBytes
        in B.concat [B.singleton firstByte, encodedOff, encodedLen]
        where encode = B.pack . map fromIntegral . reverse . filter (>0)
              padFalse :: [Bool] -> Int -> [Bool]
              padFalse bits len = let
                pad = len - length bits
                in bool bits (replicate pad False ++ bits) (pad > 0)
              boolsToByte :: Int -> [Bool] -> Int
              boolsToByte = foldl' (\acc b -> shiftL acc 1 + fromEnum b)

fullObject :: PackObjectType -> Bool
fullObject t = t `elem` [CommitObject, TreeObject, BlobObject, TagObject]

packObjectType :: (Bits t, Integral t) => t -> PackObjectType
packObjectType header = toEnum . fromIntegral $ (header `shiftR` 4) .&. 7

toAssoc :: PackIndexEntry -> (Int, Ref)
toAssoc (PackIndexEntry o r _) = (o, r)

getCRC :: PackIndexEntry -> Word32
getCRC (PackIndexEntry _ _ c) = c

emptyCombinedMap :: CombinedMap
emptyCombinedMap = CombinedMap Map.empty Map.empty

emptyObjectMap :: ObjectMap
emptyObjectMap = ObjectMap Map.empty Map.empty

insertObject :: Int -> PackedObject -> ObjectMap -> ObjectMap
insertObject offset object@(PackedObject _ r _) ObjectMap {..} = let
    getObjectMap'   = Map.insert offset object getObjectMap
    getObjectIndex' = Map.insert r      offset getObjectIndex
    in ObjectMap getObjectMap' getObjectIndex'

fromBytes :: (Bits t, Integral t) => B.ByteString -> t
fromBytes = B.foldl' (\a b -> (a `shiftL` 8) + fromIntegral b) 0

toSomeBitList :: (Bits t, Integral t) => Int -> t -> [t]
toSomeBitList some n = reverse $ toSomeBitList' some n
    where toSomeBitList' some n = case divMod n (bit some) of
            (0, i) -> [fromIntegral i]
            (x, y) ->  fromIntegral y : toSomeBitList' some x

toByteList, to7BitList :: (Bits t, Integral t) => t -> [t]
toByteList = toSomeBitList 8
to7BitList = toSomeBitList 7

fifthOffsets :: B.ByteString -> [Int]
fifthOffsets ""   = []
fifthOffsets bstr = fromBytes (B.take 8 bstr):fifthOffsets (B.drop 8 bstr)

fixOffsets :: [Int] -> Int -> Int
fixOffsets fOffsets offset
    | offset < msb = offset
    | otherwise    = fOffsets !! (offset-msb)
    where msb = bit 31

packIndexEntries :: CombinedMap -> [PackIndexEntry]
packIndexEntries CombinedMap {..} = let
    crc32s     = Map.map (crc32 . toBytes) getOffsetMap
    offsetRefs = Map.toList getRefIndex
    in map (\(r, o) -> PackIndexEntry o r (crc32s Map.! o)) offsetRefs
