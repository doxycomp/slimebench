import jdk.incubator.vector.FloatVector;
import jdk.incubator.vector.VectorSpecies;

/**
 * The diffusion stencil through the JDK Vector API (class V).
 *
 * <p><b>The question.</b> Class V has been languages reaching the vector unit
 * through intrinsics named for one instruction set. The JDK's Vector API is
 * the other approach and the most cautious version of it: the source names no
 * instruction set and no width, {@link VectorSpecies} is resolved at run time,
 * and the JIT is expected to turn it into machine code. Whether that reaches
 * hand-written AVX-512 was not measured here before.
 *
 * <p><b>Still incubating.</b> `jdk.incubator.vector` has been an incubator
 * module since Java 16 and still is in 21, so both javac and java need
 * {@code --add-modules jdk.incubator.vector} and the runtime prints a warning
 * to stderr. build.sh supplies the flag; the warning is harmless because the
 * benchmark's JSON goes to stdout.
 *
 * <p><b>Why it stays conformance tier A.</b> SPEC-1 §8.1: the stencil does no
 * cross-lane work. Nine loads, eight adds, one multiply, one divide, all
 * elementwise, one output cell per lane — each lane performs exactly the
 * scalar computation for its own cell, in the same order. Vectorising could
 * only change the result if lanes interacted, and none do.
 *
 * <p>The two wrapping columns stay scalar: they are the only cells whose
 * neighbours are not contiguous in memory.
 */
final class Simd {

    /**
     * The widest species the runtime will use. Unlike .NET's portable
     * {@code Vector<T>}, which caps at 256 bits on this hardware,
     * SPECIES_PREFERRED does take AVX-512 when the CPU has it.
     */
    static final VectorSpecies<Float> SPECIES = FloatVector.SPECIES_PREFERRED;

    static boolean available() { return SPECIES.length() > 1; }

    static String name() {
        return available() ? "vector" + SPECIES.vectorBitSize() : "scalar";
    }

    /**
     * SPEC-1 §5.4 over rows [y0,y1). The summation order is normative and
     * identical to {@link Sim#diffuseRows}.
     */
    static void diffuseRows(Sim s, int y0, int y1) {
        if (!available()) { s.diffuseRows(y0, y1); return; }

        final int w = s.cfg.width;
        final int log2w = Integer.numberOfTrailingZeros(w);
        final int xmask = w - 1;
        final int ymask = s.cfg.height - 1;
        final float decay = s.cfg.decay;
        final float[] src = s.grid, dst = s.scratch;
        final int vw = SPECIES.length();

        final FloatVector vfour = FloatVector.broadcast(SPECIES, 4.0f);
        final FloatVector vtwelve = FloatVector.broadcast(SPECIES, 12.0f);
        final FloatVector vdecay = FloatVector.broadcast(SPECIES, decay);

        for (int y = y0; y < y1; y++) {
            final int rowm = ((y - 1) & ymask) << log2w;
            final int row0 = y << log2w;
            final int rowp = ((y + 1) & ymask) << log2w;

            cell(src, dst, 0, rowm, row0, rowp, xmask, decay);

            int x = 1;
            for (; x + vw <= w - 1; x += vw) {
                FloatVector acc = FloatVector.fromArray(SPECIES, src, rowm + x - 1);
                acc = acc.add(FloatVector.fromArray(SPECIES, src, rowm + x));
                acc = acc.add(FloatVector.fromArray(SPECIES, src, rowm + x + 1));
                acc = acc.add(FloatVector.fromArray(SPECIES, src, row0 + x - 1));
                acc = acc.add(vfour.mul(FloatVector.fromArray(SPECIES, src, row0 + x)));
                acc = acc.add(FloatVector.fromArray(SPECIES, src, row0 + x + 1));
                acc = acc.add(FloatVector.fromArray(SPECIES, src, rowp + x - 1));
                acc = acc.add(FloatVector.fromArray(SPECIES, src, rowp + x));
                acc = acc.add(FloatVector.fromArray(SPECIES, src, rowp + x + 1));
                acc.div(vtwelve).mul(vdecay).intoArray(dst, row0 + x);
            }

            for (; x < w; x++)
                cell(src, dst, x, rowm, row0, rowp, xmask, decay);
        }
    }

    /** One output cell, scalar; used for the two wrapping columns. */
    private static void cell(float[] src, float[] dst, int x,
                             int rowm, int row0, int rowp, int xmask, float decay) {
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

    private Simd() {}
}
