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

import Control.Monad (unless, when)
import Data.Word (Word8)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable (..))

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
          loop !i
            | i >= frames = pure ()
            | otherwise = do
                closing <- c_WindowShouldClose
                unless (closing /= 0) $ do
                  unless roFreeze (tick sim)
                  !r0 <- nowNs
                  renderGrayPtr sim roDisplayMax gray
                  c_UpdateTexture texP gray
                  c_BeginDrawing
                  c_ClearBackground black
                  c_DrawTexture texP 0 0 white
                  c_EndDrawing
                  !r1 <- nowNs
                  addFrame stats (r1 - r0)

                  n <- sinceTitle stats
                  when (n >= 60) $ do
                    ms <- recentMean stats 60
                    withCString (titleFor "raylib" ms) c_SetWindowTitle
                    resetTitle stats
                  loop (i + 1)
      loop (0 :: Int)
      c_UnloadTexture texP

  c_CloseWindow
  when roJson $ statsJson stats cfg "raylib" >>= mapM_ putStrLn
