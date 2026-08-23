using System.Runtime.CompilerServices;

namespace Slimebench;

/// <summary>
/// slimebench -- C# implementation of SPEC-1 (conformance tier A).
///
/// <para><b>Why this port exists.</b> As a language C# is close enough to Java
/// that a second managed-JIT-with-GC row would add little. What it adds is an
/// axis nothing else in this project has: the identical source runs under a
/// tracing JIT <i>and</i> compiles ahead of time to a native binary with no JIT
/// and no runtime at all. Stock OpenJDK cannot do that, so the question "what
/// does the JIT's runtime profile buy over ahead-of-time compilation?" was
/// unanswerable here until now. build.sh produces four configurations from
/// this one file and they must all agree bit for bit.</para>
///
/// <para><b>Exactness.</b> No tricks are needed. Since .NET Core 3.0 float
/// arithmetic is strict IEEE binary32 -- an operation on two floats yields a
/// float, and the runtime is not permitted to keep a wider intermediate. Nor
/// may the JIT contract a multiply and an add: <c>Math.FusedMultiplyAdd</c>
/// exists precisely because fusing has to be requested. So the stencil is
/// written plainly, without the redundant conversions impl/go carries and
/// without the rounding calls impl/ocaml needs.</para>
///
/// <para><b>Unsigned arithmetic.</b> C# has <c>uint</c>, and arithmetic is
/// unchecked by default, so the PRNG in SPEC-1 section 3.1 transcribes
/// directly -- no masking as in the OCaml and Fortran ports, no signed
/// reinterpretation as in Java.</para>
///
/// <para><b>What is deliberately not done.</b> No <c>unsafe</c>, no
/// <c>Span</c> tricks, no <c>Unsafe.Add</c> to skip bounds checks. The arrays
/// are plain <c>float[]</c>. Section 3 of docs/RESULTS.md prices bounds checks
/// in four other languages; adding an unsafe variant here would measure how
/// much unsafe code one is willing to write.</para>
/// </summary>
internal sealed class Sim
{
    public const string SpecVersion = "SPEC-1";

    private const uint FnvOffset = 0x811C9DC5u;
    private const uint FnvPrime = 0x01000193u;

    internal sealed class Config
    {
        public int Width = 1024, Height = 1024;
        public int Agents = 262144;
        public int Ticks = 1000, Warmup = 0;
        public uint Seed = 12345;
        public int Threads = 1;
        public string Update = "serial";
        public string Reduce = "binned";
        public float SensorDist = 9.0f;
        public float Step = 1.0f;
        public float Deposit = 10.0f;
        public float Decay = 0.94f;
        public int SensorSteps = 144, RotSteps = 144;
        public int HashEvery = 0;
        public bool Simd = false;
        /// <summary>Ticks between spatial re-sorts of the agent arrays;
        /// 0 = never. See Sim.AgentSort -- it changes which agent sits
        /// where, not what any of them computes.</summary>
        public int AgentTile = 0;
        // Force the portable Vector<T> even where Vector512 is available.
        public bool SimdPortable = false;
        public string Preset = "custom";
    }

    public readonly Config Cfg;
    private readonly int _log2w, _xmask, _ymask;

    public float[] Grid, Scratch;
    public readonly float[]? Dep;
    public readonly float[] Ax, Ay;
    public readonly ushort[] Adir;
    public readonly uint[] Arng;

    // Spatial ordering (Config.AgentTile). _aid[j] is the original index of
    // the agent now in slot j and _slot[a] is its inverse; everything that has
    // to speak in agent indices rather than slots -- the deposit, the agent
    // hash -- goes through one of them. null when ordering is off.
    private int[]? _aid, _slot, _agentIdx, _sortKey;
    private uint[]? _sortU32;
    private float[]? _sortF32;
    private ushort[]? _sortU16;
    private int _ticksDone;

    private readonly float[] _cos = new float[Dirtable.NDIR];
    private readonly float[] _sin = new float[Dirtable.NDIR];

    public long NsAgents, NsDiffuse;

    public Sim(Config c)
    {
        if (c.Width <= 0 || (c.Width & (c.Width - 1)) != 0)
            throw new ArgumentException("width must be a power of two");
        if (c.Height <= 0 || (c.Height & (c.Height - 1)) != 0)
            throw new ArgumentException("height must be a power of two");
        Cfg = c;
        _log2w = System.Numerics.BitOperations.TrailingZeroCount((uint)c.Width);
        _xmask = c.Width - 1;
        _ymask = c.Height - 1;

        int cells = c.Width * c.Height;
        Grid = new float[cells];
        Scratch = new float[cells];
        Dep = c.Update == "deferred" ? new float[cells] : null;

        Ax = new float[c.Agents];
        Ay = new float[c.Agents];
        Adir = new ushort[c.Agents];
        Arng = new uint[c.Agents * 4];
        if (c.AgentTile > 0)
        {
            _aid = new int[c.Agents];
            _slot = new int[c.Agents];
            _agentIdx = new int[c.Agents];
            _sortKey = new int[c.Agents];
            _sortF32 = new float[c.Agents];
            _sortU32 = new uint[c.Agents * 4];
            _sortU16 = new ushort[c.Agents];
            for (int i = 0; i < c.Agents; i++) { _aid[i] = i; _slot[i] = i; }
        }

        for (int i = 0; i < Dirtable.NDIR; i++)
        {
            _cos[i] = BitConverter.UInt32BitsToSingle(Dirtable.CosBits[i]);
            _sin[i] = BitConverter.UInt32BitsToSingle(Dirtable.SinBits[i]);
        }
        Init();
    }

    public int Log2W => _log2w;
    public int XMask => _xmask;
    public int YMask => _ymask;

    // ---- PRNG (SPEC-1 section 3.1) ----------------------------------------

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint SplitMix32(ref uint state)
    {
        state += 0x9E3779B9u;
        uint z = state;
        z = (z ^ (z >> 16)) * 0x21F0AAADu;
        z = (z ^ (z >> 15)) * 0x735A2D97u;
        return z ^ (z >> 15);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint Rotl32(uint x, int k) => (x << k) | (x >> (32 - k));

    /// <summary>Advances the four words at arng[o..o+4) and returns one draw.</summary>
    private static uint Xoshiro128pp(uint[] s, int o)
    {
        uint result = Rotl32(s[o] + s[o + 3], 7) + s[o];
        uint t = s[o + 1] << 9;
        s[o + 2] ^= s[o];
        s[o + 3] ^= s[o + 1];
        s[o + 1] ^= s[o + 2];
        s[o] ^= s[o + 3];
        s[o + 2] ^= t;
        s[o + 3] = Rotl32(s[o + 3], 11);
        return result;
    }

    /// <summary>Exact: u&gt;&gt;8 is below 2^24 and 16777216 is a power of two.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static float Rnd01(uint u) => (u >> 8) / 16777216.0f;

    /// <summary>SPEC-1 section 2.2 -- not a modulo, one conditional shift.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static float Wrapf(float v, float m)
    {
        if (v < 0.0f) v += m;
        if (v >= m) v -= m;
        return v;
    }

    // ---- initialisation (SPEC-1 section 3.3) ------------------------------

    private void Init()
    {
        uint sm = Cfg.Seed ^ 0x5BF03635u;
        for (int i = 0; i < Grid.Length; i++)
            Grid[i] = Rnd01(SplitMix32(ref sm)) * 100.0f;

        float fw = Cfg.Width, fh = Cfg.Height;
        for (int i = 0; i < Cfg.Agents; i++)
        {
            uint sa = Cfg.Seed + 0x9E3779B9u * (uint)(i + 1);
            int o = i * 4;
            for (int k = 0; k < 4; k++) Arng[o + k] = SplitMix32(ref sa);
            if ((Arng[o] | Arng[o + 1] | Arng[o + 2] | Arng[o + 3]) == 0) Arng[o] = 1;
            Ax[i] = Rnd01(Xoshiro128pp(Arng, o)) * fw;
            Ay[i] = Rnd01(Xoshiro128pp(Arng, o)) * fh;
            Adir[i] = (ushort)(Xoshiro128pp(Arng, o) % Dirtable.NDIR);
        }
    }

    // ---- one tick (SPEC-1 section 5.2) ------------------------------------

    /// <summary>
    /// A counting sort of the agent arrays into 8x8 tiles of the grid, so that
    /// three sensor reads of neighbouring agents land in neighbouring cache
    /// lines. impl/c/sb_core.c carries the measurement behind the tile size.
    /// The arrays are readonly, so this copies back rather than swapping.
    /// </summary>
    private void AgentSort()
    {
        const int TileShift = 3;                // 8x8 cells
        int n = Cfg.Agents;
        int tw = (Cfg.Width + (1 << TileShift) - 1) >> TileShift;
        int th = (Cfg.Height + (1 << TileShift) - 1) >> TileShift;

        var count = new int[tw * th + 1];
        var key = _sortKey!;
        for (int j = 0; j < n; j++)
        {
            int x = (int)Ax[j] & _xmask;
            int y = (int)Ay[j] & _ymask;
            int k = (y >> TileShift) * tw + (x >> TileShift);
            key[j] = k;
            count[k + 1]++;
        }
        for (int t = 1; t < count.Length; t++) count[t] += count[t - 1];

        // Stable: walking the agents in their current order keeps a re-sort
        // cheap when almost nothing has moved.
        for (int j = 0; j < n; j++)
        {
            int dst = count[key[j]]++;
            _sortF32![dst] = Ax[j];
            _sortU16![dst] = Adir[j];
            Array.Copy(Arng, j * 4, _sortU32!, dst * 4, 4);
            key[j] = dst;                       // reused as the permutation
        }
        Array.Copy(_sortF32!, Ax, n);
        Array.Copy(_sortU16!, Adir, n);
        Array.Copy(_sortU32!, Arng, n * 4);
        for (int j = 0; j < n; j++) _sortF32![key[j]] = Ay[j];
        Array.Copy(_sortF32!, Ay, n);
        for (int j = 0; j < n; j++) _sortU32![key[j]] = (uint)_aid![j];
        for (int j = 0; j < n; j++) _aid![j] = (int)_sortU32![j];
        for (int j = 0; j < n; j++) _slot![_aid![j]] = j;
    }

    public void Tick()
    {
        // Re-sort inside the timed region, not beside it: the ordering is only
        // worth having if it pays for itself.
        if (Cfg.AgentTile > 0 && _ticksDone % Cfg.AgentTile == 0) AgentSort();
        _ticksDone++;

        long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
        if (_aid != null)
        {
            // With spatial ordering the step order is no longer the agent
            // order, so the deposits are buffered and applied afterwards in
            // ascending *agent* index -- the same order, and therefore the
            // same floats, as the direct loop.
            int n = Cfg.Agents;
            AgentPass(0, n, _agentIdx);
            float[] target = Dep ?? Grid;
            float d = Cfg.Deposit;
            for (int a = 0; a < n; a++)
            {
                int idx = _agentIdx![_slot![a]];
                target[idx] = target[idx] + d;
            }
        }
        else
        {
            AgentPass(0, Cfg.Agents, null);
        }
        long t1 = System.Diagnostics.Stopwatch.GetTimestamp();

        if (Dep != null) MergeRows(0, Cfg.Height);
        if (Cfg.Simd) Slimebench.Simd.DiffuseRows(this, 0, Cfg.Height, Cfg.SimdPortable);
        else DiffuseRows(0, Cfg.Height);
        SwapBuffers();

        long t2 = System.Diagnostics.Stopwatch.GetTimestamp();
        NsAgents += ToNs(t1 - t0);
        NsDiffuse += ToNs(t2 - t1);
    }

    public static long ToNs(long ticks) =>
        (long)(ticks * (1_000_000_000.0 / System.Diagnostics.Stopwatch.Frequency));

    public void SwapBuffers() => (Grid, Scratch) = (Scratch, Grid);

    /// <summary>Folds Dep into Grid over rows [y0,y1) and clears it.</summary>
    public void MergeRows(int y0, int y1)
    {
        if (Dep == null) return;
        int lo = y0 << _log2w, hi = y1 << _log2w;
        for (int i = lo; i < hi; i++)
        {
            Grid[i] += Dep[i];
            Dep[i] = 0.0f;
        }
    }

    /// <summary>
    /// SPEC-1 section 5.3 over agents [lo,hi).
    ///
    /// <para>The three sensor reads are written out rather than factored into a
    /// helper, because the order of the two <see cref="Wrapf"/> calls per read
    /// is normative and a helper hides it.</para>
    ///
    /// <para>With <paramref name="aidx"/> non-null the deposit is not applied;
    /// the target cell is recorded for a later phase to apply in a chosen
    /// order. That is the only thing the threaded caller does differently.</para>
    /// </summary>
    public void AgentPass(int lo, int hi, int[]? aidx)
    {
        float[] g = Grid;
        float[] target = Dep ?? Grid;
        float[] ax = Ax, ay = Ay, cs = _cos, sn = _sin;
        ushort[] adir = Adir;
        uint[] rng = Arng;
        int xmask = _xmask, ymask = _ymask, log2w = _log2w;
        float fw = Cfg.Width, fh = Cfg.Height;
        float sdist = Cfg.SensorDist, step = Cfg.Step, deposit = Cfg.Deposit;
        int ss = Cfg.SensorSteps, rs = Cfg.RotSteps, nd = Dirtable.NDIR;

        for (int i = lo; i < hi; i++)
        {
            int d = adir[i];
            float x = ax[i], y = ay[i];

            int dl = (d - ss + nd) % nd;
            int dr = (d + ss) % nd;

            float sx = Wrapf(x + cs[dl] * sdist, fw);
            float sy = Wrapf(y + sn[dl] * sdist, fh);
            float fl = g[(((int)sy & ymask) << log2w) | ((int)sx & xmask)];

            sx = Wrapf(x + cs[d] * sdist, fw);
            sy = Wrapf(y + sn[d] * sdist, fh);
            float fc = g[(((int)sy & ymask) << log2w) | ((int)sx & xmask)];

            sx = Wrapf(x + cs[dr] * sdist, fw);
            sy = Wrapf(y + sn[dr] * sdist, fh);
            float fr = g[(((int)sy & ymask) << log2w) | ((int)sx & xmask)];

            if (fc >= fl && fc >= fr)
            {
                // straight on
            }
            else if (fc < fl && fc < fr)
            {
                // Only the dead-end case draws from the stream (SPEC-1 5.3).
                d = (Xoshiro128pp(rng, i * 4) & 1) != 0
                    ? (d + rs) % nd
                    : (d - rs + nd) % nd;
            }
            else if (fl > fr) d = (d - rs + nd) % nd;
            else d = (d + rs) % nd;

            x = Wrapf(x + cs[d] * step, fw);
            y = Wrapf(y + sn[d] * step, fh);

            int idx = (((int)y & ymask) << log2w) | ((int)x & xmask);
            if (aidx == null) target[idx] += deposit;
            else aidx[i] = idx;

            adir[i] = (ushort)d;
            ax[i] = x;
            ay[i] = y;
        }
    }

    /// <summary>
    /// SPEC-1 section 5.4 over rows [y0,y1), writing into Scratch.
    ///
    /// <para>The summation order is normative -- do not reorder. No conversion
    /// is needed around <c>4.0f * src[...]</c>: the runtime must round the
    /// multiplication before the addition sees it, and a JIT may not turn the
    /// pair into an FMA. Output cells are independent, so splitting the row
    /// range across threads is unconditionally bit-identical.</para>
    /// </summary>
    public void DiffuseRows(int y0, int y1)
    {
        int w = Cfg.Width, log2w = _log2w, xmask = _xmask, ymask = _ymask;
        float decay = Cfg.Decay;
        float[] src = Grid, dst = Scratch;

        for (int y = y0; y < y1; y++)
        {
            int rowm = ((y - 1) & ymask) << log2w;
            int row0 = y << log2w;
            int rowp = ((y + 1) & ymask) << log2w;

            for (int x = 0; x < w; x++)
            {
                int xm = (x - 1) & xmask;
                int xp = (x + 1) & xmask;

                float acc = src[rowm | xm];
                acc += src[rowm | x];
                acc += src[rowm | xp];
                acc += src[row0 | xm];
                acc += 4.0f * src[row0 | x];
                acc += src[row0 | xp];
                acc += src[rowp | xm];
                acc += src[rowp | x];
                acc += src[rowp | xp];

                dst[row0 | x] = acc / 12.0f * decay;
            }
        }
    }

    // ---- checksums (SPEC-1 section 6) -------------------------------------
    //
    // SingleToUInt32Bits is the raw reinterpretation. The alternative,
    // SingleToInt32Bits on a NaN, is equally raw in .NET -- but naming the
    // unsigned one keeps the hash arithmetic unsigned throughout.

    public uint HashGrid()
    {
        uint h = FnvOffset;
        foreach (float v in Grid) h = (h ^ BitConverter.SingleToUInt32Bits(v)) * FnvPrime;
        return h;
    }

    public uint HashAgents()
    {
        uint h = FnvOffset;
        // In agent order, which is slot order only when the arrays have not
        // been spatially re-sorted. A checksum that changed with a performance
        // flag would defeat the point of having one.
        for (int a = 0; a < Cfg.Agents; a++)
        {
            int i = _slot == null ? a : _slot[a];
            h = (h ^ BitConverter.SingleToUInt32Bits(Ax[i])) * FnvPrime;
            h = (h ^ BitConverter.SingleToUInt32Bits(Ay[i])) * FnvPrime;
            h = (h ^ Adir[i]) * FnvPrime;
        }
        return h;
    }

    public static uint DirtableHashRuntime()
    {
        uint h = FnvOffset;
        foreach (uint b in Dirtable.CosBits) h = (h ^ b) * FnvPrime;
        foreach (uint b in Dirtable.SinBits) h = (h ^ b) * FnvPrime;
        return h;
    }
}
