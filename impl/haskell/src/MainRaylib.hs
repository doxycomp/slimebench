{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE RecordWildCards #-}

-- | slimebench -- Haskell + raylib frontend (benchmark class R).
--
-- Bound with @foreign import ccall@ against the same @libraylib.so@ the C,
-- Rust and Python frontends link, rather than through @h-raylib@.
--
-- That is not laziness: @h-raylib@ vendors raylib and builds its own copy, so
-- using it would compare a Haskell program against a *different build* of the
-- library than every other target in this class. Declaring the eight
-- functions this frontend calls keeps the comparison to the language and its
-- FFI, which is what class R is for. It is also, for a C library this small a
-- surface, what the Haskell FFI is designed for -- the declarations below are
-- the whole binding.
--
-- raylib's @UNCOMPRESSED_GRAYSCALE@ takes the 8-bit buffer directly, so
-- unlike the SDL2 frontend there is no expansion loop here.
module Main (main) where

import Control.Monad (foldM, when)
import Data.Word (Word8)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable (..))

import qualified Hud
import Render
import RenderCli (RenderOpts (..), parseRenderArgs, titleFor)
import Sim

-- | raylib's @Image@: a pointer plus four ints. Laid out by hand because that
-- is the only struct crossing the boundary.
data RlImage = RlImage
  { imgData    :: !(Ptr Word8)
  , imgWidth   :: !CInt
  , imgHeight  :: !CInt
  , imgMipmaps :: !CInt
  , imgFormat  :: !CInt
  }

instance Storable RlImage where
  sizeOf _ = 8 + 4 * 4
  alignment _ = 8
  peek p = RlImage <$> peekByteOff p 0 <*> peekByteOff p 8
                   <*> peekByteOff p 12 <*> peekByteOff p 16
                   <*> peekByteOff p 20
  poke p RlImage{..} = do
    pokeByteOff p 0 imgData
    pokeByteOff p 8 imgWidth
    pokeByteOff p 12 imgHeight
    pokeByteOff p 16 imgMipmaps
    pokeByteOff p 20 imgFormat

-- | raylib's @Texture2D@: five ints.
data RlTexture = RlTexture !CInt !CInt !CInt !CInt !CInt

instance Storable RlTexture where
  sizeOf _ = 20
  alignment _ = 4
  peek p = RlTexture <$> peekByteOff p 0 <*> peekByteOff p 4 <*> peekByteOff p 8
                     <*> peekByteOff p 12 <*> peekByteOff p 16
  poke p (RlTexture a b c d e) = do
    pokeByteOff p 0 a; pokeByteOff p 4 b; pokeByteOff p 8 c
    pokeByteOff p 12 d; pokeByteOff p 16 e

-- | raylib's @Color@ is four bytes and is passed by value; as a 32-bit word
-- it lands in the right register on the SysV ABI.
type RlColor = CInt

rgba :: Int -> Int -> Int -> Int -> RlColor
rgba r g b a = fromIntegral (r + g * 256 + b * 65536 + a * 16777216)

-- Scalar-only entry points come straight from libraylib.
foreign import ccall unsafe "InitWindow"        c_InitWindow :: CInt -> CInt -> CString -> IO ()
foreign import ccall unsafe "CloseWindow"       c_CloseWindow :: IO ()
foreign import ccall unsafe "WindowShouldClose" c_WindowShouldClose :: IO CInt
foreign import ccall unsafe "IsKeyPressed"      c_IsKeyPressed :: CInt -> IO CInt
foreign import ccall unsafe "SetWindowTitle"    c_SetWindowTitle :: CString -> IO ()
foreign import ccall unsafe "SetTraceLogLevel"  c_SetTraceLogLevel :: CInt -> IO ()
foreign import ccall unsafe "BeginDrawing"      c_BeginDrawing :: IO ()
foreign import ccall unsafe "EndDrawing"        c_EndDrawing :: IO ()

-- The five that pass a struct by value go through impl/shim/raylib_shim.c, which
-- Haskell's FFI cannot express.
foreign import ccall unsafe "sb_rl_clear_background" c_ClearBackground :: RlColor -> IO ()
foreign import ccall unsafe "sb_rl_load_texture"     c_LoadTextureFromImage
  :: Ptr RlImage -> Ptr RlTexture -> IO ()
foreign import ccall unsafe "sb_rl_update_texture"   c_UpdateTexture
  :: Ptr RlTexture -> Ptr Word8 -> IO ()
foreign import ccall unsafe "sb_rl_draw_texture"     c_DrawTexture
  :: Ptr RlTexture -> CInt -> CInt -> RlColor -> IO ()
foreign import ccall unsafe "sb_rl_unload_texture"   c_UnloadTexture :: Ptr RlTexture -> IO ()

-- Checked against the header rather than trusted: if raylib ever grows a
-- field, this aborts instead of scribbling past the end of an alloca.
foreign import ccall unsafe "sb_rl_sizeof_image"   c_sizeofImage :: IO CInt
foreign import ccall unsafe "sb_rl_sizeof_texture" c_sizeofTexture :: IO CInt

-- | raylib key codes: ASCII for the printable keys, GLFW numbers otherwise.
keymap :: [(Int, String)]
keymap =
  [ (256, "quit"), (81, "quit"), (32, "pause"), (78, "step")
  , (82, "reset"), (258, "hud"), (72, "help"), (290, "help")
  , (67, "hash"), (70, "freeze")
  , (49, "deposit-"), (50, "deposit+"), (51, "decay-"), (52, "decay+")
  , (53, "sensor-"), (54, "sensor+"), (55, "step-"), (56, "step+")
  , (57, "rot-"), (48, "rot+"), (45, "bright-"), (61, "bright+")
  ]

logWarning, pixelfmtGray :: CInt
logWarning = 4
pixelfmtGray = 1

main :: IO ()
main = do
  RenderOpts{..} <- parseRenderArgs
  let cfg@Config{..} = roCfg
      !frames = if cfgTicks == 0 then 100000 else cfgTicks
      !cells = cfgWidth * cfgHeight

  sim <- newSim cfg

  do szI <- c_sizeofImage
     szT <- c_sizeofTexture
     when (fromIntegral szI /= sizeOf (undefined :: RlImage)
           || fromIntegral szT /= sizeOf (undefined :: RlTexture)) $
       error ("raylib struct layout changed: Image " ++ show szI
              ++ " vs " ++ show (sizeOf (undefined :: RlImage))
              ++ ", Texture2D " ++ show szT
              ++ " vs " ++ show (sizeOf (undefined :: RlTexture)))

  c_SetTraceLogLevel logWarning
  withCString "slimebench -- Haskell / raylib" $ \t ->
    c_InitWindow (fromIntegral cfgWidth) (fromIntegral cfgHeight) t

  fp <- mallocForeignPtrBytes cells :: IO (ForeignPtr Word8)
  stats <- newStats

  withForeignPtr fp $ \gray ->
    alloca $ \imgP -> alloca $ \texP -> do
      poke imgP RlImage { imgData = gray
                        , imgWidth = fromIntegral cfgWidth
                        , imgHeight = fromIntegral cfgHeight
                        , imgMipmaps = 1
                        , imgFormat = pixelfmtGray }
      c_LoadTextureFromImage imgP texP

      let black = rgba 0 0 0 255
          white = rgba 255 255 255 255
          hud0 = Hud.newHud "Haskell / raylib" (not roJson)
          view0 = Hud.HudView
            { Hud.hvWidth = cfgWidth, Hud.hvHeight = cfgHeight
            , Hud.hvAgents = cfgAgents, Hud.hvThreads = max 1 cfgThreads
            , Hud.hvRotSteps = cfgRotSteps, Hud.hvDeposit = cfgDeposit
            , Hud.hvDecay = cfgDecay, Hud.hvSensorDist = cfgSensorDist
            , Hud.hvStep = cfgStep, Hud.hvDeferred = True }
          -- Editing a parameter replaces the config with a record update,
          -- which shares every mutable array: no indirection lands in the
          -- tick, so class S is unaffected.
          cfgOf sm v = (simCfg sm)
            { cfgDeposit = Hud.hvDeposit v, cfgDecay = Hud.hvDecay v
            , cfgSensorDist = Hud.hvSensorDist v, cfgStep = Hud.hvStep v
            , cfgRotSteps = Hud.hvRotSteps v }
          pollKeys st = foldM oneKey st keymap
          oneKey acc@(h, v, b) (code, action) = do
            down <- c_IsKeyPressed (fromIntegral code)
            pure (if down /= 0 then Hud.act action h v b else acc)
          loop !i !sm !hud !view !bright
            | i >= frames = pure ()
            | otherwise = do
                closing <- c_WindowShouldClose
                (hud1, view1, bright1) <- pollKeys (hud, view, bright)
                if closing /= 0 || Hud.hQuit hud1 then pure () else do
                  sm1 <- if Hud.hReset hud1 then newSim (cfgOf sm view1)
                                            else pure sm { simCfg = cfgOf sm view1 }
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
                                (if Hud.hEdited hud2 then "  EDITED"
                                                     else "" :: String)
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
                  renderGrayPtr sm1 bright1 gray
                  Hud.draw 1 gray hud4 view1 bright1
                  c_UpdateTexture texP gray
                  c_BeginDrawing
                  c_ClearBackground black
                  c_DrawTexture texP 0 0 white
                  c_EndDrawing
                  !r1 <- nowNs
                  addFrame stats (r1 - r0)
                  let hud5 = Hud.smooth (fromIntegral (s1 - s0) / 1e6)
                                        (fromIntegral (r1 - r0) / 1e6) hud4

                  n <- sinceTitle stats
                  when (n >= 60) $ do
                    ms <- recentMean stats 60
                    withCString (titleFor "raylib" ms) c_SetWindowTitle
                    resetTitle stats
                  loop (i + 1) sm1 hud5 view1 bright1
      loop (0 :: Int) sim hud0 view0 roDisplayMax
      c_UnloadTexture texP

  c_CloseWindow
  when roJson $ statsJson stats cfg "raylib" >>= mapM_ putStrLn
