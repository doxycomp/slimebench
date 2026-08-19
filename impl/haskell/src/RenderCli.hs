{-# LANGUAGE BangPatterns #-}

-- | The subset of the SPEC-1 section 10 CLI the windowed frontends need.
--
-- Separate from 'Main''s parser because the render targets accept a different
-- set: no @--threads@, no @--deposit-reduce@, but @--freeze-sim@ and
-- @--display-max@. Shared by both frontends so they cannot drift apart in
-- what they accept.
module RenderCli
  ( RenderOpts(..)
  , parseRenderArgs
  , titleFor
  ) where

import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

import Sim (Config (..), Update (..), defaultConfig, specVersion)

data RenderOpts = RenderOpts
  { roCfg        :: !Config
  , roJson       :: !Bool
  , roFreeze     :: !Bool
  , roDisplayMax :: !Float
  }

usage :: String
usage = unlines
  [ "usage: slimebench-<backend> [options]   (slimebench " ++ specVersion ++ ")"
  , "  --preset NAME        tiny|small|medium|large|browser"
  , "  --width N --height N powers of two"
  , "  --agents N  --ticks N  --seed N"
  , "  --update MODE        serial|deferred"
  , "  --sensor-dist F  --sensor-steps N  --rot-steps N"
  , "  --step F  --deposit F  --decay F"
  , "  --render  --freeze-sim  --display-max F  --json"
  , "  -h, --help"
  ]

preset :: String -> Maybe (Int, Int, Int, Int)
preset "tiny"    = Just (512, 512, 65536, 1000)
preset "small"   = Just (1024, 1024, 262144, 1000)
preset "medium"  = Just (2048, 2048, 1048576, 1000)
preset "large"   = Just (4096, 4096, 4194304, 500)
preset "browser" = Just (1024, 1024, 262144, 0)
preset _         = Nothing

bail :: String -> IO a
bail m = hPutStrLn stderr ("error: " ++ m) >> hPutStrLn stderr usage
         >> exitWith (ExitFailure 2)

parseRenderArgs :: IO RenderOpts
parseRenderArgs = getArgs >>= go (RenderOpts defaultConfig False False 100.0)
  where
    go o [] = pure o
    go o (a : rest) = case a of
      "-h"           -> putStr usage >> exitSuccess
      "--help"       -> putStr usage >> exitSuccess
      "--json"       -> go o { roJson = True } rest
      "--freeze-sim" -> go o { roFreeze = True } rest
      "--render"     -> go o rest
      "--headless"   -> go o rest
      _ -> case rest of
        (v : rest') -> withValue o a v rest'
        []          -> bail (a ++ " requires a value")

    withValue o a v rest =
      let c = roCfg o
          upd f = go o { roCfg = f c } rest
      in case a of
        "--preset" -> case preset v of
          Nothing -> bail ("unknown preset '" ++ v ++ "'")
          Just (w, h, n, t) -> upd (\x -> x { cfgWidth = w, cfgHeight = h
                                            , cfgAgents = n, cfgTicks = t
                                            , cfgPreset = v })
        "--width"        -> upd (\x -> x { cfgWidth = readI v, cfgPreset = "custom" })
        "--height"       -> upd (\x -> x { cfgHeight = readI v, cfgPreset = "custom" })
        "--agents"       -> upd (\x -> x { cfgAgents = readI v, cfgPreset = "custom" })
        "--ticks"        -> upd (\x -> x { cfgTicks = readI v })
        "--warmup"       -> upd (\x -> x { cfgWarmup = readI v })
        "--seed"         -> upd (\x -> x { cfgSeed = fromIntegral (readI v) })
        "--sensor-steps" -> upd (\x -> x { cfgSensorSteps = readI v })
        "--rot-steps"    -> upd (\x -> x { cfgRotSteps = readI v })
        "--sensor-dist"  -> upd (\x -> x { cfgSensorDist = readF v })
        "--step"         -> upd (\x -> x { cfgStep = readF v })
        "--deposit"      -> upd (\x -> x { cfgDeposit = readF v })
        "--decay"        -> upd (\x -> x { cfgDecay = readF v })
        "--display-max"  -> go o { roDisplayMax = readF v } rest
        "--update" -> case v of
          "serial"   -> upd (\x -> x { cfgUpdate = Serial })
          "deferred" -> upd (\x -> x { cfgUpdate = Deferred })
          _          -> bail "--update must be serial|deferred"
        -- SPEC-1 section 10: never silently ignore an unknown flag.
        _ -> bail ("unknown argument '" ++ a ++ "'")

    readI x = read x :: Int
    readF x = realToFrac (read x :: Double) :: Float

titleFor :: String -> Double -> String
titleFor backend ms =
  printf "slimebench -- Haskell / %s -- %.2f ms/frame (%.0f fps)"
         backend ms (if ms > 0 then 1000 / ms else 0 :: Double)
