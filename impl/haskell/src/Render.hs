{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

-- | Shared render-timing helper for the windowed Haskell frontends
-- (SPEC-1 11.1).
--
-- A rendering backend benchmark measures the upload path
-- grid -> texture -> screen. If the simulation keeps running during the
-- measurement it dominates the frame and the backends come out
-- indistinguishable, so @--freeze-sim@ stops it and every frame re-uploads
-- the same grid. Same contract and the same JSON as @impl/c/sb_render.h@.
module Render
  ( Stats
  , newStats
  , addFrame
  , recentMean
  , sinceTitle
  , resetTitle
  , statsJson
  ) where

import Data.IORef
import Data.List (sort)
import Data.Word (Word64)
import Text.Printf (printf)

import Sim (Config (..))

data Stats = Stats
  { stMs    :: !(IORef [Double])   -- ^ reversed; the caller never sees the order
  , stCount :: !(IORef Int)
  , stTitle :: !(IORef Int)
  }

newStats :: IO Stats
newStats = Stats <$> newIORef [] <*> newIORef 0 <*> newIORef 0

addFrame :: Stats -> Word64 -> IO ()
addFrame s !ns = do
  modifyIORef' (stMs s) ((fromIntegral ns / 1e6 :: Double) :)
  modifyIORef' (stCount s) (+ 1)
  modifyIORef' (stTitle s) (+ 1)

recentMean :: Stats -> Int -> IO Double
recentMean s k = do
  xs <- readIORef (stMs s)
  let take' = take k xs
  pure $ if null take' then 0 else sum take' / fromIntegral (length take')

sinceTitle :: Stats -> IO Int
sinceTitle = readIORef . stTitle

resetTitle :: Stats -> IO ()
resetTitle s = writeIORef (stTitle s) 0

statsJson :: Stats -> Config -> String -> IO (Maybe String)
statsJson s Config{..} backend = do
  xs <- reverse <$> readIORef (stMs s)
  if null xs then pure Nothing else do
    let n = length xs
        srt = sort xs
        median = srt !! (n `div` 2)
        p99 = srt !! min (n - 1) (floor (fromIntegral n * 0.99 :: Double))
        mean = sum xs / fromIntegral n
        mpix = fromIntegral cfgWidth * fromIntegral cfgHeight / 1e6 :: Double
    pure . Just $ printf
      ("{\"schema\":1,\"impl\":\"haskell\",\"backend\":\"%s\",\"class\":\"R\","
       ++ "\"preset\":\"%s\",\"width\":%d,\"height\":%d,\"frames\":%d,"
       ++ "\"ms_render_mean\":%.6f,\"ms_render_median\":%.6f,"
       ++ "\"ms_render_p99\":%.6f,\"fps_equiv\":%.2f,\"mpixels_per_s\":%.1f}")
      backend cfgPreset cfgWidth cfgHeight n
      mean median p99
      (if median > 0 then 1000 / median else 0)
      (if median > 0 then mpix * 1000 / median else 0)
