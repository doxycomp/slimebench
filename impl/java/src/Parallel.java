import java.util.Locale;
import java.util.concurrent.BrokenBarrierException;
import java.util.concurrent.CyclicBarrier;

/**
 * Class P for the Java target (SPEC-1 section 5.6).
 *
 * <p>The structure is the C reference's, phase for phase, because the point of
 * class P is to compare the same decomposition across languages. What is
 * deliberately Java is the barrier: {@link CyclicBarrier} from
 * java.util.concurrent, not a hand-rolled sense-reversing one. Section 5 of
 * docs/RESULTS.md shows the barrier is where the languages actually differ at
 * high thread counts -- C uses futex, Go parks goroutines in its own
 * scheduler -- so substituting a custom barrier here would replace the thing
 * being measured with a copy of someone else's answer.
 *
 * <p>Platform threads, not virtual ones. Virtual threads are for blocking I/O;
 * a barrier-synchronised CPU-bound loop is exactly the workload they are not
 * for, and pinning N virtual threads to N carriers would measure the scheduler
 * twice.
 *
 * <h2>binned</h2>
 *
 * Bit-identical to the serial run at every thread count. Agents are bucketed
 * by the row block their deposit lands in, counting-sorted so that each block's
 * deposits are applied in ascending agent index, and each worker then owns one
 * block outright. The order deposits hit a cell is therefore the serial order,
 * whatever the partition.
 *
 * <h2>private</h2>
 *
 * Per-thread deposit buffers, merged in a fixed worker order. Reproducible for
 * a given thread count and not in general equal to the serial chain -- the
 * grouping of the f32 additions differs. That is a documented tier, not a bug.
 */
final class Parallel {

    static final class Result {
        double msTotal;
        double[] tickMs;
    }

    private final Sim s;
    private final int t, cells, agents, height, log2w;
    private final float deposit;
    private final boolean binned;
    private final CyclicBarrier bar;

    private final int[] aidx, sorted, counts, offsets, ybucket;
    private final float[] priv;

    private Parallel(Sim s, int t) {
        this.s = s;
        this.t = t;
        this.cells = s.cfg.width * s.cfg.height;
        this.agents = s.cfg.agents;
        this.height = s.cfg.height;
        this.log2w = Integer.numberOfTrailingZeros(s.cfg.width);
        this.deposit = s.cfg.deposit;
        this.binned = s.cfg.reduce.equals("binned");
        this.bar = new CyclicBarrier(t);

        this.aidx = new int[agents];
        if (binned) {
            this.sorted = new int[agents];
            this.counts = new int[t * t];
            this.offsets = new int[t * t];
            this.ybucket = new int[height];
            this.priv = null;
            for (int y = 0; y < height; y++) {
                // Fixed, even row blocks. The adaptive variant the C reference
                // carries bought 5.9 % and is not the shipping config -- see
                // section 11 of docs/RESULTS.md.
                int b = 0;
                while (b < t - 1 && y >= hi(height, t, b)) b++;
                ybucket[y] = b;
            }
        } else {
            this.sorted = null;
            this.counts = null;
            this.offsets = null;
            this.ybucket = null;
            this.priv = new float[t * cells];
        }
    }

    /** Contiguous split of [0,n) into `parts`; identical to the C reference's. */
    private static int lo(int n, int parts, int i) {
        int base = n / parts, rem = n % parts;
        return i * base + Math.min(i, rem);
    }

    private static int hi(int n, int parts, int i) {
        return lo(n, parts, i) + n / parts + (i < n % parts ? 1 : 0);
    }

    private int bucketOf(int idx) { return ybucket[idx >>> log2w]; }

    private void await() {
        try {
            bar.await();
        } catch (InterruptedException | BrokenBarrierException e) {
            throw new IllegalStateException("barrier broken", e);
        }
    }

    // ---- private ----------------------------------------------------------

    private void agentsPrivate(int tid) {
        int a = lo(agents, t, tid), b = hi(agents, t, tid);
        s.agentPass(a, b, aidx);
        int base = tid * cells;
        for (int i = a; i < b; i++) priv[base + aidx[i]] += deposit;
    }

    private void mergePrivate(int tid) {
        int a = lo(cells, t, tid), b = hi(cells, t, tid);
        float[] g = s.grid;
        for (int i = a; i < b; i++) {
            float acc = priv[i];
            priv[i] = 0.0f;
            for (int k = 1; k < t; k++) {
                acc += priv[k * cells + i];
                priv[k * cells + i] = 0.0f;
            }
            g[i] = g[i] + acc;
        }
    }

    // ---- binned -----------------------------------------------------------

    private void agentsBinned(int tid) {
        int a = lo(agents, t, tid), b = hi(agents, t, tid);
        int cbase = tid * t;
        for (int i = 0; i < t; i++) counts[cbase + i] = 0;
        s.agentPass(a, b, aidx);
        for (int i = a; i < b; i++) counts[cbase + bucketOf(aidx[i])]++;
    }

    private void prefixBinned() {
        int running = 0;
        for (int b = 0; b < t; b++) {
            for (int w = 0; w < t; w++) {
                offsets[w * t + b] = running;
                running += counts[w * t + b];
            }
        }
    }

    private void scatterBinned(int tid) {
        int a = lo(agents, t, tid), b = hi(agents, t, tid);
        int obase = tid * t;
        for (int i = a; i < b; i++) {
            int bkt = bucketOf(aidx[i]);
            sorted[offsets[obase + bkt]++] = i;
        }
    }

    /**
     * Applies exactly the deposits landing in this worker's row block, in
     * ascending agent index. Cells in other blocks are never touched, so no
     * two workers write the same cell and no atomics are needed.
     */
    private void depositBinned(int tid) {
        int begin = 0;
        for (int b = 0; b < tid; b++)
            for (int w = 0; w < t; w++) begin += counts[w * t + b];
        int end = begin;
        for (int w = 0; w < t; w++) end += counts[w * t + tid];

        float[] d = s.dep;
        for (int j = begin; j < end; j++) {
            int idx = aidx[sorted[j]];
            d[idx] = d[idx] + deposit;
        }
    }

    // ---- the tick ---------------------------------------------------------

    private void runTick(int tid) {
        if (binned) {
            agentsBinned(tid);
            await();
            if (tid == 0) prefixBinned();
            await();
            scatterBinned(tid);
            await();
            depositBinned(tid);
            await();
            s.mergeRows(lo(height, t, tid), hi(height, t, tid));
            await();
        } else {
            agentsPrivate(tid);
            await();
            mergePrivate(tid);
            await();
        }

        s.diffuseRows(lo(height, t, tid), hi(height, t, tid));
        await();

        // Two array references are shared, so exactly one worker swaps them,
        // between two barriers -- everyone else is parked.
        if (tid == 0) s.swapBuffers();
        await();
    }

    static Result run(Sim s, int warmup, int ticks, boolean logTicks) {
        if (s.dep == null)
            throw new IllegalArgumentException(
                "--threads > 1 requires --update deferred (SPEC-1 5.5)");

        int t = s.cfg.threads;
        Parallel p = new Parallel(s, t);
        Result r = new Result();
        r.tickMs = new double[ticks];

        // Worker 0 runs on this thread and drives the loop; the other t-1 are
        // started once and stay for the whole run, so the measurement never
        // includes thread creation.
        final int total = warmup + ticks;
        Thread[] workers = new Thread[t - 1];
        for (int k = 1; k < t; k++) {
            final int tid = k;
            workers[k - 1] = new Thread(() -> {
                for (int i = 0; i < total; i++) p.runTick(tid);
            }, "slimebench-" + tid);
            workers[k - 1].start();
        }

        for (int i = 0; i < warmup; i++) p.runTick(0);
        s.nsAgents = 0;
        s.nsDiffuse = 0;

        long start = System.nanoTime();
        for (int i = 0; i < ticks; i++) {
            long a = System.nanoTime();
            p.runTick(0);
            r.tickMs[i] = (System.nanoTime() - a) / 1e6;
            if (logTicks) System.err.printf(Locale.ROOT, "tick_ms %d %.6f%n", i, r.tickMs[i]);
        }
        r.msTotal = (System.nanoTime() - start) / 1e6;

        for (Thread w : workers) {
            try {
                w.join();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        return r;
    }
}
