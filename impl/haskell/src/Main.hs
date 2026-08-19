{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

-- | slimebench -- Haskell headless benchmark (class S).
module Main (main) where

import Control.Monad (forM_, when)
import Data.Bits ((.&.))
import Data.IORef (newIORef, modifyIORef', readIORef)
import Data.List (sort)
import Data.Word (Word32)
import Data.Maybe (isNothing)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitSuccess, exitWith, ExitCode(..))
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL

import Sim
import Parallel (ReduceMode (..), runParallel)

-- ---- CLI (SPEC-1 section 10) ---------------------------------------------

usage :: String
usage = unlines
  [ "usage: slimebench [options]   (slimebench " ++ specVersion ++ ")"
  , "  --preset NAME        tiny|small|medium|large|huge|browser"
  , "  --width N --height N powers of two"
  , "  --agents N  --ticks N  --warmup N  --seed N"
  , "  --update MODE        serial|deferred"
  , "  --threads N"
  , "  --deposit-reduce M   private|binned  (SPEC-1 5.6)"
  , "  --sensor-dist F  --sensor-steps N  --rot-steps N"
  , "  --step F  --deposit F  --decay F"
  , "  --headless  --render"
  , "  --json  --hash-every N  --dump-grid PATH  --display-max F"
  , "  -h, --help"
  ]

data Opts = Opts
  { optCfg      :: !Config
  , optJson     :: !Bool
  , optDumpGrid :: !(Maybe FilePath)
  , optReduce   :: !ReduceMode
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
parseArgs = go (Opts defaultConfig False Nothing Binned)
  where
    go o [] = pure o
    go o (a : rest) = case a of
      "-h"     -> putStr usage >> exitSuccess
      "--help" -> putStr usage >> exitSuccess
      "--json"     -> go o { optJson = True } rest
      "--headless" -> go o rest
      "--render"   -> go o rest
      _ -> case rest of
        (v : rest') -> withValue o a v rest'
        [] -> usageError (a ++ " requires a value")

    withValue o a v rest = case a of
      "--preset" -> case preset v of
        Nothing -> usageError ("unknown preset '" ++ v ++ "'")
        Just (w, h, n, t) -> go o { optCfg = (optCfg o)
          { cfgWidth = w, cfgHeight = h, cfgAgents = n, cfgTicks = t
          , cfgPreset = v } } rest
      "--width"        -> upd rest o (\c -> c { cfgWidth = readI v, cfgPreset = "custom" })
      "--height"       -> upd rest o (\c -> c { cfgHeight = readI v, cfgPreset = "custom" })
      "--agents"       -> upd rest o (\c -> c { cfgAgents = readI v, cfgPreset = "custom" })
      "--ticks"        -> upd rest o (\c -> c { cfgTicks = readI v })
      "--warmup"       -> upd rest o (\c -> c { cfgWarmup = readI v })
      "--seed"         -> upd rest o (\c -> c { cfgSeed = fromIntegral (readI v) })
      "--threads"      -> upd rest o (\c -> c { cfgThreads = readI v })
      "--hash-every"   -> upd rest o (\c -> c { cfgHashEvery = readI v })
      "--sensor-steps" -> upd rest o (\c -> c { cfgSensorSteps = readI v })
      "--rot-steps"    -> upd rest o (\c -> c { cfgRotSteps = readI v })
      "--sensor-dist"  -> upd rest o (\c -> c { cfgSensorDist = readF v })
      "--step"         -> upd rest o (\c -> c { cfgStep = readF v })
      "--deposit"      -> upd rest o (\c -> c { cfgDeposit = readF v })
      "--decay"        -> upd rest o (\c -> c { cfgDecay = readF v })
      "--display-max"  -> go o rest
      "--dump-grid"    -> go o { optDumpGrid = Just v } rest
      "--deposit-reduce" -> case v of
        "private" -> go o { optReduce = Private } rest
        "binned"  -> go o { optReduce = Binned } rest
        _ -> usageError "--deposit-reduce must be private|binned"
      "--update" -> case v of
        "serial"   -> upd rest o (\c -> c { cfgUpdate = Serial })
        "deferred" -> upd rest o (\c -> c { cfgUpdate = Deferred })
        _ -> usageError "--update must be serial|deferred"
      -- SPEC-1 section 10: never silently ignore an unknown flag.
      _ -> usageError ("unknown argument '" ++ a ++ "'")

    upd rest o f = go o { optCfg = f (optCfg o) } rest
    readI s = read s :: Int
    readF s = realToFrac (read s :: Double) :: Float

-- ---- main -----------------------------------------------------------------

main :: IO ()
main = do
  Opts{..} <- parseArgs =<< getArgs
  let cfg@Config{..} = optCfg
  when (not (isPowerOfTwo cfgWidth)) $ usageError "width must be a power of two"
  when (not (isPowerOfTwo cfgHeight)) $ usageError "height must be a power of two"

  sim <- newSim cfg

  (msTotal, tickMs) <- if cfgThreads > 1
    then do
      -- Class P: the whole tick loop lives in the pool; see Parallel.hs.
      adaptive <- isNothing <$> lookupEnv "SLIMEBENCH_NO_REBALANCE"
      !a <- nowNs
      r <- runParallel sim optReduce adaptive cfgWarmup cfgTicks
      !b <- nowNs
      case r of
        Left err -> hPutStrLn stderr ("error: " ++ err) >> exitWith (ExitFailure 2)
        Right ts -> pure (fromIntegral (b - a) / 1e6 :: Double, ts)
    else do
      forM_ [1 .. cfgWarmup] $ \_ -> tick sim
      resetTimers sim
      ticksRef <- newIORef []
      !t0 <- nowNs
      forM_ [1 .. cfgTicks] $ \t -> do
        !a <- nowNs
        tick sim
        !b <- nowNs
        modifyIORef' ticksRef ((fromIntegral (b - a) / 1e6 :: Double) :)
        when (cfgHashEvery /= 0 && t `mod` cfgHashEvery == 0) $ do
          g <- hashGrid sim
          ag <- hashAgents sim
          hPutStrLn stderr (printf "tick %d grid=0x%08X agents=0x%08X" t g ag)
      !t1 <- nowNs
      ts <- reverse <$> readIORef ticksRef
      pure (fromIntegral (t1 - t0) / 1e6 :: Double, ts)

  case optDumpGrid of
    Nothing -> pure ()
    Just path -> dumpGrid sim path

  gh <- hashGrid sim
  ah <- hashAgents sim
  nsA <- readNsAgent sim
  nsD <- readNsDiff sim
  let msA = fromIntegral nsA / 1e6 :: Double
      msD = fromIntegral nsD / 1e6 :: Double

  if optJson
    then putStrLn (resultJson cfg optReduce gh ah msTotal msA msD tickMs)
    else do
      printf "%s %dx%d agents=%d ticks=%d update=%s\n"
        cfgPreset cfgWidth cfgHeight cfgAgents cfgTicks (updateName cfgUpdate)
      printf "  grid_hash  0x%08X\n" gh
      printf "  agent_hash 0x%08X\n" ah
      printf "  total      %.2f ms  (%.4f ms/tick)\n" msTotal
        (if cfgTicks > 0 then msTotal / fromIntegral cfgTicks else 0)
      printf "  agents     %.2f ms\n" msA
      printf "  diffuse    %.2f ms\n" msD

isPowerOfTwo :: Int -> Bool
isPowerOfTwo n = n > 0 && (n .&. (n - 1)) == 0

-- The wire name, not the constructor name: every implementation prints the
-- same lowercase token so output can be diffed across languages.
updateName :: Update -> String
updateName Deferred = "deferred"
updateName Serial = "serial"

resultJson :: Config -> ReduceMode -> Word32 -> Word32 -> Double -> Double -> Double
           -> [Double] -> String
resultJson Config{..} reduce gh ah msTotal msA msD tickMs =
  let n = length tickMs
      srt = sort tickMs
      median = if n > 0 then srt !! (n `div` 2) else 0
      p99 = if n > 0 then srt !! min (n - 1) (floor (fromIntegral n * 0.99 :: Double)) else 0
      mean = if n > 0 then sum tickMs / fromIntegral n else 0
      cells = fromIntegral cfgWidth * fromIntegral cfgHeight :: Double
      maups = if msTotal > 0 then fromIntegral cfgAgents * fromIntegral n / msTotal / 1000 else 0
      mcups = if msTotal > 0 then cells * fromIntegral n / msTotal / 1000 else 0
      upd = updateName cfgUpdate
      cls = if cfgThreads > 1 then "P" else "S" :: String
      variant | cfgThreads <= 1 = "scalar" :: String
              | reduce == Binned = "binned"
              | otherwise = "private"
  in printf
      ("{\"schema\":1,\"impl\":\"haskell\",\"backend\":\"headless\",\"class\":\"%s\","
       ++ "\"variant\":\"%s\","
       ++ "\"preset\":\"%s\",\"width\":%d,\"height\":%d,\"agents\":%d,\"ticks\":%d,"
       ++ "\"seed\":%d,\"update\":\"%s\",\"threads\":%d,"
       ++ "\"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\","
       ++ "\"ms_total\":%.4f,\"ms_agents\":%.4f,\"ms_diffuse\":%.4f,"
       ++ "\"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,"
       ++ "\"maups\":%.4f,\"mcups\":%.4f}")
      cls variant
      cfgPreset cfgWidth cfgHeight cfgAgents n (fromIntegral cfgSeed :: Int) upd cfgThreads
      gh ah dirtableHashRuntime
      msTotal msA msD mean median p99 maups mcups

dumpGrid :: Sim -> FilePath -> IO ()
dumpGrid sim path = do
  vals <- gridValues sim
  BL.writeFile path (B.toLazyByteString (foldMap B.floatLE vals))
