{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

-- | slimebench -- Haskell headless benchmark, idiomatic style (class S).
--
-- Same CLI and same JSON as 'Main', so the harness cannot tell the two apart
-- except by the @variant@ field. The simulation is 'SimVector'; see that
-- module for what "idiomatic" means here and why it exists.
module Main (main) where

import Control.Monad (when)
import Data.Bits ((.&.))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Word (Word32)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Vector.Unboxed as U

import Sim (Config (..), Update (..), defaultConfig, dirtableHashRuntime, nowNs, specVersion)
import SimVector (World (..), hashAgentsV, hashGridV, newWorld, runTicks)

usage :: String
usage = unlines
  [ "usage: slimebench-vector [options]   (slimebench " ++ specVersion ++ ", idiomatic)"
  , "  --preset NAME        tiny|small|medium|large|huge|browser"
  , "  --width N --height N powers of two"
  , "  --agents N  --ticks N  --warmup N  --seed N"
  , "  --update MODE        deferred   (serial is not expressible, see SimVector)"
  , "  --sensor-dist F  --sensor-steps N  --rot-steps N"
  , "  --step F  --deposit F  --decay F"
  , "  --json  --hash-every N  --dump-grid PATH"
  , "  -h, --help"
  ]

data Opts = Opts
  { optCfg      :: !Config
  , optJson     :: !Bool
  , optDumpGrid :: !(Maybe FilePath)
  }

preset :: String -> Maybe (Int, Int, Int, Int)
preset "tiny"    = Just (512, 512, 65536, 1000)
preset "small"   = Just (1024, 1024, 262144, 1000)
preset "medium"  = Just (2048, 2048, 1048576, 1000)
preset "large"   = Just (4096, 4096, 4194304, 500)
preset "huge"    = Just (8192, 8192, 16777216, 100)
preset "browser" = Just (1024, 1024, 262144, 0)
preset _         = Nothing

usageError :: String -> IO a
usageError msg = do
  hPutStrLn stderr ("error: " ++ msg)
  hPutStrLn stderr usage
  exitWith (ExitFailure 2)

parseArgs :: [String] -> IO Opts
parseArgs = go (Opts defaultConfig False Nothing)
  where
    go o [] = pure o
    go o (a : rest) = case a of
      "-h" -> putStrLn usage >> exitSuccess
      "--help" -> putStrLn usage >> exitSuccess
      "--json" -> go o { optJson = True } rest
      "--headless" -> go o rest
      "--render" -> usageError "this target is headless only"
      "--simd" -> usageError "this target has no vectorised kernel"
      "--no-simd" -> go o rest
      _ -> withValue o a rest

    withValue _ flag [] = usageError (flag ++ " requires a value")
    withValue o flag (v : rest) =
      let c = optCfg o
          int = readIntOr flag v
          flt = readFloatOr flag v
      in case flag of
        "--preset" -> case preset v of
          Nothing -> usageError ("unknown preset '" ++ v ++ "'")
          Just (w, h, ag, tk) ->
            go o { optCfg = c { cfgWidth = w, cfgHeight = h, cfgAgents = ag
                              , cfgTicks = tk, cfgPreset = v } } rest
        "--width" -> int >>= \n -> go o { optCfg = c { cfgWidth = n, cfgPreset = "custom" } } rest
        "--height" -> int >>= \n -> go o { optCfg = c { cfgHeight = n, cfgPreset = "custom" } } rest
        "--agents" -> int >>= \n -> go o { optCfg = c { cfgAgents = n, cfgPreset = "custom" } } rest
        "--ticks" -> int >>= \n -> go o { optCfg = c { cfgTicks = n } } rest
        "--warmup" -> int >>= \n -> go o { optCfg = c { cfgWarmup = n } } rest
        "--seed" -> int >>= \n -> go o { optCfg = c { cfgSeed = fromIntegral n } } rest
        "--threads" -> int >>= \n ->
          if n > 1 then usageError "this target is single-threaded"
                   else go o { optCfg = c { cfgThreads = n } } rest
        "--hash-every" -> int >>= \n -> go o { optCfg = c { cfgHashEvery = n } } rest
        "--sensor-steps" -> int >>= \n -> go o { optCfg = c { cfgSensorSteps = n } } rest
        "--rot-steps" -> int >>= \n -> go o { optCfg = c { cfgRotSteps = n } } rest
        "--sensor-dist" -> flt >>= \f -> go o { optCfg = c { cfgSensorDist = f } } rest
        "--step" -> flt >>= \f -> go o { optCfg = c { cfgStep = f } } rest
        "--deposit" -> flt >>= \f -> go o { optCfg = c { cfgDeposit = f } } rest
        "--decay" -> flt >>= \f -> go o { optCfg = c { cfgDecay = f } } rest
        "--display-max" -> go o rest
        "--dump-grid" -> go o { optDumpGrid = Just v } rest
        "--update" -> case v of
          "deferred" -> go o { optCfg = c { cfgUpdate = Deferred } } rest
          "serial" -> serialRefused
          _ -> usageError "--update must be serial|deferred"
        -- SPEC-1 section 10: never silently ignore an unknown flag.
        _ -> usageError ("unknown argument '" ++ flag ++ "'")

    readIntOr flag v = case reads v of
      [(n, "")] -> pure (n :: Int)
      _ -> usageError ("'" ++ v ++ "' is not an integer (" ++ flag ++ ")")
    readFloatOr flag v = case reads v of
      [(f, "")] -> pure (f :: Float)
      _ -> usageError ("'" ++ v ++ "' is not a number (" ++ flag ++ ")")

-- | Refuse rather than compute something else. Exit code 3, matching the numpy
-- target, so the harness can tell "cannot" apart from "misused".
serialRefused :: IO a
serialRefused = do
  hPutStrLn stderr $ unlines
    [ "error: the idiomatic target implements --update deferred only."
    , "       SPEC-1 'serial' makes an agent's deposit visible to the next"
    , "       agent in the same tick. Over immutable vectors that means"
    , "       rebuilding the grid once per agent; there is no fusion that"
    , "       rescues it. The vectorised numpy target refuses the same mode"
    , "       for the same reason -- see SPEC-1 section 5.5."
    , "       Use the low-level Haskell target for serial."
    ]
  exitWith (ExitFailure 3)

main :: IO ()
main = do
  Opts{..} <- parseArgs =<< getArgs
  let cfg@Config{..} = optCfg
  when (not (isPowerOfTwo cfgWidth)) $ usageError "width must be a power of two"
  when (not (isPowerOfTwo cfgHeight)) $ usageError "height must be a power of two"
  when (cfgUpdate == Serial) serialRefused

  let w0 = newWorld cfg
  -- Force the initial world before the clock starts; `newWorld` is lazy and
  -- would otherwise be billed to the first tick.
  _ <- pure $! U.length (wGrid w0) + U.length (wAx w0)
  let !warm = runTicks cfg cfgWarmup w0
  _ <- pure $! hashGridV warm

  ticksRef <- newIORef []
  !t0 <- nowNs
  let loop !i !w
        | i > cfgTicks = pure w
        | otherwise = do
            !a <- nowNs
            let !w' = runTicks cfg 1 w
            -- runTicks is pure and lazy; forcing the checksum-free way would
            -- leave a thunk. Touch one element to make the tick actually run.
            _ <- pure $! U.unsafeIndex (wGrid w') 0
            !b <- nowNs
            modifyIORef' ticksRef ((fromIntegral (b - a) / 1e6 :: Double) :)
            when (cfgHashEvery /= 0 && i `mod` cfgHashEvery == 0) $
              hPutStrLn stderr (printf "tick %d grid=0x%08X agents=0x%08X"
                                       i (hashGridV w') (hashAgentsV w'))
            loop (i + 1) w'
  wEnd <- loop 1 warm
  !t1 <- nowNs
  let !msTotal = fromIntegral (t1 - t0) / 1e6 :: Double

  tickMs <- reverse <$> readIORef ticksRef

  case optDumpGrid of
    Nothing -> pure ()
    Just path -> BL.writeFile path
      (B.toLazyByteString (U.foldr (\v acc -> B.floatLE v <> acc) mempty (wGrid wEnd)))

  let gh = hashGridV wEnd
      ah = hashAgentsV wEnd

  if optJson
    then putStrLn (resultJson cfg gh ah msTotal tickMs)
    else do
      printf "%s %dx%d agents=%d ticks=%d update=%s variant=vector\n"
        cfgPreset cfgWidth cfgHeight cfgAgents cfgTicks ("deferred" :: String)
      printf "  grid_hash  0x%08X\n" gh
      printf "  agent_hash 0x%08X\n" ah
      printf "  total      %.2f ms  (%.4f ms/tick)\n" msTotal
        (if cfgTicks > 0 then msTotal / fromIntegral cfgTicks else 0)

isPowerOfTwo :: Int -> Bool
isPowerOfTwo n = n > 0 && (n .&. (n - 1)) == 0

-- | The phase split the low-level target reports is not available here: the
-- agent pass and the diffusion pass are one fused pipeline by construction, so
-- ms_agents / ms_diffuse are reported as zero rather than invented.
resultJson :: Config -> Word32 -> Word32 -> Double -> [Double] -> String
resultJson Config{..} gh ah msTotal tickMs =
  let n = length tickMs
      srt = sort tickMs
      median = if n > 0 then srt !! (n `div` 2) else 0
      p99 = if n > 0 then srt !! min (n - 1) (floor (fromIntegral n * 0.99 :: Double)) else 0
      mean = if n > 0 then sum tickMs / fromIntegral n else 0
      cells = fromIntegral cfgWidth * fromIntegral cfgHeight :: Double
      maups = if msTotal > 0 then fromIntegral cfgAgents * fromIntegral n / msTotal / 1000 else 0
      mcups = if msTotal > 0 then cells * fromIntegral n / msTotal / 1000 else 0
  in printf
      ("{\"schema\":1,\"impl\":\"haskell\",\"backend\":\"headless\",\"class\":\"S\","
       ++ "\"variant\":\"vector\","
       ++ "\"preset\":\"%s\",\"width\":%d,\"height\":%d,\"agents\":%d,\"ticks\":%d,"
       ++ "\"seed\":%d,\"update\":\"deferred\",\"threads\":1,"
       ++ "\"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\","
       ++ "\"ms_total\":%.4f,\"ms_agents\":0,\"ms_diffuse\":0,"
       ++ "\"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,"
       ++ "\"maups\":%.4f,\"mcups\":%.4f}")
      cfgPreset cfgWidth cfgHeight cfgAgents n (fromIntegral cfgSeed :: Int)
      gh ah dirtableHashRuntime
      msTotal mean median p99 maups mcups
