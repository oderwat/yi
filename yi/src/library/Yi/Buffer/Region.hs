{-# LANGUAGE CPP #-}
{-# OPTIONS_HADDOCK show-extensions #-}

-- |
-- Module      :  Yi.Buffer.Region
-- License     :  GPL-2
-- Maintainer  :  yi-devel@googlegroups.com
-- Stability   :  experimental
-- Portability :  portable
--
-- This module defines buffer operation on regions

module Yi.Buffer.Region
  (
   module Yi.Region
  , swapRegionsB
  , deleteRegionB
  , replaceRegionB
  , replaceRegionClever
  , readRegionB
  , mapRegionB
  , modifyRegionB
  , modifyRegionClever
  , winRegionB
  , inclusiveRegionB
  , blockifyRegion
  , joinLinesB
  , concatLinesB
  )
where

import           Control.Applicative
import           Control.Lens hiding (transform)
import           Control.Monad
import           Data.Algorithm.Diff
import           Data.List (sort)
import qualified Data.Text as T
import           Yi.Buffer.Misc
import           Yi.Region
import           Yi.Rope (YiString)
import qualified Yi.Rope as R
import           Yi.String (lines')
import           Yi.Utils
import           Yi.Window (winRegion)

winRegionB :: BufferM Region
winRegionB = askWindow winRegion

-- | Delete an arbitrary part of the buffer
deleteRegionB :: Region -> BufferM ()
deleteRegionB r = deleteNAt (regionDirection r) (fromIntegral (regionEnd r ~- regionStart r)) (regionStart r)

readRegionB :: Region -> BufferM YiString
readRegionB r = nelemsB (fromIntegral (regionEnd r - i)) i
    where i = regionStart r

-- | Replace a region with a given rope.
replaceRegionB :: Region -> YiString -> BufferM ()
replaceRegionB r s = do
  deleteRegionB r
  insertNAt s $ regionStart r

-- TODO: reimplement 'getGroupedDiff' for Ropes, so we can use
-- 'replaceRegionClever' on large regions.
-- TODO2: …do above or do the same for Text

-- | As 'replaceRegionB, but do a minimal edition instead of deleting
-- the whole region and inserting it back.
--
-- Due to use of 'getGroupedDiff', we convert to and from 'String'
-- which means it might actually be faster to delete and insert a
-- whole region as long as we do it over 'YiString'.
replaceRegionClever :: Region -> YiString -> BufferM ()
replaceRegionClever region text' = savingExcursionB $ do
    text <- readRegionB region
    let diffs = getGroupedDiff (R.toString text) (R.toString text')
    moveTo (regionStart region)
    forM_ diffs $ \d -> case d of
      First str -> deleteN $ length str
      Both str _ -> rightN $ length str
      Second str -> insertN (R.fromString str)

-- | TODO: implement map over 'YiString'.
mapRegionB :: Region -> (Char -> Char) -> BufferM ()
mapRegionB r f = do
  text <- readRegionB r
  replaceRegionB r (R.withText (T.map f) text)

-- | Swap the content of two Regions
swapRegionsB :: Region -> Region -> BufferM ()
swapRegionsB r r'
    | regionStart r > regionStart r' = swapRegionsB r' r
    | otherwise = do w0 <- readRegionB r
                     w1 <- readRegionB r'
                     replaceRegionB r' w0
                     replaceRegionB r  w1

-- Transform a replace into a modify.
replToMod :: (Region -> a -> BufferM b) -- ^ Replacer
          -> (R.YiString -> a) -- ^ region transformer
             -> Region -- ^ Region to transform
             -> BufferM b
replToMod replace f region = f <$> readRegionB region >>= replace region

-- | Modifies the given region according to the given
-- string transformation function
modifyRegionB :: (R.YiString -> R.YiString)
                 -- ^ The string modification function
              -> Region
                 -- ^ The region to modify
              -> BufferM ()
modifyRegionB = replToMod replaceRegionB

-- | As 'modifyRegionB', but do a minimal edition instead of deleting the whole
-- region and inserting it back.
modifyRegionClever :: (R.YiString -> R.YiString) -> Region -> BufferM ()
modifyRegionClever = replToMod replaceRegionClever

-- | Extend the right bound of a region to include it.
inclusiveRegionB :: Region -> BufferM Region
inclusiveRegionB r =
          if regionStart r <= regionEnd r
              then mkRegion (regionStart r) <$> pointAfterCursorB (regionEnd r)
              else mkRegion <$> pointAfterCursorB (regionStart r) <*> pure (regionEnd r)

-- | See a region as a block/rectangular region,
-- since regions are represented by two point, this returns
-- a list of small regions form this block region.
blockifyRegion :: Region -> BufferM [Region]
blockifyRegion r = savingPointB $ do
  [lowCol,highCol] <- sort <$> mapM colOf [regionStart r, regionEnd r]
  startLine <- lineOf $ regionStart r
  endLine   <- lineOf $ regionEnd r
  when (startLine > endLine) $ fail "blockifyRegion: impossible"
  mapM (\line -> mkRegion <$> pointOfLineColB line lowCol <*> pointOfLineColB line (1 + highCol))
       [startLine..endLine]

-- | Joins lines in the region with a single space, skipping any empty
-- lines.
joinLinesB :: Region -> BufferM ()
joinLinesB = savingPointB . modifyRegionClever (withT g')
  where
    -- TODO yi-rope init
    withT f = R.fromText . f . R.toText
    g' = over _init $ T.concat . over _tail pad . lines'
    pad :: [T.Text] -> [T.Text]
    pad = fmap $ skip (T.cons ' ' . T.stripStart)
    skip g x = if T.null x then x else g x


-- | Concatenates lines in the region preserving the trailing newline
-- if any.
concatLinesB :: Region -> BufferM ()
concatLinesB = savingPointB . modifyRegionClever f
  where
    -- TODO: yi-rope init
    f = R.fromText . over _init (T.filter (/= '\n')) . R.toText
