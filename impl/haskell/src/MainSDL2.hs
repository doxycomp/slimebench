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

import Control.Monad (when)
import Data.Word (Word8)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (castPtr)
import qualified Data.ByteString.Unsafe as BU
import qualified Data.Text as T
import qualified SDL

import qualified Hud
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
  -- The overlay carries the interactive state, so the loop threads it along
  -- with the simulation. `sim` is threaded too: editing a parameter replaces
  -- the config with a record update, which shares every mutable array and so
  -- costs nothing in the tick -- the alternative, an IORef in Sim, would put
  -- an indirection in the hot loop and change what class S measures.
  let hud0 = Hud.newHud "Haskell / SDL2" (not roJson)
      view0 = Hud.HudView
        { Hud.hvWidth = cfgWidth, Hud.hvHeight = cfgHeight
        , Hud.hvAgents = cfgAgents, Hud.hvThreads = max 1 cfgThreads
        , Hud.hvRotSteps = cfgRotSteps, Hud.hvDeposit = cfgDeposit
        , Hud.hvDecay = cfgDecay, Hud.hvSensorDist = cfgSensorDist
        , Hud.hvStep = cfgStep, Hud.hvDeferred = True }
      loop !i !sm !hud !view !bright
        | i >= frames = pure ()
        | otherwise = do
            evs <- SDL.pollEvents
            let (hud1, view1, bright1) =
                  foldl applyEvent (hud, view, bright) evs
            if Hud.hQuit hud1 then pure () else do
              sm1 <- if Hud.hReset hud1 then newSim (cfgOf sm view1)
                                        else pure (withView sm view1)
              let hud2 = if Hud.hReset hud1
                           then hud1 { Hud.hReset = False, Hud.hTick = 0 }
                           else hud1
              hud3 <- if Hud.hHash hud2
                        then do
                          g <- hashGrid sm1
                          a <- hashAgents sm1
                          hPutStrLn stderr $ printf
                            "grid 0x%08X  agents 0x%08X  tick %d%s"
                            g a (Hud.hTick hud2)
                            (if Hud.hEdited hud2 then "  EDITED" else ""
                              :: String)
                          pure hud2 { Hud.hHash = False }
                        else pure hud2
              let runIt = not roFreeze && not (Hud.hFrozen hud3)
                          && (not (Hud.hPaused hud3) || Hud.hStepOnce hud3)
              !s0 <- nowNs
              when runIt (tick sm1)
              !s1 <- nowNs
              let hud4 = if runIt
                           then hud3 { Hud.hTick = Hud.hTick hud3 + 1
                                     , Hud.hStepOnce = False }
                           else hud3
              !r0 <- nowNs
              withForeignPtr fp $ \p -> do
                renderArgbPtr sm1 bright1 p
                Hud.draw 4 p hud4 view1 bright1
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
              let hud5 = Hud.smooth (fromIntegral (s1 - s0) / 1e6)
                                    (fromIntegral (r1 - r0) / 1e6) hud4

              n <- sinceTitle stats
              when (n >= 60) $ do
                ms <- recentMean stats 60
                SDL.windowTitle window SDL.$= T.pack (titleFor "SDL2" ms)
                resetTitle stats
              loop (i + 1) sm1 hud5 view1 bright1
      cfgOf sm v = (simCfg sm)
        { cfgDeposit = Hud.hvDeposit v, cfgDecay = Hud.hvDecay v
        , cfgSensorDist = Hud.hvSensorDist v, cfgStep = Hud.hvStep v
        , cfgRotSteps = Hud.hvRotSteps v }
      withView sm v = sm { simCfg = cfgOf sm v }
  loop (0 :: Int) sim hud0 view0 roDisplayMax

  SDL.destroyTexture tex
  SDL.destroyRenderer renderer
  SDL.destroyWindow window
  SDL.quit

  when roJson $ statsJson stats cfg "sdl2" >>= mapM_ putStrLn

-- | One SDL event folded into the overlay state. Key codes live here and
-- named actions live in Hud, for the reason that header gives: SDL2 and
-- raylib spell the same key differently.
applyEvent :: (Hud.Hud, Hud.HudView, Float) -> SDL.Event
           -> (Hud.Hud, Hud.HudView, Float)
applyEvent (h, v, b) e = case SDL.eventPayload e of
  SDL.QuitEvent -> (h { Hud.hQuit = True }, v, b)
  SDL.KeyboardEvent k
    | SDL.keyboardEventKeyMotion k == SDL.Pressed ->
        maybe (h, v, b) (\a -> Hud.act a h v b)
              (lookup (SDL.keysymKeycode (SDL.keyboardEventKeysym k)) keymap)
  _ -> (h, v, b)

keymap :: [(SDL.Keycode, String)]
keymap =
  [ (SDL.KeycodeEscape, "quit"), (SDL.KeycodeQ, "quit")
  , (SDL.KeycodeSpace, "pause"), (SDL.KeycodeN, "step")
  , (SDL.KeycodeR, "reset"), (SDL.KeycodeTab, "hud")
  , (SDL.KeycodeH, "help"), (SDL.KeycodeF1, "help")
  , (SDL.KeycodeC, "hash"), (SDL.KeycodeF, "freeze")
  , (SDL.Keycode1, "deposit-"), (SDL.Keycode2, "deposit+")
  , (SDL.Keycode3, "decay-"), (SDL.Keycode4, "decay+")
  , (SDL.Keycode5, "sensor-"), (SDL.Keycode6, "sensor+")
  , (SDL.Keycode7, "step-"), (SDL.Keycode8, "step+")
  , (SDL.Keycode9, "rot-"), (SDL.Keycode0, "rot+")
  , (SDL.KeycodeMinus, "bright-"), (SDL.KeycodeEquals, "bright+")
  ]
