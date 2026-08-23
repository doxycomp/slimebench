-- | The on-screen overlay, drawn into the pixel buffer the frontends already
-- fill -- ARGB8888 for SDL2, 8-bit greyscale for raylib.
--
-- impl/c/sb_hud.h explains the design; this is that design in Haskell, with
-- the same five status lines, the same help text, the same scale rule and the
-- same @edited@ flag. Like the C header it knows nothing about a simulation:
-- it reads and writes a plain 'HudView' of scalars, so the SDL2 and raylib
-- frontends share it unchanged.
--
-- Nothing here affects a measured number. The overlay is off whenever
-- @--json@ is in play, because a window being measured must not spend its
-- frame time drawing text about itself.
module Hud
  ( HudView(..)
  , Hud(..)
  , newHud
  , viewFromConfig
  , draw
  , act
  , smooth
  , scaleFor
  , helpLines
  ) where

import Data.Word (Word8)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekByteOff, pokeByteOff)
import Text.Printf (printf)

import Font (glyphFor, glyphH, glyphW)

-- | The scalars the overlay shows, copied out of the config by the caller.
data HudView = HudView
  { hvWidth      :: !Int
  , hvHeight     :: !Int
  , hvAgents     :: !Int
  , hvThreads    :: !Int
  , hvRotSteps   :: !Int
  , hvDeposit    :: !Float
  , hvDecay      :: !Float
  , hvSensorDist :: !Float
  , hvStep       :: !Float
  , hvDeferred   :: !Bool
  }

data Hud = Hud
  { hShow     :: !Bool
  , hHelp     :: !Bool
  , hPaused   :: !Bool
  , hStepOnce :: !Bool
  , hQuit     :: !Bool
  , hReset    :: !Bool
  , hHash     :: !Bool
  , hFrozen   :: !Bool
  , hEdited   :: !Bool
  , hTick     :: !Int
  , hSimMs    :: !Double
  , hDrawMs   :: !Double
  , hLabel    :: !String
  }

newHud :: String -> Bool -> Hud
newHud label vis = Hud
  { hShow = vis, hHelp = False, hPaused = False, hStepOnce = False
  , hQuit = False, hReset = False, hHash = False, hFrozen = False
  , hEdited = False, hTick = 0, hSimMs = 0, hDrawMs = 0, hLabel = label }

-- | Exponential smoothing, so the numbers can be read while they move.
smooth :: Double -> Double -> Hud -> Hud
smooth sim drw h =
  h { hSimMs = hSimMs h * 0.9 + sim * 0.1
    , hDrawMs = hDrawMs h * 0.9 + drw * 0.1 }

viewFromConfig :: Int -> Int -> Int -> Int -> Int
               -> Float -> Float -> Float -> Float -> Bool -> HudView
viewFromConfig = HudView

-- | sb_hud_scale: about ninety characters across, clamped to readable.
scaleFor :: Int -> Int
scaleFor w = max 1 (min 4 (w `div` 560))

helpLines :: [String]
helpLines =
  [ "KEYS"
  , "  SPACE    PAUSE / RESUME"
  , "  N        SINGLE STEP"
  , "  R        RESET SIMULATION"
  , "  TAB      HUD ON / OFF"
  , "  H  F1    THIS HELP"
  , "  C        PRINT HASHES TO STDERR"
  , "  F        FREEZE SIM (RENDER ONLY)"
  , "  1 / 2    DEPOSIT    DOWN / UP"
  , "  3 / 4    DECAY      DOWN / UP"
  , "  5 / 6    SENSOR     DOWN / UP"
  , "  7 / 8    STEP       DOWN / UP"
  , "  9 / 0    ROT STEPS  DOWN / UP"
  , "  - / =    BRIGHTNESS DOWN / UP"
  , "  Q  ESC   QUIT"
  , ""
  , "CHANGING A PARAMETER LEAVES THE SPEC-1"
  , "CONFIGURATION. THE RUN IS THEN MARKED"
  , "EDITED AND ITS HASHES REPRODUCE NOTHING."
  ]

-- ---------------------------------------------------------------------------
-- Pixels.
--
-- The two frontends hand over different buffers: SDL2 needs ARGB8888, which
-- renderArgbPtr fills as three grey bytes then alpha, and raylib takes the
-- 8-bit greyscale buffer directly. Both are grey, so the only difference is
-- the stride -- passed in as bytes per pixel rather than having two copies of
-- the glyph loop.

setPixel :: Int -> Ptr Word8 -> Int -> Int -> Int -> Int -> Word8 -> IO ()
setPixel bpp dst w h x y v
  | x < 0 || y < 0 || x >= w || y >= h = pure ()
  | otherwise = do
      let o = (y * w + x) * bpp
      mapM_ (\k -> pokeByteOff dst (o + k) v) [0 .. min bpp 3 - 1]

dimRect :: Int -> Ptr Word8 -> Int -> Int -> Int -> Int -> Int -> Int -> IO ()
dimRect bpp dst w h x0 y0 x1 y1 =
  mapM_ row [max 0 y0 .. min h y1 - 1]
  where
    row y = mapM_ (col y) [max 0 x0 .. min w x1 - 1]
    col y x = do
      let o = (y * w + x) * bpp
      v <- peekByteOff dst o :: IO Word8
      setPixel bpp dst w h x y (v `div` 4)

text :: Int -> Ptr Word8 -> Int -> Int -> Int -> Int -> Int -> String -> IO ()
text bpp dst w h px0 py sc = go px0
  where
    go _ [] = pure ()
    go px (c:cs) = do
      if c == ' ' then pure () else mapM_ (row px) [0 .. glyphH - 1]
      go (px + (glyphW + 1) * sc) cs
      where
        rows = glyphFor c
        row px' gy = mapM_ (cell px' gy) [0 .. glyphW - 1]
        cell px' gy gx
          | rows !! (gy * glyphW + gx) /= '#' = pure ()
          | otherwise =
              mapM_ (\(sx, sy) -> setPixel bpp dst w h (px' + gx * sc + sx)
                                            (py + gy * sc + sy) 255)
                    [(sx, sy) | sx <- [0 .. sc - 1], sy <- [0 .. sc - 1]]

-- | Draw the overlay in place. @bpp@ is 4 for ARGB8888, 1 for greyscale.
draw :: Int -> Ptr Word8 -> Hud -> HudView -> Float -> IO ()
draw bpp dst hud v displayMax
  | not (hShow hud) = pure ()
  | otherwise = do
      let w = hvWidth v
          h = hvHeight v
          sc = scaleFor w
          lh = (glyphH + 3) * sc
          pad = 4 * sc
          total = hSimMs hud + hDrawMs hud
          fps = if total > 0 then 1000 / total else 0 :: Double
          ls =
            [ printf "slimebench  %s  %dx%d  %d agents"
                (hLabel hud) w h (hvAgents v)
            , printf "tick %d   sim %.2f ms   draw %.2f ms   %.0f fps"
                (hTick hud) (hSimMs hud) (hDrawMs hud) fps
            , printf "deposit %.3f  decay %.3f  sensor %.1f  step %.2f  rot %d"
                (hvDeposit v) (hvDecay v) (hvSensorDist v) (hvStep v)
                (hvRotSteps v)
            , printf "update %s  threads %d  bright %.0f"
                (if hvDeferred v then "deferred" else "serial" :: String)
                (hvThreads v) displayMax
            , (if hPaused hud then "paused" else "running")
              ++ (if hEdited hud then "   edited -- not reproducible" else "")
              ++ "   h for help"
            ]
          bw = maximum (map length ls) * (glyphW + 1) * sc + 2 * pad
          bh = length ls * lh + 2 * pad
      dimRect bpp dst w h 0 0 bw bh
      mapM_ (\(i, s) -> text bpp dst w h pad (pad + i * lh) sc s)
            (zip [0 ..] ls)
      if not (hHelp hud) then pure () else do
        let hy = bh + pad
            hw = max bw (maximum (map length helpLines) * (glyphW + 1) * sc
                         + 2 * pad)
        dimRect bpp dst w h 0 (hy - pad) hw (hy + length helpLines * lh + pad)
        mapM_ (\(i, s) -> text bpp dst w h pad (hy + i * lh) sc s)
              (zip [0 ..] helpLines)

-- ---------------------------------------------------------------------------
-- Keyboard, as named actions rather than key codes: SDL2 and raylib disagree
-- about how a key is spelled, and sb_hud.h makes the same split for the same
-- reason.

-- | Apply one named action. Returns the new state and brightness.
--
-- Anything that moves a simulation parameter sets @edited@, which the status
-- line shows: the run has left the SPEC-1 configuration and its hashes no
-- longer reproduce anything.
act :: String -> Hud -> HudView -> Float -> (Hud, HudView, Float)
act a hud v bright = case a of
  "quit"    -> (hud { hQuit = True }, v, bright)
  "pause"   -> (hud { hPaused = not (hPaused hud) }, v, bright)
  "step"    -> (hud { hStepOnce = True, hPaused = True }, v, bright)
  "reset"   -> (hud { hReset = True }, v, bright)
  "hud"     -> (hud { hShow = not (hShow hud) }, v, bright)
  "help"    -> (hud { hHelp = not (hHelp hud) }, v, bright)
  "hash"    -> (hud { hHash = True }, v, bright)
  "freeze"  -> (hud { hFrozen = not (hFrozen hud) }, v, bright)
  "bright-" -> (hud, v, max 1 (bright / 1.25))
  "bright+" -> (hud, v, min 1e6 (bright * 1.25))
  "deposit-" -> edit (\x -> x { hvDeposit = clampF 0 10 (hvDeposit x - 0.01) })
  "deposit+" -> edit (\x -> x { hvDeposit = clampF 0 10 (hvDeposit x + 0.01) })
  "decay-"   -> edit (\x -> x { hvDecay = clampF 0 1 (hvDecay x - 0.01) })
  "decay+"   -> edit (\x -> x { hvDecay = clampF 0 1 (hvDecay x + 0.01) })
  "sensor-"  -> edit (\x -> x { hvSensorDist = clampF 0.5 64 (hvSensorDist x - 0.5) })
  "sensor+"  -> edit (\x -> x { hvSensorDist = clampF 0.5 64 (hvSensorDist x + 0.5) })
  "step-"    -> edit (\x -> x { hvStep = clampF 0.05 8 (hvStep x - 0.05) })
  "step+"    -> edit (\x -> x { hvStep = clampF 0.05 8 (hvStep x + 0.05) })
  "rot-"     -> edit (\x -> x { hvRotSteps = clampI 1 360 (hvRotSteps x - 1) })
  "rot+"     -> edit (\x -> x { hvRotSteps = clampI 1 360 (hvRotSteps x + 1) })
  _          -> (hud, v, bright)
  where
    edit f = (hud { hEdited = True }, f v, bright)
    clampF lo hi x = max lo (min hi x)
    clampI lo hi x = max lo (min hi x)
