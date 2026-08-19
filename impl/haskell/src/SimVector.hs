{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

-- | slimebench -- the *idiomatic* Haskell implementation of SPEC-1.
--
-- This exists because the other one ('Sim') was fairly described by a Haskell
-- programmer reading it as "what happens if you take the C and re-create it
-- line by line". That is accurate: it is @IOUArray@ in @IO@ with hand-written
-- tail recursion and explicit index arithmetic, and nobody would write it that
-- way if they were not matching a C reference statement for statement.
--
-- The usual advice is the opposite: write high-level code over immutable
-- structures and let GHC's fusion do the work. So this module does that, and
-- the benchmark reports both. The question is not which style is nicer -- it
-- is what the choice costs, in a language where the received wisdom is that it
-- costs little.
--
-- What "idiomatic" means concretely here:
--
--   * Pure functions over immutable 'U.Vector's. No @IO@ below 'runTicks', no
--     mutation, no manual index recursion.
--   * The diffusion pass is one 'U.generate' -- say what each output cell is,
--     let the compiler decide how to walk the grid.
--   * The deposit scatter is 'U.accumulate', which is exactly the operation
--     SPEC-1 5.3 describes and which preserves the required left-to-right
--     order over duplicate indices.
--   * The agent pass is 'U.unfoldrExactN' over a pure per-agent step.
--
-- Two things it deliberately does NOT give up, because they are correctness
-- rather than style: the normative summation order in the stencil (SPEC-1 5.4)
-- and 'Float' rather than 'Double'. Both styles are conformance tier A and
-- produce identical checksums; that is checked, not assumed.
--
-- == The one thing this style cannot express
--
-- @--update serial@ requires an agent to see the deposits of the agents before
-- it *within the same tick*. That is a sequential dependency through the grid,
-- and there is no way to write it over immutable vectors without rebuilding
-- the whole grid once per agent. This module refuses the mode rather than
-- quietly computing something else -- the same wall the numpy target hits, for
-- the same reason (see @impl/python/slimebench_numpy.py@). Worth noting that
-- the functional formulation and the vectorised one fail on exactly the same
-- construct.
module SimVector
  ( World(..)
  , newWorld
  , runTicks
  , hashGridV
  , hashAgentsV
  ) where

import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import GHC.Float (castFloatToWord32)

import DirTable (cosTable, ndir, sinTable)
import Data.Array.Base (unsafeAt)
import Sim (Config (..), Update (..))

fnvOffset, fnvPrime :: Word32
fnvOffset = 0x811C9DC5
fnvPrime = 0x01000193

-- | The whole simulation state. Immutable: a tick maps one 'World' to the next.
data World = World
  { wGrid :: !(U.Vector Float)
  , wAx   :: !(U.Vector Float)
  , wAy   :: !(U.Vector Float)
  , wAdir :: !(U.Vector Int)
  , wRng  :: !(U.Vector Word32) -- ^ four words per agent, flattened
  }

-- ---- PRNG (SPEC-1 section 3.1) --------------------------------------------

rotl32 :: Word32 -> Int -> Word32
rotl32 !x !k = (x `shiftL` k) .|. (x `shiftR` (32 - k))
{-# INLINE rotl32 #-}

splitmix32 :: Word32 -> (Word32, Word32)
splitmix32 !s0 =
  let !s = s0 + 0x9E3779B9
      !z1 = (s `xor` (s `shiftR` 16)) * 0x21F0AAAD
      !z2 = (z1 `xor` (z1 `shiftR` 15)) * 0x735A2D97
  in (s, z2 `xor` (z2 `shiftR` 15))
{-# INLINE splitmix32 #-}

-- | One xoshiro128++ draw. Pure: state in, (state, value) out.
type Rng = (Word32, Word32, Word32, Word32)

xoshiro :: Rng -> (Rng, Word32)
xoshiro (!a, !b, !c, !d) =
  let !res = rotl32 (a + d) 7 + a
      !t = b `shiftL` 9
      !c1 = c `xor` a
      !d1 = d `xor` b
      !b1 = b `xor` c1
      !a1 = a `xor` d1
      !c2 = c1 `xor` t
      !d2 = rotl32 d1 11
  in ((a1, b1, c2, d2), res)
{-# INLINE xoshiro #-}

rnd01 :: Word32 -> Float
rnd01 !u = fromIntegral (u `shiftR` 8) / 16777216.0
{-# INLINE rnd01 #-}

wrapf :: Float -> Float -> Float
wrapf !v0 !m =
  let !v1 = if v0 < 0.0 then v0 + m else v0
  in if v1 >= m then v1 - m else v1
{-# INLINE wrapf #-}

-- ---- construction (SPEC-1 section 3.3) ------------------------------------

newWorld :: Config -> World
newWorld Config{..} = World
  { wGrid = U.unfoldrExactN cells gridStep (cfgSeed `xor` 0x5BF03635)
  , wAx = U.map (\(x, _, _, _) -> x) seeds
  , wAy = U.map (\(_, y, _, _) -> y) seeds
  , wAdir = U.map (\(_, _, d, _) -> d) seeds
  , wRng = U.concatMap (\(_, _, _, (a, b, c, d)) -> U.fromListN 4 [a, b, c, d]) seeds
  }
  where
    !cells = cfgWidth * cfgHeight
    !fw = fromIntegral cfgWidth :: Float
    !fh = fromIntegral cfgHeight :: Float

    gridStep !s = let (!s', !u) = splitmix32 s in (rnd01 u * 100.0, s')

    seeds :: U.Vector (Float, Float, Int, Rng)
    seeds = U.generate cfgAgents agentSeed

    agentSeed !i =
      let !sm0 = cfgSeed + 0x9E3779B9 * fromIntegral (i + 1)
          (!sm1, !r0) = splitmix32 sm0
          (!sm2, !r1) = splitmix32 sm1
          (!sm3, !r2) = splitmix32 sm2
          (_, !r3) = splitmix32 sm3
          !r0' = if r0 .|. r1 .|. r2 .|. r3 == 0 then 1 else r0
          (!g1, !u1) = xoshiro (r0', r1, r2, r3)
          (!g2, !u2) = xoshiro g1
          (!g3, !u3) = xoshiro g2
      in ( rnd01 u1 * fw
         , rnd01 u2 * fh
         , fromIntegral (u3 `mod` fromIntegral ndir)
         , g3
         )

-- ---- one tick --------------------------------------------------------------

-- | What one agent produces: its new state, and the cell it deposits into.
--
-- Returning the target cell instead of applying the deposit is what lets the
-- scatter be a single 'U.accumulate' -- and it is the same split the C
-- reference makes in @sb_agent.h@ for the threaded path, arrived at from the
-- opposite direction.
agentStep
  :: Config -> Int -> Int -> Int -> U.Vector Float
  -> (Float, Float, Int, Rng)
  -> (Float, Float, Int, Rng, Int)
agentStep Config{..} !log2w !xmask !ymask grid (!x0, !y0, !d0, !rng0) =
  let !fw = fromIntegral cfgWidth :: Float
      !fh = fromIntegral cfgHeight :: Float
      !nd = ndir

      sense !dd =
        let !sx = wrapf (x0 + (cosTable `unsafeAt` dd) * cfgSensorDist) fw
            !sy = wrapf (y0 + (sinTable `unsafeAt` dd) * cfgSensorDist) fh
        in U.unsafeIndex grid (((truncate sy .&. ymask) `shiftL` log2w) .|. (truncate sx .&. xmask))

      !dl = (d0 - cfgSensorSteps + nd) `mod` nd
      !dr = (d0 + cfgSensorSteps) `mod` nd
      !fl = sense dl
      !fc = sense d0
      !fr = sense dr

      -- Only the dead-end case draws from the stream (SPEC-1 5.3); every other
      -- branch must leave the agent's PRNG untouched.
      (!rng1, !d)
        | fc >= fl && fc >= fr = (rng0, d0)
        | fc < fl && fc < fr =
            let (!g, !r) = xoshiro rng0
            in (g, if r .&. 1 /= 0 then (d0 + cfgRotSteps) `mod` nd
                                   else (d0 - cfgRotSteps + nd) `mod` nd)
        | fl > fr = (rng0, (d0 - cfgRotSteps + nd) `mod` nd)
        | otherwise = (rng0, (d0 + cfgRotSteps) `mod` nd)

      !x = wrapf (x0 + (cosTable `unsafeAt` d) * cfgStep) fw
      !y = wrapf (y0 + (sinTable `unsafeAt` d) * cfgStep) fh
      !idx = ((truncate y .&. ymask) `shiftL` log2w) .|. (truncate x .&. xmask)
  in (x, y, d, rng1, idx)
{-# INLINE agentStep #-}

-- | SPEC-1 section 5.4. Summation order is normative -- do not reorder.
--
-- One 'U.generate': say what cell @i@ of the output is, and let GHC produce
-- the loop. This is the part of the idiomatic style that costs nothing --
-- the stencil is a pure map and fuses cleanly.
diffuse :: Config -> Int -> Int -> Int -> U.Vector Float -> U.Vector Float
diffuse Config{..} !log2w !xmask !ymask src = U.generate (cfgWidth * cfgHeight) cell
  where
    cell !i =
      let !y = i `shiftR` log2w
          !x = i .&. xmask
          !rowm = ((y - 1) .&. ymask) `shiftL` log2w
          !row0 = y `shiftL` log2w
          !rowp = ((y + 1) .&. ymask) `shiftL` log2w
          !xm = (x - 1) .&. xmask
          !xp = (x + 1) .&. xmask
          at !j = U.unsafeIndex src j
          !s1 = at (rowm .|. xm) + at (rowm .|. x)
          !s2 = s1 + at (rowm .|. xp)
          !s3 = s2 + at (row0 .|. xm)
          !s4 = s3 + 4.0 * at (row0 .|. x)
          !s5 = s4 + at (row0 .|. xp)
          !s6 = s5 + at (rowp .|. xm)
          !s7 = s6 + at (rowp .|. x)
          !s8 = s7 + at (rowp .|. xp)
      in (s8 / 12.0) * cfgDecay
{-# INLINE diffuse #-}

tickV :: Config -> Int -> Int -> Int -> World -> World
tickV cfg !log2w !xmask !ymask World{..} =
  World { wGrid = grid', wAx = ax', wAy = ay', wAdir = adir', wRng = rng' }
  where
    !n = cfgAgents cfg

    stepped :: U.Vector (Float, Float, Int, Rng, Int)
    stepped = U.generate n $ \i ->
      let !o = i * 4
          !rng = ( U.unsafeIndex wRng o, U.unsafeIndex wRng (o + 1)
                 , U.unsafeIndex wRng (o + 2), U.unsafeIndex wRng (o + 3) )
      in agentStep cfg log2w xmask ymask wGrid
           (U.unsafeIndex wAx i, U.unsafeIndex wAy i, U.unsafeIndex wAdir i, rng)

    ax' = U.map (\(x, _, _, _, _) -> x) stepped
    ay' = U.map (\(_, y, _, _, _) -> y) stepped
    adir' = U.map (\(_, _, d, _, _) -> d) stepped
    rng' = U.concatMap (\(_, _, _, (a, b, c, d), _) -> U.fromListN 4 [a, b, c, d]) stepped

    -- The scatter. `accumulate` folds left to right over the pairs, so
    -- duplicate targets accumulate in ascending agent index -- which is
    -- exactly the order SPEC-1 5.3 prescribes, and the reason this is one
    -- library call rather than a hand-rolled loop.
    --
    -- It has to accumulate into a *zero* vector and be folded into the grid
    -- afterwards, not into `wGrid` directly. Two deposits on a cell must give
    -- @g + (d1 + d2)@, and accumulating in place gives @(g + d1) + d2@ -- a
    -- different rounding whenever @g@ is large enough that the last bit of the
    -- deposit falls off. The obvious one-liner is wrong by 1 ULP and the grid
    -- checksum caught it while the agent checksum stayed correct, which is
    -- what the two separate hashes in SPEC-1 6.3 are for.
    depOnly = U.accumulate (+) (U.replicate (cfgWidth cfg * cfgHeight cfg) 0.0)
      (U.map (\(_, _, _, _, idx) -> (idx, cfgDeposit cfg)) stepped)

    deposited = U.zipWith (+) wGrid depOnly

    grid' = diffuse cfg log2w xmask ymask deposited

-- | Run @k@ ticks. The only 'IO'-shaped thing here is the strict fold; the
-- simulation itself is a pure function from 'World' to 'World'.
runTicks :: Config -> Int -> World -> World
runTicks cfg !k w0 = go k w0
  where
    !log2w = countLog2 (cfgWidth cfg)
    !xmask = cfgWidth cfg - 1
    !ymask = cfgHeight cfg - 1
    go !i !w
      | i <= 0 = w
      | otherwise = go (i - 1) (tickV cfg log2w xmask ymask w)

countLog2 :: Int -> Int
countLog2 v = go 0 where go !n = if (1 `shiftL` n) >= v then n else go (n + 1)

-- ---- checksums (SPEC-1 section 6) -----------------------------------------

hashGridV :: World -> Word32
hashGridV World{..} = U.foldl' step fnvOffset wGrid
  where step !h !v = (h `xor` castFloatToWord32 v) * fnvPrime

hashAgentsV :: World -> Word32
hashAgentsV World{..} = go 0 fnvOffset
  where
    !n = U.length wAx
    go !i !h
      | i >= n = h
      | otherwise =
          let !h1 = (h `xor` castFloatToWord32 (U.unsafeIndex wAx i)) * fnvPrime
              !h2 = (h1 `xor` castFloatToWord32 (U.unsafeIndex wAy i)) * fnvPrime
              !h3 = (h2 `xor` fromIntegral (U.unsafeIndex wAdir i)) * fnvPrime
          in go (i + 1) h3
