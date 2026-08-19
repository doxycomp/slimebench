{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | slimebench -- Haskell + SDL2 frontend (benchmark class R).
--
-- Uses the @sdl2@ package, which is a real binding with a Haskell-shaped API
-- (a type for the pixel format, 'V2' for sizes, textures behind a newtype),
-- not a thin @foreign import@ layer. That is deliberate: it is what a Haskell
-- programmer would reach for, so it is what should be measured.
--
-- SDL2 has no 8-bit greyscale texture, so the frame is expanded to ARGB8888
-- by 'renderArgbPtr' -- one poke loop over four million pixels. The raylib
-- frontend has no equivalent loop, and in the C measurement that asymmetry
-- was most of the gap between the two backends.
module Main (main) where

import Control.Monad (unless, when)
import Data.Word (Word8)
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (castPtr)
import qualified Data.ByteString.Unsafe as BU
import qualified Data.Text as T
import qualified SDL

import Render
import RenderCli (RenderOpts (..), parseRenderArgs, titleFor)
import Sim

main :: IO ()
main = do
  RenderOpts{..} <- parseRenderArgs
  let cfg@Config{..} = roCfg
      !frames = if cfgTicks == 0 then 100000 else cfgTicks
      !cells = cfgWidth * cfgHeight

  sim <- newSim cfg

  SDL.initialize [SDL.InitVideo]
  window <- SDL.createWindow "slimebench -- Haskell / SDL2"
    SDL.defaultWindow { SDL.windowInitialSize =
                          SDL.V2 (fromIntegral cfgWidth) (fromIntegral cfgHeight) }
  renderer <- SDL.createRenderer window (-1) SDL.defaultRenderer
  tex <- SDL.createTexture renderer SDL.ARGB8888 SDL.TextureAccessStreaming
           (SDL.V2 (fromIntegral cfgWidth) (fromIntegral cfgHeight))

  -- One staging buffer for the whole run; allocating per frame would measure
  -- the allocator rather than the backend.
  fp <- mallocForeignPtrBytes (cells * 4) :: IO (ForeignPtr Word8)

  stats <- newStats
  let loop !i
        | i >= frames = pure ()
        | otherwise = do
            evs <- SDL.pollEvents
            unless (any isQuit evs) $ do
              unless roFreeze (tick sim)
              !r0 <- nowNs
              withForeignPtr fp $ \p -> do
                renderArgbPtr sim roDisplayMax p
                -- Zero-copy view of the staging buffer; the ByteString does
                -- not outlive this block.
                bs <- BU.unsafePackCStringLen (castPtr p, cells * 4)
                _ <- SDL.updateTexture tex Nothing bs (fromIntegral (cfgWidth * 4))
                pure ()
              SDL.clear renderer
              SDL.copy renderer tex Nothing Nothing
              SDL.present renderer
              !r1 <- nowNs
              addFrame stats (r1 - r0)

              n <- sinceTitle stats
              when (n >= 60) $ do
                ms <- recentMean stats 60
                SDL.windowTitle window SDL.$= T.pack (titleFor "SDL2" ms)
                resetTitle stats
              loop (i + 1)
  loop (0 :: Int)

  SDL.destroyTexture tex
  SDL.destroyRenderer renderer
  SDL.destroyWindow window
  SDL.quit

  when roJson $ statsJson stats cfg "sdl2" >>= mapM_ putStrLn

isQuit :: SDL.Event -> Bool
isQuit e = case SDL.eventPayload e of
  SDL.QuitEvent -> True
  SDL.KeyboardEvent k ->
    SDL.keyboardEventKeyMotion k == SDL.Pressed
      && SDL.keysymKeycode (SDL.keyboardEventKeysym k) == SDL.KeycodeEscape
  _ -> False
