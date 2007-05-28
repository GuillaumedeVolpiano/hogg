--
-- Module      : Chop
-- Copyright   : (c) Conrad Parker 2006
-- License     : BSD-style
-- Maintainer  : conradp@cse.unsw.edu.au
-- Stability   : experimental
-- Portability : portable

module Codec.Container.Ogg.Chop (
  chainAddSkeletonG, -- XXX: For debugging only, TO BE REMOVED
  chop
) where

import Control.Monad.Identity
import Control.Monad.State

import qualified Data.ByteString.Lazy as L
import qualified Data.Map as Map
import Data.Maybe

import Codec.Container.Ogg.Chain
import Codec.Container.Ogg.ContentType
import Codec.Container.Ogg.Granulepos
import Codec.Container.Ogg.ListMerge
import Codec.Container.Ogg.Page
import Codec.Container.Ogg.Packet
import Codec.Container.Ogg.Serial
import Codec.Container.Ogg.Skeleton
import Codec.Container.Ogg.Timestamp
import Codec.Container.Ogg.Track

------------------------------------------------------------
-- Types
--

type ChopState = Map.Map OggTrack ChopTrackState

data ChopTrackState =
  ChopTrackState {
    ctsBOS :: [OggPage],
    ctsHdrs :: [OggPage],
    
    headersRemaining :: Int,

    -- Greatest previously inferred keyframe value
    prevK :: Integer,

    -- Just to spice things up (and simplify the algorithm)
    -- the page accumulator is kept in reverse order
    pageAccum :: [OggPage],

    -- Whether or not this track has delivered beyond the chop end
    ended :: Bool
  }

type Chop a = (StateT ChopState Identity) a

-- | chop start end chain
chop :: Bool -> Maybe Timestamp -> Maybe Timestamp -> OggChain -> OggChain
chop skel start end chain =
  fst $ runChop emptyChopState (chopTop skel start end chain)

emptyChopState :: ChopState
emptyChopState = Map.empty

emptyChopTrackState :: ChopTrackState
emptyChopTrackState = ChopTrackState [] [] 0 0 [] False

runChop :: ChopState -> Chop a -> (a, ChopState)
runChop st x = runIdentity (runStateT x st)

-- | Top-level bitstream chopper -- handles headers
chopTop :: Bool -> Maybe Timestamp -> Maybe Timestamp -> OggChain
        -> Chop OggChain
chopTop skel mStart mEnd (OggChain tracks pages _) = do
  let chopT = if skel then chopTop' else chopTopN'
  pages' <- chopT mStart mEnd pages
  let packets' = pagesToPackets pages' 
  return $ OggChain tracks pages' packets'

chopTop' :: Maybe Timestamp -> Maybe Timestamp -> [OggPage] -> Chop [OggPage]
chopTop' _ _ [] = return []
chopTop' Nothing Nothing gs = return gs
chopTop' Nothing mEnd@(Just _) gs = chopTo mEnd gs
chopTop' (Just start) mEnd (g:gs)
  | pageBOS g = do
    pushBOS g -- Remember this BOS page
    chopTop' (Just start) mEnd gs
  | otherwise = do
    p <- doneHeaders
    case p of
      False -> do
        pushHdr g -- Remember this header
        chopTop' (Just start) mEnd gs
      _  -> chopCtrl (Just start) mEnd (g:gs)

pushBOS :: OggPage -> Chop ()
pushBOS g = do
    addHeaders g -- Add the number of headers for this track
    subHeaders g -- Subtract the number contained in this page
    m <- get
    let st = Map.findWithDefault emptyChopTrackState t m
        m' = Map.insert t st{ctsBOS = [g]} m
    put m'
  where
    t = pageTrack g

pushHdr :: OggPage -> Chop ()
pushHdr g = do
    subHeaders g -- Subtract the number contained in this page
    m <- get
    let st = Map.findWithDefault emptyChopTrackState t m
        hdrs = ctsHdrs st
        m' = Map.insert t st{ctsHdrs = hdrs++[g]} m
    put m'
  where
    t = pageTrack g

-- | Dump the control section
chopCtrl :: Maybe Timestamp -> Maybe Timestamp -> [OggPage] -> Chop [OggPage]
chopCtrl mStart mEnd gs = do
    boss <- popBOSs
    hdrs <- popHdrs
    cs <- chopRaw mStart mEnd gs
    return $ boss ++ hdrs ++ cs

popBOSs :: Chop [OggPage]
popBOSs = popPages ctsBOS

popHdrs :: Chop [OggPage]
popHdrs = popPages ctsHdrs

popPages :: (ChopTrackState -> [OggPage]) -> Chop [OggPage]
popPages f = do
    m <- get
    let gs = Map.fold (\a b -> (f a)++b) [] m
    return gs

-- | A version of ChopTop that does not add a Skeleton bitstream
chopTopN' :: Maybe Timestamp -> Maybe Timestamp -> [OggPage] -> Chop [OggPage]
chopTopN' _ _ [] = return []
chopTopN' Nothing Nothing gs = return gs
chopTopN' Nothing mEnd@(Just _) gs = chopTo mEnd gs
chopTopN' (Just start) mEnd (g:gs)
  | pageBOS g = do
    addHeaders g -- Add the number of headers for this track
    subHeaders g -- Subtract the number contained in this page
    cs <- chopTop' (Just start) mEnd gs
    return $ g : cs
  | otherwise = do
    p <- doneHeaders
    case p of
      False -> do
        subHeaders g -- Subtract the number contained in this page
        cs <- chopTop' (Just start) mEnd gs
        return $ g : cs
      _  -> chopRaw (Just start) mEnd (g:gs)

-- | Raw bitstream chopper -- after headers
chopRaw :: Maybe Timestamp -> Maybe Timestamp -> [OggPage] -> Chop [OggPage]
chopRaw _ _ [] = return []
chopRaw Nothing Nothing gs = return gs
chopRaw Nothing mEnd@(Just _) gs = chopTo mEnd gs
chopRaw (Just start) mEnd (g:gs) = case (timestampOf g) of
  Nothing -> do
    -- Add this page to accum buffer
    chopAccum g
    return g >> (chopRaw (Just start) mEnd gs)
  (Just gTime) -> do
    p <- changedK g
    case p of
      False -> do
        -- Add this page to accum buffer
        chopAccum g
      True -> do
        pruneAccum g
        setK g
        -- Add this page to accum buffer
        chopAccum g
    case (compare start gTime) of
      LT -> do
        -- Dump accum buffer into bitstream
        as <- getAccum
        cs <- chopRaw Nothing mEnd gs
        return $ as ++ cs
      _  -> do
        chopRaw (Just start) mEnd gs

-- | Chop to the specified end time
chopTo :: Maybe Timestamp -> [OggPage] -> Chop [OggPage]
chopTo _ [] = return []
chopTo mEnd (g:gs)
  | before mEnd g = do
      cs <- chopTo mEnd gs
      return $ g : cs
  | otherwise = chopEnd mEnd (g:gs)

-- | Handle last pages of all tracks
chopEnd :: Maybe Timestamp -> [OggPage] -> Chop [OggPage]
chopEnd _ [] = return []
chopEnd mEnd (g:gs) = do
    m <- get
    ts <- Map.lookup (pageTrack g) m
    case (ended ts) of
      True -> do
        isEnded <- allEnded
        case isEnded of
          True -> return []
          False -> chopEnd mEnd gs
      False -> do
        let m' = Map.adjust (\ts' -> ts'{ended = True}) (pageTrack g) m
        put m'
        cs <- chopEnd mEnd gs
        return $ g{pageEOS = True} : cs

-- | Determine whether all tracks are ended
allEnded :: Chop Bool
allEnded = do
    m <- get
    return $ Map.fold (\x b -> ended x && b) True m

-- | Get prevK for a given track
getK :: OggPage -> Chop Integer
getK g = do
  m <- get
  ts <- Map.lookup (pageTrack g) m
  let c = prevK ts
  return c

-- | Set prevK for a given track
setK :: OggPage -> Chop ()
setK g = case (pageGranulepos g) of
  Granulepos Nothing -> return ()
  _ -> do
    m <- get
    let k = fromJust $ pageKeyGranule g
        m' = Map.adjust (s' k) (pageTrack g) m
    put m'
  where
    s' k ts = ts{prevK = k}

-- | Has the K part of the granulepos changed?
changedK :: OggPage -> Chop Bool
changedK g = case (pageGranulepos g) of
  Granulepos Nothing -> return False
  _ -> do
    c <- getK g
    let k = fromJust $ pageKeyGranule g
    return (k /= c)

-- | Accumulate a page
chopAccum :: OggPage -> Chop ()
chopAccum g = case (trackGranuleshift t) of
    Nothing -> return ()
    _ -> do
      m <- get
      let m' = Map.adjust (chopTrackAccum g) t m
      put m'
  where
    t = pageTrack g

chopTrackAccum :: OggPage -> ChopTrackState -> ChopTrackState
chopTrackAccum g ts = ts{pageAccum = (g:gs)}
  where gs = pageAccum ts

-- | Prune accumulated pages
pruneAccum :: OggPage -> Chop ()
pruneAccum g = case (trackGranuleshift t) of
    Nothing -> return ()
    _ -> do
      m <- get
      k <- getK g
      let m' = Map.adjust (pruneTrackAccum g k) t m
      put m'
  where
    t = pageTrack g

pruneTrackAccum :: OggPage -> Integer -> ChopTrackState -> ChopTrackState
pruneTrackAccum g k ts = ts{pageAccum = g:gs}
  where
    as = pageAccum ts
    t = pageTrack g
    gs = takeWhileB later as
    later x = case (pageGranulepos x) of
      Granulepos Nothing -> True
      _ -> (fromJust $ gpToGranules (pageGranulepos x) t) >= k

-- | get accumulated pages
getAccum :: Chop [OggPage]
getAccum = do
  m <- get
  let accums = Map.fold (\x b -> (reverse . pageAccum) x : b) [] m
      as = listMerge accums
  return as

-- | Add the total number of headers that this track expects
addHeaders :: OggPage -> Chop ()
addHeaders g = do
  let t = pageTrack g
      h = headers $ fromJust (trackType t)
  modifyHeaders t h

-- | Subtract the number of completed header packets provided by this page
subHeaders :: OggPage -> Chop ()
subHeaders g = do
  let segs = length $ pageSegments g
      incmplt = pageIncomplete g
      n = if incmplt then (segs-1) else segs
  modifyHeaders (pageTrack g) (-n)

-- | State modifier to change the number of headers remaining
modifyHeaders :: OggTrack -> Int -> Chop ()
modifyHeaders t n = do
  m <- get
  let st = Map.findWithDefault emptyChopTrackState t m
      r = headersRemaining st
      m' = Map.insert t st{headersRemaining = r + n} m
  put m'

-- | Determine whether all tracks have no headers remaining
doneHeaders :: Chop Bool
doneHeaders = do
  m <- get
  return $ Map.fold (\t b -> (headersRemaining t <= 0) && b) True m

-- | a version of takeWhile that includes the first bounding failure
takeWhileB :: (a -> Bool) -> [a] -> [a]
takeWhileB _ [] = []
takeWhileB p (x:xs) = if p x then x : takeWhileB p xs
                      else [x]

------------------------------------------------------------
-- chainAddSkeletonG -- Version of chainAddSKeleton working on pages
--

-- | Add a Skeleton logical bitstream to an OggChain
chainAddSkeletonG :: OggChain -> IO OggChain
chainAddSkeletonG chain = do
  serialno <- genSerial
  return $ chainAddSkeletonG' serialno chain

-- | Add a Skeleton logical bitstream with a given serialno to an OggChain
chainAddSkeletonG' :: Serial -> OggChain -> OggChain
chainAddSkeletonG' serialno (OggChain tracks pages _) = OggChain nt ng np
  where
    nt = skelTrack : tracks
    ng = fh : concat [ixBoss, ixFisbones, ixHdrs, [sEOS], ixD]
    np = pagesToPackets ng

    -- Construct a new track for the Skeleton
    skelTrack = (newTrack serialno){trackType = Just skeleton}

    -- Create the fishead and fisbone packets (all with pageIx 0)
    fh = fisheadToPage skelTrack emptyFishead
    fbs = map (fisboneToPage skelTrack) $ tracksToFisbones tracks

    -- Separate out the BOS pages of the input
    (boss, rest) = span pageBOS pages

    -- Increment the pageIx of these original BOS pages by 1, as the
    -- Skeleton fishead packet is being prepended
    -- ixBoss = map (incPageIx 1) boss
    ixBoss = boss

    -- Split the remainder of the input into headers and data
    (hdrs, d) = splitAt totHeaders rest

    -- ... for which we determine the total number of header pages
    totHeaders = sum tracksNHeaders
    tracksNHeaders = map headers $ mapMaybe trackType tracks

    -- Increment the pageIx of the original data packets by the number of
    -- Skeleton pages
    -- ixHdrs = map (incPageIx (1 + length fbs)) hdrs
    -- ixD = map (incPageIx (2 + length fbs)) d
    ixHdrs = hdrs
    ixD = d

    -- Set the pageIx of the fisbones in turn, beginning after the last
    -- BOS page
    -- ixFisbones = zipWith setPageIx [1+(length tracks)..] fbs
    ixFisbones = fbs

    -- Generate an EOS page for the Skeleton track
    sEOS = (uncutPage L.empty skelTrack sEOSgp){pageEOS = True}
    sEOSgp = Granulepos (Just 0)

{-
-- An internal function for setting the pageIx of the segment of a packet.
-- This is only designed for working with packets which are known to only
-- and entirely span one page, such as Skeleton fisbones.
setPageIxG :: Int -> OggPage -> OggPacket
setPageIxG ix p@(OggPacket _ _ _ _ _ (Just [oldSegment])) =
  p{packetSegments = Just [newSegment]}
  where
    newSegment = oldSegment{segmentPageIx = ix}
setPageIx _ _ = error "setPageIx used on non-uncut page"

-- An internal function for incrementing the pageIx of all the segments of
-- a packet.
incPageIx :: Int -> OggPacket -> OggPacket
incPageIx ixd p@(OggPacket _ _ _ _ _ (Just segments)) =
  p{packetSegments = Just (map incSegIx segments)}
  where
    incSegIx :: OggSegment -> OggSegment
    incSegIx s@(OggSegment _ oix _) = s{segmentPageIx = oix + ixd}
-- Otherwise, the packet has no segmentation info so leave it untouched
incPageIx _ p = p
-}
