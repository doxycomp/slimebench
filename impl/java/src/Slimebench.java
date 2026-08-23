import java.util.Arrays;
import java.util.Locale;

/**
 * slimebench -- Java headless benchmark (class S).
 *
 * <p>Java brings one thing to this benchmark that no other target has: the
 * measurement depends on how long you have been measuring. Every other
 * implementation here is at full speed on tick 1. A JVM starts in the
 * interpreter, promotes to C1 after a few thousand invocations, and to C2
 * after a few tens of thousands, so the first ticks are a different program
 * from the later ones.
 *
 * <p>Two things follow. {@code --warmup} is not optional for this target the
 * way it is for the others, and the shape of the ramp is itself a result --
 * set {@code SLIMEBENCH_TICK_MS=1} to get every tick's duration on stderr,
 * which is what bench/jvm-warmup.sh plots.
 */
public final class Slimebench {

    private static final String USAGE = """
        usage: slimebench [options]   (slimebench SPEC-1)
          --preset NAME        tiny|small|medium|large|huge|browser
          --width N --height N powers of two
          --agents N  --ticks N  --warmup N  --seed N
          --update MODE        serial|deferred
          --threads N
          --deposit-reduce M   private|binned  (SPEC-1 5.6)
          --sensor-dist F  --sensor-steps N  --rot-steps N
          --step F  --deposit F  --decay F
          --simd               vectorised diffusion (SPEC-1 8.1)
          --headless  --json  --hash-every N
          -h, --help
        env:
          SLIMEBENCH_TICK_MS=1   per-tick milliseconds on stderr (JIT warm-up)""";

    private static void fail(String msg) {
        System.err.println("error: " + msg);
        System.err.println(USAGE);
        System.exit(2);
    }

    private static boolean applyPreset(Sim.Config c, String name) {
        switch (name) {
            case "tiny":    c.width = 512;  c.height = 512;  c.agents = 65536;    c.ticks = 1000; break;
            case "small":   c.width = 1024; c.height = 1024; c.agents = 262144;   c.ticks = 1000; break;
            case "medium":  c.width = 2048; c.height = 2048; c.agents = 1048576;  c.ticks = 1000; break;
            case "large":   c.width = 4096; c.height = 4096; c.agents = 4194304;  c.ticks = 500;  break;
            case "huge":    c.width = 8192; c.height = 8192; c.agents = 16777216; c.ticks = 100;  break;
            case "browser": c.width = 1024; c.height = 1024; c.agents = 262144;   c.ticks = 0;    break;
            default: return false;
        }
        c.preset = name;
        return true;
    }

    public static void main(String[] argv) {
        Sim.Config c = new Sim.Config();
        boolean wantJson = false;

        for (int i = 0; i < argv.length; i++) {
            String a = argv[i];
            String v = null;
            // Every option below except the flags takes exactly one value.
            switch (a) {
                case "-h", "--help" -> { System.out.println(USAGE); return; }
                case "--json" -> { wantJson = true; continue; }
                case "--headless" -> { continue; }
                case "--no-simd" -> { c.simd = false; continue; }
                case "--simd" -> { c.simd = true; continue; }
                // Spatial ordering of the agent arrays; the argument is
                // how many ticks between re-sorts. 0 keeps creation order.
                case "--agent-tile" -> {
                    if (i + 1 >= argv.length) fail(a + " requires a value");
                    c.agentTile = Integer.parseInt(argv[++i]);
                    continue;
                }
                default -> {
                    if (a.startsWith("--")) {
                        if (i + 1 >= argv.length) fail(a + " requires a value");
                        v = argv[++i];
                    }
                }
            }
            try {
                switch (a) {
                    case "--preset" -> { if (!applyPreset(c, v)) fail("unknown preset '" + v + "'"); }
                    case "--width"  -> { c.width  = Integer.parseInt(v); c.preset = "custom"; }
                    case "--height" -> { c.height = Integer.parseInt(v); c.preset = "custom"; }
                    case "--agents" -> { c.agents = Integer.parseInt(v); c.preset = "custom"; }
                    case "--ticks"  -> c.ticks = Integer.parseInt(v);
                    case "--warmup" -> c.warmup = Integer.parseInt(v);
                    case "--seed"   -> c.seed = Integer.parseInt(v);
                    case "--threads" -> c.threads = Integer.parseInt(v);
                    case "--hash-every" -> c.hashEvery = Integer.parseInt(v);
                    case "--sensor-steps" -> c.sensorSteps = Integer.parseInt(v);
                    case "--rot-steps" -> c.rotSteps = Integer.parseInt(v);
                    case "--sensor-dist" -> c.sensorDist = Float.parseFloat(v);
                    case "--step" -> c.step = Float.parseFloat(v);
                    case "--deposit" -> c.deposit = Float.parseFloat(v);
                    case "--decay" -> c.decay = Float.parseFloat(v);
                    // Accepted for CLI compatibility, unused by a headless target.
                    case "--display-max", "--dump-grid" -> { }
                    case "--update" -> {
                        if (!v.equals("serial") && !v.equals("deferred"))
                            fail("--update must be serial|deferred");
                        c.update = v;
                    }
                    case "--deposit-reduce" -> {
                        if (!v.equals("private") && !v.equals("binned"))
                            fail("--deposit-reduce must be private|binned");
                        c.reduce = v;
                    }
                    // SPEC-1 section 10: never silently ignore an unknown flag.
                    default -> fail("unknown argument '" + a + "'");
                }
            } catch (NumberFormatException e) {
                fail("'" + v + "' is not a number");
            }
        }

        Sim s;
        try {
            s = new Sim(c);
        } catch (IllegalArgumentException e) {
            System.err.println("error: " + e.getMessage());
            System.exit(2);
            return;
        }

        boolean logTicks = "1".equals(System.getenv("SLIMEBENCH_TICK_MS"));
        String cls = "S";
        // The variant names the width the runtime chose, as impl/c names the
        // instruction set.
        String variant = c.simd ? Simd.name() : "scalar";
        if (c.simd && !Simd.available()) {
            System.err.println("error: --simd requested but no vector unit is available");
            System.exit(2);
        }
        double msTotal;
        double[] tickMs;

        if (c.threads > 1) {
            cls = "P";
            variant = c.reduce;
            Parallel.Result r = Parallel.run(s, c.warmup, c.ticks, logTicks);
            msTotal = r.msTotal;
            tickMs = r.tickMs;
        } else {
            for (int i = 0; i < c.warmup; i++) s.tick();
            s.nsAgents = 0;
            s.nsDiffuse = 0;

            tickMs = new double[c.ticks];
            long start = System.nanoTime();
            for (int t = 0; t < c.ticks; t++) {
                long a = System.nanoTime();
                s.tick();
                tickMs[t] = (System.nanoTime() - a) / 1e6;
                if (logTicks) System.err.printf(Locale.ROOT, "tick_ms %d %.6f%n", t, tickMs[t]);
                if (c.hashEvery != 0 && (t + 1) % c.hashEvery == 0)
                    System.err.printf("tick %d grid=0x%08X agents=0x%08X%n",
                                      t + 1, s.hashGrid(), s.hashAgents());
            }
            msTotal = (System.nanoTime() - start) / 1e6;
        }

        gcStats(c.ticks);

        if (wantJson) System.out.println(resultJson(s, cls, variant, msTotal, tickMs));
        else printHuman(s, variant, msTotal);
    }

    /**
     * What the collector did, under SLIMEBENCH_GC_STATS=1.
     *
     * <p>The interesting answer here is "nothing". The simulation allocates
     * its arrays once and then writes into them for the rest of the run, so a
     * garbage-collected runtime is running with an idle collector — which is
     * worth stating, because it means this benchmark does not measure the one
     * thing that most distinguishes these runtimes from C.</p>
     */
    private static void gcStats(int ticks) {
        if (!"1".equals(System.getenv("SLIMEBENCH_GC_STATS"))) return;
        long count = 0, millis = 0;
        for (var b : java.lang.management.ManagementFactory.getGarbageCollectorMXBeans()) {
            if (b.getCollectionCount() > 0) count += b.getCollectionCount();
            if (b.getCollectionTime() > 0) millis += b.getCollectionTime();
        }
        Runtime rt = Runtime.getRuntime();
        System.err.printf(Locale.ROOT,
            "gc_stats collections=%d gc_ms=%d heap_used_mib=%.1f ticks=%d%n",
            count, millis, (rt.totalMemory() - rt.freeMemory()) / 1048576.0, ticks);
    }

    private static void printHuman(Sim s, String variant, double msTotal) {
        Sim.Config c = s.cfg;
        System.out.printf(Locale.ROOT, "%s %dx%d agents=%d ticks=%d update=%s",
                          c.preset, c.width, c.height, c.agents, c.ticks, c.update);
        if (c.threads > 1) System.out.printf(Locale.ROOT, " threads=%d reduce=%s", c.threads, c.reduce);
        System.out.println();
        System.out.printf("  grid_hash  0x%08X%n", s.hashGrid());
        System.out.printf("  agent_hash 0x%08X%n", s.hashAgents());
        System.out.printf(Locale.ROOT, "  total      %.2f ms  (%.4f ms/tick)%n",
                          msTotal, c.ticks > 0 ? msTotal / c.ticks : 0.0);
        System.out.printf(Locale.ROOT, "  agents     %.2f ms%n", s.nsAgents / 1e6);
        System.out.printf(Locale.ROOT, "  diffuse    %.2f ms%n", s.nsDiffuse / 1e6);
    }

    private static String resultJson(Sim s, String cls, String variant,
                                     double msTotal, double[] tickMs) {
        int n = tickMs.length;
        double[] sorted = tickMs.clone();
        Arrays.sort(sorted);
        double median = 0, p99 = 0, mean = 0;
        if (n > 0) {
            median = sorted[n / 2];
            p99 = sorted[Math.min(n - 1, (int) (n * 0.99))];
            for (double v : tickMs) mean += v;
            mean /= n;
        }
        Sim.Config c = s.cfg;
        double cells = (double) c.width * c.height;
        double maups = msTotal > 0 ? (double) c.agents * n / msTotal / 1000.0 : 0.0;
        double mcups = msTotal > 0 ? cells * n / msTotal / 1000.0 : 0.0;

        return String.format(Locale.ROOT,
            "{\"schema\":1,\"impl\":\"java\",\"backend\":\"headless\",\"class\":\"%s\","
            + "\"preset\":\"%s\",\"variant\":\"%s\",\"width\":%d,\"height\":%d,"
            + "\"agents\":%d,\"ticks\":%d,\"seed\":%d,\"update\":\"%s\",\"threads\":%d,"
            + "\"grid_hash\":\"0x%08X\",\"agent_hash\":\"0x%08X\",\"dirtable_hash\":\"0x%08X\","
            + "\"ms_total\":%.4f,\"ms_agents\":%.4f,\"ms_diffuse\":%.4f,"
            + "\"ms_per_tick_mean\":%.6f,\"ms_per_tick_median\":%.6f,\"ms_per_tick_p99\":%.6f,"
            + "\"maups\":%.4f,\"mcups\":%.4f}",
            cls, c.preset, variant, c.width, c.height, c.agents, n, c.seed,
            c.update, c.threads,
            s.hashGrid(), s.hashAgents(), Sim.dirtableHashRuntime(),
            msTotal, s.nsAgents / 1e6, s.nsDiffuse / 1e6,
            mean, median, p99, maups, mcups);
    }

    private Slimebench() {}
}
