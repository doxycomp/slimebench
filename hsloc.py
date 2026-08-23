import pathlib


def patch(rel, pairs):
    p = pathlib.Path(rel)
    s = p.read_text(encoding="utf-8")
    for a, b in pairs:
        assert a in s, f"NOT FOUND in {rel}:\n{a[:200]}"
        s = s.replace(a, b, 1)
    p.write_text(s, encoding="utf-8", newline="\n")
    print("patched", rel)


patch("impl/haskell/src/Sim.hs", [
    ("  , cfgThreads     :: !Int",
     "  , cfgThreads     :: !Int\n"
     "  -- | Ticks between spatial re-sorts of the agent arrays; 0 = never.\n"
     "  -- See 'agentSort' -- it changes which agent sits where, not what any\n"
     "  -- of them computes.\n"
     "  , cfgAgentTile   :: !Int"),

    ("  , cfgTicks = 1000, cfgWarmup = 0, cfgSeed = 12345, cfgThreads = 1",
     "  , cfgTicks = 1000, cfgWarmup = 0, cfgSeed = 12345, cfgThreads = 1\n"
     "  , cfgAgentTile = 0"),

    ("""  , simNsAgent :: !(IORef Int)""",
     """  -- | Spatial ordering ('cfgAgentTile'). @simAid[j]@ is the original index
  -- of the agent now in slot j and @simSlot[a]@ is its inverse; everything
  -- that has to speak in agent indices rather than slots -- the deposit, the
  -- agent hash -- goes through one of them. 'Nothing' when ordering is off.
  , simOrder   :: !(Maybe Order)
  , simTicks   :: !(IORef Int)
  , simNsAgent :: !(IORef Int)"""),

    ("""    , simNsAgent = nsA, simNsDiff = nsD
    }""",
     """    , simOrder = order, simTicks = ticksRef
    , simNsAgent = nsA, simNsDiff = nsD
    }"""),

    ("""  gridRef <- newIORef grid
  scratchRef <- newIORef scratch
  nsA <- newIORef 0""",
     """  gridRef <- newIORef grid
  scratchRef <- newIORef scratch
  ticksRef <- newIORef 0
  order <- if cfgAgentTile cfg <= 0 then pure Nothing else do
    aid  <- newListArray (0, n - 1) [0 .. fromIntegral n - 1]
    slot <- newListArray (0, n - 1) [0 .. fromIntegral n - 1]
    aidx <- newArray (0, n - 1) 0
    key  <- newArray (0, n - 1) 0
    sf   <- newArray (0, n - 1) 0
    su   <- newArray (0, n * 4 - 1) 0
    sd   <- newArray (0, n - 1) 0
    pure (Just (Order aid slot aidx key sf su sd))
  nsA <- newIORef 0"""),

    ("""hashAgents :: Sim -> IO Word32
hashAgents Sim{..} = do
  let !n = cfgAgents simCfg
      go !i !h
        | i >= n = pure h
        | otherwise = do
            !x <- unsafeRead simAx i
            !y <- unsafeRead simAy i
            !d <- unsafeRead simAdir i""",
     """-- | In agent order, which is slot order only when the arrays have not been
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
            !d <- unsafeRead simAdir i"""),
])
print("haskell stage one")
