/**
 * slimebench -- Java implementation of SPEC-1 (conformance tier A).
 *
 * <h2>Why this reaches tier A without a keyword</h2>
 *
 * Between Java 1.2 and Java 17, {@code float} arithmetic on x86 was allowed to
 * be evaluated in the x87 extended range unless a method or class was marked
 * {@code strictfp}. JEP 306 removed that permission: since Java 17 every
 * floating-point operation is strict IEEE 754, and {@code strictfp} is a no-op
 * kept for source compatibility. This port is therefore tier A by default on
 * 17 and later, and would need {@code strictfp} on 8 through 16.
 *
 * The other half is contraction. The JLS has always required each operator to
 * round its own result -- there is no equivalent of C's {@code -ffp-contract},
 * and a JIT may not fuse {@code a + b * c} into an FMA, because that would
 * produce a different value than the specification demands. {@link Math#fma}
 * exists precisely because fusing has to be asked for. So the stencil here is
 * written plainly, without the {@code float32(...)} conversions the Go port
 * needs for the same guarantee (see impl/go/sim/sim.go).
 *
 * <h2>Unsigned arithmetic without unsigned types</h2>
 *
 * Java has no unsigned 32-bit integer. It does not need one: {@code int}
 * arithmetic is defined to wrap modulo 2^32, which is exactly what the PRNG in
 * SPEC-1 section 3.1 requires. The only place signedness is visible is the
 * shift -- {@code >>>} instead of {@code >>} -- and the hash comparison, where
 * {@link Integer#toUnsignedString} formats what a C {@code uint32_t} would
 * print.
 *
 * <h2>What is deliberately not done</h2>
 *
 * No {@code Unsafe}, no {@code MemorySegment}, no bounds-check elision. The
 * arrays are plain {@code float[]}, which the JVM bounds-checks on every
 * access and which C2 hoists out of the diffusion loop when it can prove the
 * range. Measuring a version with the checks removed would measure how much
 * unsafe code one is willing to write; section 3 of docs/RESULTS.md already
 * prices bounds checks in Rust, Go and Swift.
 */
final class Sim {
    static final String SPEC_VERSION = "SPEC-1";

    private static final int FNV_OFFSET = 0x811C9DC5;
    private static final int FNV_PRIME = 0x01000193;

    // ---- configuration ----------------------------------------------------

    static final class Config {
        int width = 1024, height = 1024;
        int agents = 262144;
        int ticks = 1000, warmup = 0;
        int seed = 12345;
        int threads = 1;
        String update = "serial";
        String reduce = "binned";
        float sensorDist = 9.0f;
        float step = 1.0f;
        float deposit = 10.0f;
        float decay = 0.94f;
        int sensorSteps = 144;
        int rotSteps = 144;
        int hashEvery = 0;
        boolean simd = false;
        // Ticks between spatial re-sorts of the agent arrays; 0 = never.
        // See Sim.agentSort -- it changes which agent sits where, not
        // what any of them computes.
        int agentTile = 0;
        String preset = "custom";
    }

    final Config cfg;
    private final int log2w, xmask, ymask;

    float[] grid, scratch, dep;
    final float[] ax, ay;
    final short[] adir;   // 16-bit, as in every other port: NDIR is 1440
    final int[] arng;

    private final float[] cos = new float[Dirtable.NDIR];
    private final float[] sin = new float[Dirtable.NDIR];

    // Spatial ordering (Config.agentTile). aid[j] is the original index of the
    // agent now in slot j and slot[a] is its inverse; everything that has to
    // speak in agent indices rather than slots -- the deposit, the agent hash
    // -- goes through one of them. null when ordering is off.
    private int[] aid, slot, agentIdx, sortKey, sortU32;
    private float[] sortF32;
    private short[] sortU16;
    private int ticksDone;

    long nsAgents, nsDiffuse;

    Sim(Config c) {
        if (c.width <= 0 || (c.width & (c.width - 1)) != 0)
            throw new IllegalArgumentException("width must be a power of two");
        if (c.height <= 0 || (c.height & (c.height - 1)) != 0)
            throw new IllegalArgumentException("height must be a power of two");
        this.cfg = c;
        this.log2w = Integer.numberOfTrailingZeros(c.width);
        this.xmask = c.width - 1;
        this.ymask = c.height - 1;

        int cells = c.width * c.height;
        grid = new float[cells];
        scratch = new float[cells];
        dep = c.update.equals("deferred") ? new float[cells] : null;

        ax = new float[c.agents];
        ay = new float[c.agents];
        adir = new short[c.agents];
        arng = new int[c.agents * 4];
        if (c.agentTile > 0) {
            aid = new int[c.agents];
            slot = new int[c.agents];
            agentIdx = new int[c.agents];
            sortKey = new int[c.agents];
            sortF32 = new float[c.agents];
            sortU32 = new int[c.agents * 4];
            sortU16 = new short[c.agents];
            for (int i = 0; i < c.agents; i++) { aid[i] = i; slot[i] = i; }
        }

        for (int i = 0; i < Dirtable.NDIR; i++) {
            cos[i] = Float.intBitsToFloat(Dirtable.COS_BITS[i]);
            sin[i] = Float.intBitsToFloat(Dirtable.SIN_BITS[i]);
        }
        init();
    }

    // ---- PRNG (SPEC-1 section 3.1) ----------------------------------------
    //
    // splitmix32 needs to return two things -- the draw and the advanced state
    // -- and Java has no out-parameter. Packing both into a long is cheaper
    // than allocating a holder object per call, and this runs once per grid
    // cell at startup.

    private static long splitmix32(int state) {
        state += 0x9E3779B9;
        int z = state;
        z = (z ^ (z >>> 16)) * 0x21F0AAAD;
        z = (z ^ (z >>> 15)) * 0x735A2D97;
        int draw = z ^ (z >>> 15);
        return ((long) state << 32) | (draw & 0xFFFFFFFFL);
    }

    private static int smState(long packed) { return (int) (packed >>> 32); }
    private static int smDraw(long packed) { return (int) packed; }

    private static int rotl32(int x, int k) { return (x << k) | (x >>> (32 - k)); }

    /** Advances the four words at arng[o..o+4) and returns one draw. */
    private static int xoshiro128pp(int[] s, int o) {
        int result = rotl32(s[o] + s[o + 3], 7) + s[o];
        int t = s[o + 1] << 9;
        s[o + 2] ^= s[o];
        s[o + 3] ^= s[o + 1];
        s[o + 1] ^= s[o + 2];
        s[o] ^= s[o + 3];
        s[o + 2] ^= t;
        s[o + 3] = rotl32(s[o + 3], 11);
        return result;
    }

    /** Exact: u>>>8 is below 2^24 and 16777216 is a power of two (SPEC-1 3.2). */
    private static float rnd01(int u) { return (u >>> 8) / 16777216.0f; }

    /** SPEC-1 section 2.2 -- not a modulo, one conditional shift. */
    private static float wrapf(float v, float m) {
        if (v < 0.0f) v += m;
        if (v >= m) v -= m;
        return v;
    }

    // ---- initialisation (SPEC-1 section 3.3) ------------------------------

    private void init() {
        int sm = cfg.seed ^ 0x5BF03635;
        for (int i = 0; i < grid.length; i++) {
            long p = splitmix32(sm);
            sm = smState(p);
            grid[i] = rnd01(smDraw(p)) * 100.0f;
        }

        float fw = cfg.width, fh = cfg.height;
        for (int i = 0; i < cfg.agents; i++) {
            int sa = cfg.seed + 0x9E3779B9 * (i + 1);
            int o = i * 4;
            for (int k = 0; k < 4; k++) {
                long p = splitmix32(sa);
                sa = smState(p);
                arng[o + k] = smDraw(p);
            }
            if ((arng[o] | arng[o + 1] | arng[o + 2] | arng[o + 3]) == 0) arng[o] = 1;
            ax[i] = rnd01(xoshiro128pp(arng, o)) * fw;
            ay[i] = rnd01(xoshiro128pp(arng, o)) * fh;
            adir[i] = (short) (Integer.remainderUnsigned(xoshiro128pp(arng, o),
                                                        Dirtable.NDIR));
        }
    }

    // ---- one tick (SPEC-1 section 5.2) ------------------------------------

    /** A counting sort of the agent arrays into 8x8 tiles of the grid, so that
     * three sensor reads of neighbouring agents land in neighbouring cache
     * lines. impl/c/sb_core.c carries the measurement behind the tile size;
     * this is the same algorithm, and what it is worth on a JIT rather than
     * an ahead-of-time compiler is the question this row answers.
     *
     * The arrays are final, so this copies back rather than swapping. */
    private void agentSort() {
        final int TILE_SHIFT = 3;               // 8x8 cells
        final int n = cfg.agents;
        final int tw = (cfg.width + (1 << TILE_SHIFT) - 1) >>> TILE_SHIFT;
        final int th = (cfg.height + (1 << TILE_SHIFT) - 1) >>> TILE_SHIFT;

        final int[] count = new int[tw * th + 1];
        for (int j = 0; j < n; j++) {
            int x = (int) ax[j] & xmask;
            int y = (int) ay[j] & ymask;
            int k = (y >>> TILE_SHIFT) * tw + (x >>> TILE_SHIFT);
            sortKey[j] = k;
            count[k + 1]++;
        }
        for (int t = 1; t < count.length; t++) count[t] += count[t - 1];

        // Stable: walking the agents in their current order keeps a re-sort
        // cheap when almost nothing has moved.
        for (int j = 0; j < n; j++) {
            int dst = count[sortKey[j]]++;
            sortF32[dst] = ax[j];
            sortU16[dst] = adir[j];
            System.arraycopy(arng, j * 4, sortU32, dst * 4, 4);
            sortKey[j] = dst;                   // reused as the permutation
        }
        System.arraycopy(sortF32, 0, ax, 0, n);
        System.arraycopy(sortU16, 0, adir, 0, n);
        System.arraycopy(sortU32, 0, arng, 0, n * 4);
        for (int j = 0; j < n; j++) sortF32[sortKey[j]] = ay[j];
        System.arraycopy(sortF32, 0, ay, 0, n);
        for (int j = 0; j < n; j++) sortU32[sortKey[j]] = aid[j];
        System.arraycopy(sortU32, 0, aid, 0, n);
        for (int j = 0; j < n; j++) slot[aid[j]] = j;
    }

    void tick() {
        // Re-sort inside the timed region, not beside it: the ordering is only
        // worth having if it pays for itself.
        if (cfg.agentTile > 0 && ticksDone % cfg.agentTile == 0) agentSort();
        ticksDone++;

        long t0 = System.nanoTime();
        if (aid != null) {
            // With spatial ordering the step order is no longer the agent
            // order, so the deposits are buffered and applied afterwards in
            // ascending *agent* index -- the same order, and therefore the
            // same floats, as the direct loop.
            final int n = cfg.agents;
            agentPass(0, n, agentIdx);
            final float[] target = (dep != null) ? dep : grid;
            final float d = cfg.deposit;
            for (int a = 0; a < n; a++) {
                int idx = agentIdx[slot[a]];
                target[idx] = target[idx] + d;
            }
        } else {
            agentPass(0, cfg.agents);
        }
        long t1 = System.nanoTime();

        if (dep != null) mergeRows(0, cfg.height);
        if (cfg.simd) Simd.diffuseRows(this, 0, cfg.height);
        else diffuseRows(0, cfg.height);
        swapBuffers();

        nsAgents += t1 - t0;
        nsDiffuse += System.nanoTime() - t1;
    }

    void swapBuffers() {
        float[] t = grid;
        grid = scratch;
        scratch = t;
    }

    /** Folds dep into grid over rows [y0,y1) and clears it. */
    void mergeRows(int y0, int y1) {
        if (dep == null) return;
        int lo = y0 << log2w, hi = y1 << log2w;
        for (int i = lo; i < hi; i++) {
            grid[i] = grid[i] + dep[i];
            dep[i] = 0.0f;
        }
    }

    /**
     * SPEC-1 section 5.3 over agents [lo,hi).
     *
     * The three sensor reads are written out rather than factored into a
     * helper, because the order of the two {@link #wrapf} calls per read is
     * normative and a helper hides it. That is the same decision impl/go
     * documents and then makes the other way.
     *
     * <p>With {@code aidx} non-null the deposit is not applied; the target
     * cell is recorded for a later phase to apply in a chosen order. That is
     * the only thing the threaded caller does differently, and everything
     * above it has to stay identical or the parallel run stops being the same
     * simulation.
     */
    void agentPass(int lo, int hi) { agentPass(lo, hi, null); }

    void agentPass(int lo, int hi, int[] aidx) {
        final float[] g = grid;
        final float[] target = (dep != null) ? dep : grid;
        final float[] ax = this.ax, ay = this.ay;
        final short[] adir = this.adir;
        final int[] rng = this.arng;
        final float[] cs = cos, sn = sin;
        final int xmask = this.xmask, ymask = this.ymask, log2w = this.log2w;
        final float fw = cfg.width, fh = cfg.height;
        final float sdist = cfg.sensorDist, step = cfg.step, deposit = cfg.deposit;
        final int ss = cfg.sensorSteps, rs = cfg.rotSteps;
        final int nd = Dirtable.NDIR;

        for (int i = lo; i < hi; i++) {
            int d = adir[i] & 0xFFFF;
            float x = ax[i], y = ay[i];

            int dl = (d - ss + nd) % nd;
            int dr = (d + ss) % nd;

            float sx = wrapf(x + cs[dl] * sdist, fw);
            float sy = wrapf(y + sn[dl] * sdist, fh);
            float fl = g[(((int) sy & ymask) << log2w) | ((int) sx & xmask)];

            sx = wrapf(x + cs[d] * sdist, fw);
            sy = wrapf(y + sn[d] * sdist, fh);
            float fc = g[(((int) sy & ymask) << log2w) | ((int) sx & xmask)];

            sx = wrapf(x + cs[dr] * sdist, fw);
            sy = wrapf(y + sn[dr] * sdist, fh);
            float fr = g[(((int) sy & ymask) << log2w) | ((int) sx & xmask)];

            if (fc >= fl && fc >= fr) {
                // straight on
            } else if (fc < fl && fc < fr) {
                // Only the dead-end case draws from the stream (SPEC-1 5.3).
                if ((xoshiro128pp(rng, i * 4) & 1) != 0) d = (d + rs) % nd;
                else d = (d - rs + nd) % nd;
            } else if (fl > fr) {
                d = (d - rs + nd) % nd;
            } else {
                d = (d + rs) % nd;
            }

            x = wrapf(x + cs[d] * step, fw);
            y = wrapf(y + sn[d] * step, fh);

            int idx = (((int) y & ymask) << log2w) | ((int) x & xmask);
            if (aidx == null) target[idx] = target[idx] + deposit;
            else aidx[i] = idx;

            adir[i] = (short) d;
            ax[i] = x;
            ay[i] = y;
        }
    }

    /**
     * SPEC-1 section 5.4 over rows [y0,y1), writing into scratch.
     *
     * The summation order is normative -- do not reorder. No conversion is
     * needed around {@code 4.0f * src[...]}: JLS 15.17.1 requires the
     * multiplication to round before the addition sees it, so a JIT cannot
     * turn the pair into an FMA. Output cells are independent, so splitting
     * the row range across threads is unconditionally bit-identical.
     */
    void diffuseRows(int y0, int y1) {
        final int w = cfg.width;
        final int log2w = this.log2w, xmask = this.xmask, ymask = this.ymask;
        final float decay = cfg.decay;
        final float[] src = grid, dst = scratch;

        for (int y = y0; y < y1; y++) {
            int rowm = ((y - 1) & ymask) << log2w;
            int row0 = y << log2w;
            int rowp = ((y + 1) & ymask) << log2w;

            for (int x = 0; x < w; x++) {
                int xm = (x - 1) & xmask;
                int xp = (x + 1) & xmask;

                float acc = src[rowm | xm];
                acc = acc + src[rowm | x];
                acc = acc + src[rowm | xp];
                acc = acc + src[row0 | xm];
                acc = acc + 4.0f * src[row0 | x];
                acc = acc + src[row0 | xp];
                acc = acc + src[rowp | xm];
                acc = acc + src[rowp | x];
                acc = acc + src[rowp | xp];

                dst[row0 | x] = acc / 12.0f * decay;
            }
        }
    }

    // ---- checksums (SPEC-1 section 6) -------------------------------------
    //
    // floatToRawIntBits, not floatToIntBits: the latter collapses every NaN to
    // one canonical pattern, which would hide exactly the kind of divergence
    // the checksum exists to find.

    int hashGrid() {
        int h = FNV_OFFSET;
        for (float v : grid) h = (h ^ Float.floatToRawIntBits(v)) * FNV_PRIME;
        return h;
    }

    int hashAgents() {
        int h = FNV_OFFSET;
        // In agent order, which is slot order only when the arrays have not
        // been spatially re-sorted. A checksum that changed with a performance
        // flag would defeat the point of having one.
        for (int a = 0; a < cfg.agents; a++) {
            final int i = (slot == null) ? a : slot[a];
            h = (h ^ Float.floatToRawIntBits(ax[i])) * FNV_PRIME;
            h = (h ^ Float.floatToRawIntBits(ay[i])) * FNV_PRIME;
            h = (h ^ (adir[i] & 0xFFFF)) * FNV_PRIME;
        }
        return h;
    }

    static int dirtableHashRuntime() {
        int h = FNV_OFFSET;
        for (int b : Dirtable.COS_BITS) h = (h ^ b) * FNV_PRIME;
        for (int b : Dirtable.SIN_BITS) h = (h ^ b) * FNV_PRIME;
        return h;
    }
}
