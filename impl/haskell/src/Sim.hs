{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | slimebench -- Haskell implementation of SPEC-1.
--
-- The inner loops are written against 'IOUArray' in 'IO' with everything
-- strict and unboxed. That is structurally the same code the C reference runs;
-- the interesting question this target answers is what GHC's code generator
-- does with it.
--
-- Two things that matter more here than in any other port:
--
--   * Strictness. Without the bang patterns and @{-# UNPACK #-}@ the
--     accumulator in the diffusion kernel builds a nine-deep thunk chain per
--     cell and the whole grid becomes a graph of suspended additions. That is
--     the difference between "a few times slower than C" and "unusable".
--
--   * @unsafeRead@/@unsafeWrite@, and @unsafeAt@ on the trig tables. Every
--     index has already been masked with @width-1@ or reduced mod NDIR, so the
--     bounds check can never fire, but GHC cannot prove it. This is the same
--     trade the Rust target measures with its @unchecked@ feature -- and it is
--     far more expensive here than there. Using @Data.Array.Unboxed.(!)@ for
--     the four trig lookups per agent, which is the obvious way to write it,
--     costs **1.52x overall**: 2253 -> 1479 ms at small/300, almost all of it
--     in the agent pass (1962 -> 1197). @(!)@ goes through the @Ix@ class to
--     compute the offset and range-checks it, and GHC does not eliminate
--     either even though the bounds are a compile-time constant.
module Sim
  ( Config(..)
  , Update(..)
  , Sim(..)
  , defaultConfig
  , newSim
  , tick
  , agentRange
  , diffuseRows
  , mergeRows
  , swapBuffers
  , hashGrid
  , hashAgents
  , dirtableHashRuntime
  , renderGray
  , renderGrayPtr
  , renderArgbPtr
  , gridValues
  , resetTimers
  , readNsAgent
  , readNsDiff
  , nowNs
  , specVersion
  ) where

import Control.Monad (forM_, when)
import Data.Array.Base (unsafeAt, unsafeRead, unsafeWrite)
import Data.Array.Unboxed (UArray, (!))
import Data.Array.IO (IOUArray, getElems, newArray, newListArray)
import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Word (Word32, Word64, Word8)
import GHC.Clock (getMonotonicTimeNSec)
import Foreign.Ptr (Ptr)
import Foreign.Storable (pokeByteOff)
import GHC.Float (castFloatToWord32)

import DirTable (cosBits, cosTable, ndir, sinBits, sinTable)

specVersion :: String
specVersion = "SPEC-1"

fnvOffset, fnvPrime :: Word32
fnvOffset = 0x811C9DC5
fnvPrime = 0x01000193

data Update = Serial | Deferred deriving (Eq, Show)

data Config = Config
  { cfgWidth       :: !Int
  , cfgHeight      :: !Int
  , cfgAgents      :: !Int
  , cfgTicks       :: !Int
  , cfgWarmup      :: !Int
  , cfgSeed        :: !Word32
  , cfgThreads     :: !Int
  -- | Ticks between spatial re-sorts of the agent arrays; 0 = never.
  -- See 'agentSort' -- it changes which agent sits where, not what any
  -- of them computes.
  , cfgAgentTile   :: !Int
  , cfgUpdate      :: !Update
  , cfgSensorDist  :: !Float
  , cfgStep        :: !Float
  , cfgDeposit     :: !Float
  , cfgDecay       :: !Float
  , cfgSensorSteps :: !Int
  , cfgRotSteps    :: !Int
  , cfgHashEvery   :: !Int
  , cfgPreset      :: !String
  } deriving (Show)

defaultConfig :: Config
defaultConfig = Config
  { cfgWidth = 1024, cfgHeight = 1024, cfgAgents = 262144
  , cfgTicks = 1000, cfgWarmup = 0, cfgSeed = 12345, cfgThreads = 1
  , cfgAgentTile = 0
  , cfgUpdate = Serial
  , cfgSensorDist = 9.0, cfgStep = 1.0, cfgDeposit = 10.0, cfgDecay = 0.94
  , cfgSensorSteps = 144, cfgRotSteps = 144
  , cfgHashEvery = 0, cfgPreset = "custom"
  }

data Sim = Sim
  { simCfg     :: !Config
  , simLog2w   :: !Int
  , simXmask   :: !Int
  , simYmask   :: !Int
  , simGrid    :: !(IORef (IOUArray Int Float))
  , simScratch :: !(IORef (IOUArray Int Float))
  , simDep     :: !(Maybe (IOUArray Int Float))
  , simAx      :: !(IOUArray Int Float)
  , simAy      :: !(IOUArray Int Float)
  , simAdir    :: !(IOUArray Int Int)
  , simArng    :: !(IOUArray Int Word32)
  -- | Spatial ordering ('cfgAgentTile'). 'Nothing' when it is off.
  , simOrder   :: !(Maybe Order)
  , simTicks   :: !(IORef Int)
  , simNsAgent :: !(IORef Word64)
  , simNsDiff  :: !(IORef Word64)
  }

-- | The arrays spatial ordering needs. @ordAid[j]@ is the original index of
-- the agent now in slot j and @ordSlot[a]@ is its inverse; everything that has
-- to speak in agent indices rather than slots -- the deposit, the agent hash
-- -- goes through one of them. The rest is staging for the counting sort,
-- allocated once so a re-sort costs no allocation at all.
data Order = Order
  { ordAid  :: !(IOUArray Int Word32)
  , ordSlot :: !(IOUArray Int Word32)
  , ordIdx  :: !(IOUArray Int Int)
  , ordKey  :: !(IOUArray Int Int)
  , ordF32  :: !(IOUArray Int Float)
  , ordU32  :: !(IOUArray Int Word32)
  , ordDir  :: !(IOUArray Int Int)
  }

-- ---- PRNG (SPEC-1 section 3.1) -------------------------------------------

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

-- | Advance the xoshiro128++ state stored at @arng[o .. o+3]@.
xoshiroNext :: IOUArray Int Word32 -> Int -> IO Word32
xoshiroNext !rng !o = do
  !s0 <- unsafeRead rng o
  !s1 <- unsafeRead rng (o + 1)
  !s2 <- unsafeRead rng (o + 2)
  !s3 <- unsafeRead rng (o + 3)
  let !result = rotl32 (s0 + s3) 7 + s0
      !t = s1 `shiftL` 9
      !s2a = s2 `xor` s0
      !s3a = s3 `xor` s1
      !s1a = s1 `xor` s2a
      !s0a = s0 `xor` s3a
      !s2b = s2a `xor` t
      !s3b = rotl32 s3a 11
  unsafeWrite rng o s0a
  unsafeWrite rng (o + 1) s1a
  unsafeWrite rng (o + 2) s2b
  unsafeWrite rng (o + 3) s3b
  pure result
{-# INLINE xoshiroNext #-}

-- | SPEC-1 section 3.2.
rnd01 :: Word32 -> Float
rnd01 !u = fromIntegral (u `shiftR` 8) / 16777216.0
{-# INLINE rnd01 #-}

-- | SPEC-1 section 2.2.
wrapf :: Float -> Float -> Float
wrapf !v0 !m =
  let !v1 = if v0 < 0.0 then v0 + m else v0
  in if v1 >= m then v1 - m else v1
{-# INLINE wrapf #-}

-- | The trig lookup, behind a switch, because the difference between the two
-- ways of writing it is a benchmark result rather than a matter of taste.
--
-- @unsafeAt@ is what the port uses. @(!)@ is the obvious way to write it, goes
-- through the @Ix@ class to compute the offset and range-checks it, and GHC
-- eliminates neither even though the bounds are a compile-time constant. The
-- index here has already been reduced mod NDIR, so the check can never fire.
--
-- Building the same source both ways (profile @o2-llvm-safetrig@) is what
-- makes section 4 of docs/RESULTS.md a measurement instead of a memory: the
-- slow variant was fixed rather than kept, and a comparison against a variant
-- that no longer compiles is not reproducible.
trigAt :: UArray Int Float -> Int -> Float
#ifdef SB_SAFE_TRIG
trigAt = (!)
#else
trigAt = unsafeAt
#endif
{-# INLINE trigAt #-}

-- ---- construction ---------------------------------------------------------

newSim :: Config -> IO Sim
newSim cfg@Config{..} = do
  let !cells = cfgWidth * cfgHeight
      !log2w = countLog2 cfgWidth
      !xmask = cfgWidth - 1
      !ymask = cfgHeight - 1

  grid <- newArray (0, cells - 1) 0.0 :: IO (IOUArray Int Float)
  scratch <- newArray (0, cells - 1) 0.0 :: IO (IOUArray Int Float)
  dep <- case cfgUpdate of
    Deferred -> Just <$> (newArray (0, cells - 1) 0.0 :: IO (IOUArray Int Float))
    Serial -> pure Nothing

  ax <- newArray (0, cfgAgents - 1) 0.0 :: IO (IOUArray Int Float)
  ay <- newArray (0, cfgAgents - 1) 0.0 :: IO (IOUArray Int Float)
  adir <- newArray (0, cfgAgents - 1) 0 :: IO (IOUArray Int Int)
  arng <- newArray (0, cfgAgents * 4 - 1) 0 :: IO (IOUArray Int Word32)

  -- Grid: one sequential SplitMix32 stream (SPEC-1 section 3.3).
  let goGrid !i !sm
        | i >= cells = pure ()
        | otherwise = do
            let (!sm', !u) = splitmix32 sm
            unsafeWrite grid i (rnd01 u * 100.0)
            goGrid (i + 1) sm'
  goGrid 0 (cfgSeed `xor` 0x5BF03635)

  -- Agents: one independent stream each.
  let !fw = fromIntegral cfgWidth :: Float
      !fh = fromIntegral cfgHeight :: Float
  forM_ [0 .. cfgAgents - 1] $ \i -> do
    let !o = i * 4
        !sm0 = cfgSeed + 0x9E3779B9 * fromIntegral (i + 1)
        (!sm1, !r0) = splitmix32 sm0
        (!sm2, !r1) = splitmix32 sm1
        (!sm3, !r2) = splitmix32 sm2
        (_, !r3) = splitmix32 sm3
        !r0' = if r0 .|. r1 .|. r2 .|. r3 == 0 then 1 else r0
    unsafeWrite arng o r0'
    unsafeWrite arng (o + 1) r1
    unsafeWrite arng (o + 2) r2
    unsafeWrite arng (o + 3) r3
    !u1 <- xoshiroNext arng o
    !u2 <- xoshiroNext arng o
    !u3 <- xoshiroNext arng o
    unsafeWrite ax i (rnd01 u1 * fw)
    unsafeWrite ay i (rnd01 u2 * fh)
    unsafeWrite adir i (fromIntegral (u3 `mod` fromIntegral ndir))

  gridRef <- newIORef grid
  scratchRef <- newIORef scratch
  ticksRef <- newIORef 0
  order <- if cfgAgentTile <= 0 then pure Nothing else do
    aidA  <- newListArray (0, cfgAgents - 1) [0 .. fromIntegral cfgAgents - 1]
    slotA <- newListArray (0, cfgAgents - 1) [0 .. fromIntegral cfgAgents - 1]
    idxA  <- newArray (0, cfgAgents - 1) 0
    keyA  <- newArray (0, cfgAgents - 1) 0
    f32A  <- newArray (0, cfgAgents - 1) 0
    u32A  <- newArray (0, cfgAgents * 4 - 1) 0
    dirA  <- newArray (0, cfgAgents - 1) 0
    pure (Just (Order aidA slotA idxA keyA f32A u32A dirA))
  nsA <- newIORef 0
  nsD <- newIORef 0
  pure Sim
    { simCfg = cfg, simLog2w = log2w, simXmask = xmask, simYmask = ymask
    , simGrid = gridRef, simScratch = scratchRef, simDep = dep
    , simAx = ax, simAy = ay, simAdir = adir, simArng = arng
    , simOrder = order, simTicks = ticksRef
    , simNsAgent = nsA, simNsDiff = nsD
    }

countLog2 :: Int -> Int
countLog2 v = go 0 where go !n = if (1 `shiftL` n) >= v then n else go (n + 1)

-- ---- tick -----------------------------------------------------------------

-- | A counting sort of the agent arrays into 8x8 tiles of the grid, so that
-- three sensor reads of neighbouring agents land in neighbouring cache lines.
-- impl/c/sb_core.c carries the measurement behind the tile size; this is the
-- same algorithm, on mutable unboxed arrays that are copied back rather than
-- swapped, because the record fields are strict and shared.
agentSort :: Sim -> Order -> IO ()
agentSort Sim{..} Order{..} = do
  let !n = cfgAgents simCfg
      !tileShift = 3 :: Int
      !tw = (cfgWidth simCfg + (1 `shiftL` tileShift) - 1) `shiftR` tileShift
      !th = (cfgHeight simCfg + (1 `shiftL` tileShift) - 1) `shiftR` tileShift
  count <- newArray (0, tw * th) 0 :: IO (IOUArray Int Int)
  let keys !j
        | j >= n = pure ()
        | otherwise = do
            !x <- unsafeRead simAx j
            !y <- unsafeRead simAy j
            let !xi = truncate x .&. simXmask
                !yi = truncate y .&. simYmask
                !k = (yi `shiftR` tileShift) * tw + (xi `shiftR` tileShift)
            unsafeWrite ordKey j k
            !c <- unsafeRead count k
            unsafeWrite count k (c + 1)
            keys (j + 1)
  keys 0
  -- Exclusive prefix sum, in place: count[k] becomes the first output slot of
  -- tile k.
  let scan !k !acc
        | k > tw * th - 1 = pure ()
        | otherwise = do
            !c <- unsafeRead count k
            unsafeWrite count k acc
            scan (k + 1) (acc + c)
  scan 0 0
  -- Stable: walking the agents in their current order keeps a re-sort cheap
  -- when almost nothing has moved.
  let place !j
        | j >= n = pure ()
        | otherwise = do
            !k <- unsafeRead ordKey j
            !dst <- unsafeRead count k
            unsafeWrite count k (dst + 1)
            unsafeRead simAx j >>= unsafeWrite ordF32 dst
            unsafeRead simAdir j >>= unsafeWrite ordDir dst
            let cp !w | w >= 4 = pure ()
                      | otherwise = do
                          !v <- unsafeRead simArng (j * 4 + w)
                          unsafeWrite ordU32 (dst * 4 + w) v
                          cp (w + 1)
            cp 0
            unsafeWrite ordKey j dst      -- reused as the permutation
            place (j + 1)
  place 0
  let copyBack !j
        | j >= n = pure ()
        | otherwise = do
            unsafeRead ordF32 j >>= unsafeWrite simAx j
            unsafeRead ordDir j >>= unsafeWrite simAdir j
            let cp !w | w >= 4 = pure ()
                      | otherwise = do
                          !v <- unsafeRead ordU32 (j * 4 + w)
                          unsafeWrite simArng (j * 4 + w) v
                          cp (w + 1)
            cp 0
            copyBack (j + 1)
  copyBack 0
  let permY !j
        | j >= n = pure ()
        | otherwise = do
            !d <- unsafeRead ordKey j
            unsafeRead simAy j >>= unsafeWrite ordF32 d
            permY (j + 1)
  permY 0
  let backY !j
        | j >= n = pure ()
        | otherwise = unsafeRead ordF32 j >>= unsafeWrite simAy j >> backY (j + 1)
  backY 0
  let permId !j
        | j >= n = pure ()
        | otherwise = do
            !d <- unsafeRead ordKey j
            unsafeRead ordAid j >>= unsafeWrite ordU32 d
            permId (j + 1)
  permId 0
  let backId !j
        | j >= n = pure ()
        | otherwise = do
            !v <- unsafeRead ordU32 j
            unsafeWrite ordAid j v
            unsafeWrite ordSlot (fromIntegral v) (fromIntegral j)
            backId (j + 1)
  backId 0

tick :: Sim -> IO ()
tick sim@Sim{..} = do
  -- Re-sort inside the timed region, not beside it: the ordering is only
  -- worth having if it pays for itself.
  case simOrder of
    Nothing -> pure ()
    Just o -> do
      !t <- readIORef simTicks
      when (t `mod` cfgAgentTile simCfg == 0) (agentSort sim o)
      writeIORef simTicks (t + 1)

  !t0 <- nowNs
  case simOrder of
    Nothing -> agentPass sim
    Just o -> do
      -- With spatial ordering the step order is no longer the agent order, so
      -- the deposits are buffered and applied afterwards in ascending *agent*
      -- index -- the same order, and therefore the same floats, as the direct
      -- loop.
      let !n = cfgAgents simCfg
          !d = cfgDeposit simCfg
      agentRange sim 0 n (Just (ordIdx o))
      target <- case simDep of
                  Just dep -> pure dep
                  Nothing  -> readIORef simGrid
      let dep !a
            | a >= n = pure ()
            | otherwise = do
                !sl <- unsafeRead (ordSlot o) a
                !idx <- unsafeRead (ordIdx o) (fromIntegral sl)
                !cur <- unsafeRead target idx
                unsafeWrite target idx (cur + d)
                dep (a + 1)
      dep 0
  !t1 <- nowNs

  case simDep of
    Nothing -> pure ()
    Just dep -> do
      grid <- readIORef simGrid
      let !cells = cfgWidth simCfg * cfgHeight simCfg
          go !i
            | i >= cells = pure ()
            | otherwise = do
                !g <- unsafeRead grid i
                !d <- unsafeRead dep i
                unsafeWrite grid i (g + d)
                unsafeWrite dep i 0.0
                go (i + 1)
      go 0

  diffusePass sim
  !t2 <- nowNs

  modifyIORef' simNsAgent (+ (t1 - t0))
  modifyIORef' simNsDiff (+ (t2 - t1))
  where
    modifyIORef' r f = readIORef r >>= \v -> let !v' = f v in writeIORef r v'

-- | SPEC-1 section 5.3.
agentPass :: Sim -> IO ()
agentPass sim = agentRange sim 0 (cfgAgents (simCfg sim)) Nothing

-- | SPEC-1 section 5.3 over agents @[lo, hi)@.
--
-- With @Just aidx@ the deposit is /not/ applied; the target cell is recorded
-- in @aidx[i]@ for a later phase to apply in a chosen order. That is what
-- class P's @binned@ reduction needs, and it is the only thing the threaded
-- caller does differently -- everything above it has to stay identical, or the
-- threaded run stops being the same simulation.
agentRange :: Sim -> Int -> Int -> Maybe (IOUArray Int Int) -> IO ()
agentRange Sim{..} !lo !hi !mAidx = do
  grid <- readIORef simGrid
  target <- case simDep of
    Just dep -> pure dep
    Nothing -> pure grid

  let Config{..} = simCfg
      !fw = fromIntegral cfgWidth :: Float
      !fh = fromIntegral cfgHeight :: Float
      !ndirI = ndir
      !log2w = simLog2w
      !xmask = simXmask
      !ymask = simYmask

      sense :: Float -> Float -> Int -> IO Float
      sense !x !y !d = do
        let !sx = wrapf (x + (cosTable `trigAt` d) * cfgSensorDist) fw
            !sy = wrapf (y + (sinTable `trigAt` d) * cfgSensorDist) fh
            !ix = truncate sx .&. xmask
            !iy = truncate sy .&. ymask
        unsafeRead grid ((iy `shiftL` log2w) .|. ix)
      {-# INLINE sense #-}

      go :: Int -> IO ()
      go !i
        | i >= hi = pure ()
        | otherwise = do
            !d0 <- unsafeRead simAdir i
            !x0 <- unsafeRead simAx i
            !y0 <- unsafeRead simAy i

            let !dl = (d0 - cfgSensorSteps + ndirI) `mod` ndirI
                !dr = (d0 + cfgSensorSteps) `mod` ndirI
            !fl <- sense x0 y0 dl
            !fc <- sense x0 y0 d0
            !fr <- sense x0 y0 dr

            !d <- if fc >= fl && fc >= fr
                    then pure d0
                    else if fc < fl && fc < fr
                      then do
                        !r <- xoshiroNext simArng (i * 4)
                        pure $ if r .&. 1 /= 0
                                 then (d0 + cfgRotSteps) `mod` ndirI
                                 else (d0 - cfgRotSteps + ndirI) `mod` ndirI
                      else if fl > fr
                        then pure ((d0 - cfgRotSteps + ndirI) `mod` ndirI)
                        else pure ((d0 + cfgRotSteps) `mod` ndirI)

            let !x = wrapf (x0 + (cosTable `trigAt` d) * cfgStep) fw
                !y = wrapf (y0 + (sinTable `trigAt` d) * cfgStep) fh
                !ix = truncate x .&. xmask
                !iy = truncate y .&. ymask
                !idx = (iy `shiftL` log2w) .|. ix

            case mAidx of
              Nothing -> do
                !cur <- unsafeRead target idx
                unsafeWrite target idx (cur + cfgDeposit)
              Just aidx -> unsafeWrite aidx i idx
            unsafeWrite simAdir i d
            unsafeWrite simAx i x
            unsafeWrite simAy i y
            go (i + 1)
  go lo

-- | SPEC-1 section 5.4. Summation order is normative -- do not reorder.
diffusePass :: Sim -> IO ()
diffusePass sim = diffuseRows sim 0 (cfgHeight (simCfg sim)) >> swapBuffers sim

-- | Exchange the two grid buffers. Separate from 'diffuseRows' because the
-- threaded path swaps once for the whole pool, not once per row block.
swapBuffers :: Sim -> IO ()
swapBuffers Sim{..} = do
  src <- readIORef simGrid
  dst <- readIORef simScratch
  writeIORef simGrid dst
  writeIORef simScratch src

-- | Fold @dep@ into @grid@ over rows @[y0, y1)@ and clear it.
mergeRows :: Sim -> Int -> Int -> IO ()
mergeRows Sim{..} !y0 !y1 = case simDep of
  Nothing -> pure ()
  Just dep -> do
    grid <- readIORef simGrid
    let !lo = y0 `shiftL` simLog2w
        !hi = y1 `shiftL` simLog2w
        go !i
          | i >= hi = pure ()
          | otherwise = do
              !g <- unsafeRead grid i
              !d <- unsafeRead dep i
              unsafeWrite grid i (g + d)
              unsafeWrite dep i 0.0
              go (i + 1)
    go lo

-- | SPEC-1 section 5.4 over rows @[y0, y1)@, writing into @scratch@ without
-- swapping. Output cells are independent, so splitting the row range across
-- threads is unconditionally bit-identical.
diffuseRows :: Sim -> Int -> Int -> IO ()
diffuseRows Sim{..} !y0 !y1 = do
  src <- readIORef simGrid
  dst <- readIORef simScratch
  let Config{..} = simCfg
      !w = cfgWidth
      !log2w = simLog2w
      !xmask = simXmask
      !ymask = simYmask
      !decay = cfgDecay

      row :: Int -> Int
      row !y = (y .&. ymask) `shiftL` log2w
      {-# INLINE row #-}

      goY !y
        | y >= y1 = pure ()
        | otherwise = do
            let !rowm = row (y - 1)
                !row0 = y `shiftL` log2w
                !rowp = row (y + 1)
                goX !x
                  | x >= w = pure ()
                  | otherwise = do
                      let !xm = (x - 1) .&. xmask
                          !xp = (x + 1) .&. xmask
                      !a0 <- unsafeRead src (rowm .|. xm)
                      !a1 <- unsafeRead src (rowm .|. x)
                      !a2 <- unsafeRead src (rowm .|. xp)
                      !a3 <- unsafeRead src (row0 .|. xm)
                      !a4 <- unsafeRead src (row0 .|. x)
                      !a5 <- unsafeRead src (row0 .|. xp)
                      !a6 <- unsafeRead src (rowp .|. xm)
                      !a7 <- unsafeRead src (rowp .|. x)
                      !a8 <- unsafeRead src (rowp .|. xp)
                      let !s1 = a0 + a1
                          !s2 = s1 + a2
                          !s3 = s2 + a3
                          !s4 = s3 + 4.0 * a4
                          !s5 = s4 + a5
                          !s6 = s5 + a6
                          !s7 = s6 + a7
                          !s8 = s7 + a8
                      unsafeWrite dst (row0 .|. x) ((s8 / 12.0) * decay)
                      goX (x + 1)
            goX 0
            goY (y + 1)
  goY y0

-- ---- checksums (SPEC-1 section 6) ----------------------------------------

hashGrid :: Sim -> IO Word32
hashGrid Sim{..} = do
  grid <- readIORef simGrid
  let !cells = cfgWidth simCfg * cfgHeight simCfg
      go !i !h
        | i >= cells = pure h
        | otherwise = do
            !v <- unsafeRead grid i
            go (i + 1) ((h `xor` castFloatToWord32 v) * fnvPrime)
  go 0 fnvOffset

-- | In agent order, which is slot order only when the arrays have not been
-- spatially re-sorted. A checksum that changed with a performance flag would
-- defeat the point of having one.
hashAgents :: Sim -> IO Word32
hashAgents Sim{..} = do
  let !n = cfgAgents simCfg
      go !a !h
        | a >= n = pure h
        | otherwise = do
            !i <- case simOrder of
                    Nothing -> pure a
                    Just o  -> fromIntegral <$> unsafeRead (ordSlot o) a
            !x <- unsafeRead simAx i
            !y <- unsafeRead simAy i
            !d <- unsafeRead simAdir i
            let !h1 = (h `xor` castFloatToWord32 x) * fnvPrime
                !h2 = (h1 `xor` castFloatToWord32 y) * fnvPrime
                !h3 = (h2 `xor` fromIntegral d) * fnvPrime
            -- `a + 1`, not `i + 1`: the loop walks agents, and `i` is the
            -- slot that agent currently sits in. Recursing on the slot walked
            -- a permutation of the agents instead of the agents, which the
            -- separate agent hash caught immediately -- the grid hash was
            -- right, so the deposits were right, so it could only be the
            -- checksum itself. SPEC-1 6.3 keeps the two apart for this.
            go (a + 1) h3
  go 0 fnvOffset

dirtableHashRuntime :: Word32
dirtableHashRuntime = foldl step fnvOffset (cosBits ++ sinBits)
  where step !h !b = (h `xor` b) * fnvPrime

-- | SPEC-1 section 11, straight into a caller-supplied buffer.
--
-- 'renderGray' returns a list, which is fine for a one-shot dump and useless
-- at 60 frames a second: a four-million-element @[Word8]@ is four million
-- cons cells per frame. The windowed frontends poke the bytes instead.
renderGrayPtr :: Sim -> Float -> Ptr Word8 -> IO ()
renderGrayPtr Sim{..} !displayMax !dst = do
  grid <- readIORef simGrid
  let !cells = cfgWidth simCfg * cfgHeight simCfg
      !scale = 255.0 / displayMax
      go !i
        | i >= cells = pure ()
        | otherwise = do
            !v <- unsafeRead grid i
            let !b = truncate (v * scale) :: Int
                !c = if b < 0 then 0 else if b > 255 then 255 else b
            pokeByteOff dst i (fromIntegral c :: Word8)
            go (i + 1)
  go 0

-- | The same, expanded to ARGB8888.
--
-- SDL2 has no 8-bit greyscale texture, so this loop exists in the SDL2
-- frontend and not in the raylib one. That asymmetry is the thing class R
-- measures, so it is written out rather than hidden behind a helper both
-- backends share.
renderArgbPtr :: Sim -> Float -> Ptr Word8 -> IO ()
renderArgbPtr Sim{..} !displayMax !dst = do
  grid <- readIORef simGrid
  let !cells = cfgWidth simCfg * cfgHeight simCfg
      !scale = 255.0 / displayMax
      go !i
        | i >= cells = pure ()
        | otherwise = do
            !v <- unsafeRead grid i
            let !b = truncate (v * scale) :: Int
                !c = fromIntegral (if b < 0 then 0 else if b > 255 then 255 else b) :: Word8
                !o = i * 4
            pokeByteOff dst o       c
            pokeByteOff dst (o + 1) c
            pokeByteOff dst (o + 2) c
            pokeByteOff dst (o + 3) (255 :: Word8)
            go (i + 1)
  go 0

-- | SPEC-1 section 11.
renderGray :: Sim -> Float -> IO [Word8]
renderGray sim displayMax = do
  grid <- readIORef (simGrid sim)
  vals <- getElems grid
  let !scale = 255.0 / displayMax
  pure [ fromIntegral (max 0 (min 255 (truncate (v * scale) :: Int))) | v <- vals ]

-- | The whole grid in index order; used for @--dump-grid@ only.
gridValues :: Sim -> IO [Float]
gridValues sim = readIORef (simGrid sim) >>= getElems

resetTimers :: Sim -> IO ()
resetTimers Sim{..} = writeIORef simNsAgent 0 >> writeIORef simNsDiff 0

readNsAgent, readNsDiff :: Sim -> IO Word64
readNsAgent = readIORef . simNsAgent
readNsDiff = readIORef . simNsDiff

nowNs :: IO Word64
nowNs = getMonotonicTimeNSec
