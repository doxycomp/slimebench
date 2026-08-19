{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

-- | Multi-threaded tick (SPEC-1 section 5.6, benchmark class P).
--
-- Both reduction strategies, the same phase order and the same deposit order
-- as the C reference, so @binned@ is bit-identical to the single-threaded run
-- here too. The agent rule and the stencil are not reimplemented: this module
-- calls 'Sim.agentRange' and 'Sim.diffuseRows', the same code the serial path
-- uses.
--
-- == What is different about doing this in Haskell
--
-- The workers are 'forkOn' green threads, one pinned per capability, over
-- shared 'IOUArray's. Nothing here is idiomatic-functional and nothing can be:
-- the whole point of class P is in-place mutation of one grid by several
-- threads, which is what 'Data.Array.IO' plus @-threaded@ is for. The
-- interesting question is what the runtime costs at the barriers.
--
-- The barrier is 'MVar'-based rather than STM. An STM barrier is the prettier
-- Haskell -- @retry@ blocks until the generation counter changes and reads
-- like the textbook -- but every waiter re-validates its transaction on each
-- wakeup, and with six barriers per tick and 32 threads that is a retry storm.
-- Counting into one 'MVar' and releasing through one gate per thread wakes
-- each waiter exactly once.
module Parallel
  ( ReduceMode(..)
  , runParallel
  ) where

import Control.Concurrent (forkOn, getNumCapabilities, setNumCapabilities)
import Control.Concurrent.MVar
import Control.Monad (forM, forM_, when)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.IO (IOUArray, newArray, newListArray)
import Data.Bits (shiftL, shiftR)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)

import Sim

data ReduceMode = Private | Binned deriving (Eq, Show)

-- ---- barrier ---------------------------------------------------------------

data Barrier = Barrier !Int !(MVar Int) ![MVar ()]

newBarrier :: Int -> IO Barrier
newBarrier n = Barrier n <$> newMVar 0 <*> forM [1 .. n] (const newEmptyMVar)

-- | Every thread calls this; it returns once all @n@ have arrived.
barrierWait :: Barrier -> Int -> IO ()
barrierWait (Barrier n cnt gates) !tid = do
  c <- takeMVar cnt
  if c + 1 == n
    then do
      putMVar cnt 0
      forM_ (zip [0 ..] gates) $ \(i, g) -> when (i /= (tid :: Int)) (putMVar g ())
    else do
      putMVar cnt (c + 1)
      takeMVar (gates !! tid)

-- ---- pool state ------------------------------------------------------------

-- | Contiguous split of @[0, n)@ into @parts@; part @i@ is @[lo, hi)@.
-- Identical to the C reference's @split@, deliberately: the partition is what
-- makes @binned@ reproduce the serial deposit order.
splitRange :: Int -> Int -> Int -> (Int, Int)
splitRange !n !parts !i =
  let !base = n `div` parts
      !rem' = n `mod` parts
      !lo = i * base + min i rem'
  in (lo, lo + base + (if i < rem' then 1 else 0))
{-# INLINE splitRange #-}

data Pool = Pool
  { pSim      :: !Sim
  , pThreads  :: !Int
  , pReduce   :: !ReduceMode
  , pBarrier  :: !Barrier
  , pAdaptive :: !Bool
    -- Binned
  , pAidx     :: !(IOUArray Int Int)
  , pSorted   :: !(IOUArray Int Int)
  , pCounts   :: !(IOUArray Int Int)
  , pOffsets  :: !(IOUArray Int Int)
  , pYBucket  :: !(IOUArray Int Int)
  , pRowCnt   :: !(IOUArray Int Int)
  , pRowSum   :: !(IOUArray Int Int)
    -- Private: one grid-sized deposit buffer per thread, flattened
  , pPriv     :: !(IOUArray Int Float)
  }

bucketOf :: Pool -> Int -> IO Int
bucketOf Pool{..} !idx = unsafeRead pYBucket (idx `shiftR` simLog2w pSim)
{-# INLINE bucketOf #-}

-- ---- phases ----------------------------------------------------------------

agentsPrivate :: Pool -> Int -> IO ()
agentsPrivate Pool{..} !tid = do
  let (lo, hi) = splitRange (cfgAgents (simCfg pSim)) pThreads tid
      !cells = cfgWidth (simCfg pSim) * cfgHeight (simCfg pSim)
      !base = tid * cells
      !deposit = cfgDeposit (simCfg pSim)
  -- Record targets, then apply into this thread's own buffer. Going through
  -- `agentRange` with an index array rather than letting it deposit is what
  -- keeps one copy of the rule for both strategies.
  agentRange pSim lo hi (Just pAidx)
  let go !i
        | i >= hi = pure ()
        | otherwise = do
            !idx <- unsafeRead pAidx i
            !cur <- unsafeRead pPriv (base + idx)
            unsafeWrite pPriv (base + idx) (cur + deposit)
            go (i + 1)
  go lo

-- | Fixed thread order, so the result is reproducible for this thread count.
-- It is NOT in general the same grouping as the serial chain -- SPEC-1 5.6.
mergePrivate :: Pool -> Int -> IO ()
mergePrivate Pool{..} !tid = do
  grid <- simGridArray pSim
  let !cells = cfgWidth (simCfg pSim) * cfgHeight (simCfg pSim)
      (lo, hi) = splitRange cells pThreads tid
      go !i
        | i >= hi = pure ()
        | otherwise = do
            !a0 <- unsafeRead pPriv i
            unsafeWrite pPriv i 0.0
            let acc !t !s
                  | t >= pThreads = pure s
                  | otherwise = do
                      !v <- unsafeRead pPriv (t * cells + i)
                      unsafeWrite pPriv (t * cells + i) 0.0
                      acc (t + 1) (s + v)
            !s <- acc 1 a0
            !g <- unsafeRead grid i
            unsafeWrite grid i (g + s)
            go (i + 1)
  go lo

agentsBinned :: Pool -> Int -> IO ()
agentsBinned p@Pool{..} !tid = do
  let (lo, hi) = splitRange (cfgAgents (simCfg pSim)) pThreads tid
      !t = pThreads
      !cbase = tid * t
      !h = cfgHeight (simCfg pSim)
      !rbase = tid * h
  forM_ [0 .. t - 1] $ \b -> unsafeWrite pCounts (cbase + b) 0
  when pAdaptive $ forM_ [0 .. h - 1] $ \y -> unsafeWrite pRowCnt (rbase + y) 0

  agentRange pSim lo hi (Just pAidx)

  let go !i
        | i >= hi = pure ()
        | otherwise = do
            !idx <- unsafeRead pAidx i
            !b <- bucketOf p idx
            !c <- unsafeRead pCounts (cbase + b)
            unsafeWrite pCounts (cbase + b) (c + 1)
            when pAdaptive $ do
              let !y = idx `shiftR` simLog2w pSim
              !r <- unsafeRead pRowCnt (rbase + y)
              unsafeWrite pRowCnt (rbase + y) (r + 1)
            go (i + 1)
  go lo

-- | Prefix sum over (bucket, thread) in that order, by thread 0 alone.
-- Because each thread owns a contiguous ascending agent range, walking threads
-- in order inside a bucket lays the agents down in ascending global index --
-- which is what makes the deposit chain identical to the serial one.
prefixBinned :: Pool -> IO ()
prefixBinned Pool{..} = do
  let !t = pThreads
      goB !b !running
        | b >= t = pure ()
        | otherwise = do
            let goW !w !r
                  | w >= t = pure r
                  | otherwise = do
                      unsafeWrite pOffsets (w * t + b) r
                      !c <- unsafeRead pCounts (w * t + b)
                      goW (w + 1) (r + c)
            !r' <- goW 0 running
            goB (b + 1) r'
  goB 0 0

scatterBinned :: Pool -> Int -> IO ()
scatterBinned p@Pool{..} !tid = do
  let (lo, hi) = splitRange (cfgAgents (simCfg pSim)) pThreads tid
      !obase = tid * pThreads
      go !i
        | i >= hi = pure ()
        | otherwise = do
            !idx <- unsafeRead pAidx i
            !b <- bucketOf p idx
            !o <- unsafeRead pOffsets (obase + b)
            unsafeWrite pSorted o i
            unsafeWrite pOffsets (obase + b) (o + 1)
            go (i + 1)
  go lo

-- | Applies exactly the deposits landing in this thread's row block, in
-- ascending agent index. Cells in other blocks are never touched.
depositBinned :: Pool -> Int -> IO ()
depositBinned Pool{..} !tid = do
  let !t = pThreads
      !deposit = cfgDeposit (simCfg pSim)
  dep <- case simDep pSim of
    Just d -> pure d
    Nothing -> error "binned reduction requires --update deferred"

  let sumRange !b0 !b1 = goB b0 0
        where goB !b !acc
                | b >= b1 = pure acc
                | otherwise = do
                    let goW !w !a
                          | w >= t = pure a
                          | otherwise = do
                              !c <- unsafeRead pCounts (w * t + b)
                              goW (w + 1) (a + c)
                    !a' <- goW 0 acc
                    goB (b + 1) a'
  !begin <- sumRange 0 tid
  !end <- (begin +) <$> sumRange tid (tid + 1)

  let go !j
        | j >= end = pure ()
        | otherwise = do
            !i <- unsafeRead pSorted j
            !idx <- unsafeRead pAidx i
            !cur <- unsafeRead dep idx
            unsafeWrite dep idx (cur + deposit)
            go (j + 1)
  go begin

-- | Partitioned by rows rather than cells so the same pass can reduce the
-- per-row histograms; a row range is a contiguous cell range anyway.
mergeBinned :: Pool -> Int -> IO ()
mergeBinned Pool{..} !tid = do
  let !h = cfgHeight (simCfg pSim)
      (ylo, yhi) = splitRange h pThreads tid
  mergeRows pSim ylo yhi
  when pAdaptive $ forM_ [ylo .. yhi - 1] $ \y -> do
    let go !t !acc
          | t >= pThreads = pure acc
          | otherwise = do
              !v <- unsafeRead pRowCnt (t * h + y)
              go (t + 1) (acc + v)
    !s <- go 0 0
    unsafeWrite pRowSum y s

-- | Recompute row boundaries so every thread gets a similar number of
-- deposits. Cannot change the result: the partition decides /which/ thread
-- applies a deposit, never the order deposits hit a cell.
rebalance :: Pool -> IO ()
rebalance Pool{..} = do
  let !h = cfgHeight (simCfg pSim)
      !t = pThreads
  !total <- let go !y !acc | y >= h = pure acc
                           | otherwise = do !v <- unsafeRead pRowSum y
                                            go (y + 1) (acc + fromIntegral v :: Integer)
            in go 0 0
  when (total > 0) $ do
    let go !y !b !acc
          | y >= h = pure ()
          | otherwise = do
              unsafeWrite pYBucket y b
              !v <- unsafeRead pRowSum y
              let !acc' = acc + fromIntegral v
                  climb !bb
                    | bb + 1 < t
                      && acc' * fromIntegral t >= total * fromIntegral (bb + 1)
                      && (h - y - 1) >= (t - bb - 1) = climb (bb + 1)
                    | otherwise = bb
              go (y + 1) (climb b) acc'
    go 0 0 (0 :: Integer)

-- ---- the tick --------------------------------------------------------------

-- | One tick, run by every thread. Ends with a barrier, so on return the whole
-- pool is quiesced.
--
-- Six barriers for @binned@, matching the C reference's five phase barriers
-- plus its master/worker handshake. The rebalance overlaps the diffusion pass,
-- which does not read @ybucket@.
runTick :: Pool -> Int -> IO ()
runTick p@Pool{..} !tid = do
  case pReduce of
    Binned -> do
      agentsBinned p tid
      barrierWait pBarrier tid
      when (tid == 0) (prefixBinned p)
      barrierWait pBarrier tid
      scatterBinned p tid
      barrierWait pBarrier tid
      depositBinned p tid
      barrierWait pBarrier tid
      mergeBinned p tid
      barrierWait pBarrier tid
      when (tid == 0 && pAdaptive) (rebalance p)
    Private -> do
      agentsPrivate p tid
      barrierWait pBarrier tid
      mergePrivate p tid
      barrierWait pBarrier tid

  let (ylo, yhi) = splitRange (cfgHeight (simCfg pSim)) pThreads tid
  diffuseRows pSim ylo yhi
  barrierWait pBarrier tid
  -- The two IORefs are shared, so exactly one thread swaps them, and it does
  -- so between two barriers -- everyone else is parked. This is the sync point
  -- the TypeScript port does not need, because there each worker holds its own
  -- Sim object over the same buffers and can swap locally.
  when (tid == 0) (swapBuffers pSim)
  barrierWait pBarrier tid

-- ---- entry point -----------------------------------------------------------

-- | Run @warmup + ticks@ ticks across @cfgThreads@ threads.
--
-- Returns the per-tick wall times, or 'Left' for the one case SPEC-1 forbids.
runParallel :: Sim -> ReduceMode -> Bool -> Int -> Int -> IO (Either String [Double])
runParallel sim reduce adaptive warmup ticks
  | cfgUpdate (simCfg sim) /= Deferred = pure . Left $ unlines
      [ "--threads > 1 requires --update deferred."
      , "       SPEC-1 'serial' makes an agent's deposit visible to the"
      , "       next agent in the same tick, which is a sequential"
      , "       dependency; see SPEC-1 section 5.5."
      ]
  | otherwise = do
      let cfg = simCfg sim
          !t = cfgThreads cfg
          !n = cfgAgents cfg
          !h = cfgHeight cfg
          !cells = cfgWidth cfg * cfgHeight cfg
          !binned = reduce == Binned

      -- One capability per worker, and each worker pinned to its own, so the
      -- runtime does not migrate them between the two CCDs mid-tick.
      caps <- getNumCapabilities
      when (caps /= t) (setNumCapabilities t)

      aidx <- newArray (0, max 0 (n - 1)) 0
      sorted <- newArray (0, max 0 (if binned then n - 1 else 0)) 0
      counts <- newArray (0, max 0 (t * t - 1)) 0
      offsets <- newArray (0, max 0 (t * t - 1)) 0
      -- Same split as the diffusion pass, so a thread's deposits land in rows
      -- it already touches.
      -- Row -> owning thread. Built by walking the blocks rather than
      -- searching per row: same partition, and total by construction.
      ybucket <- newListArray (0, h - 1)
        (concat [ replicate (hi - lo) b
                | b <- [0 .. t - 1], let (lo, hi) = splitRange h t b ])
      rowcnt <- newArray (0, max 0 (if binned && adaptive then t * h - 1 else 0)) 0
      rowsum <- newArray (0, max 0 (if binned && adaptive then h - 1 else 0)) 0
      privb <- newArray (0, max 0 (if binned then 0 else t * cells - 1)) 0.0
      tickRef <- newIORef []

      bar <- newBarrier t
      let pool = Pool { pSim = sim, pThreads = t, pReduce = reduce, pBarrier = bar
                      , pAdaptive = adaptive && binned
                      , pAidx = aidx, pSorted = sorted, pCounts = counts
                      , pOffsets = offsets, pYBucket = ybucket
                      , pRowCnt = rowcnt, pRowSum = rowsum, pPriv = privb }

      dones <- forM [1 .. t - 1] $ \tid -> do
        mv <- newEmptyMVar
        _ <- forkOn tid $ do
          forM_ [1 .. warmup + ticks] $ \_ -> runTick pool tid
          putMVar mv ()
        pure mv

      -- Thread 0 is a worker like the others; it just also holds the clock.
      -- `runTick` ends with a barrier, so reading it here measures the whole
      -- pool rather than thread 0's own progress.
      forM_ [1 .. warmup] $ \_ -> runTick pool 0
      resetTimers sim
      forM_ [1 .. ticks] $ \_ -> do
        !a <- nowNs
        runTick pool 0
        !b <- nowNs
        modifyIORef'' tickRef ((fromIntegral (b - a) / 1e6 :: Double) :)

      mapM_ takeMVar dones
      Right . reverse <$> readIORef tickRef
  where
    modifyIORef'' r f = readIORef r >>= \v -> let !v' = f v in writeIORef r v'

-- | The live grid buffer. The pool needs it directly for the private-buffer
-- reduction, which is the one phase that is not expressible as a row range.
simGridArray :: Sim -> IO (IOUArray Int Float)
simGridArray = readIORef . simGrid
