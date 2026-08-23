using System.Globalization;

namespace Slimebench;

/// <summary>
/// slimebench -- C# headless benchmark (classes S and P).
///
/// <para>Set <c>SLIMEBENCH_TICK_MS=1</c> for per-tick milliseconds on stderr.
/// The JIT profiles need it for the same reason the Java target does; the
/// Native AOT profile is the control that should show a flat line.</para>
/// </summary>
internal static class Program
{
    private const string Usage = """
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
          --simd-portable      force Vector<T> where Vector512 exists
          --headless  --json  --hash-every N  --dump-grid PATH
          -h, --help
        env:
          SLIMEBENCH_TICK_MS=1   per-tick milliseconds on stderr
        """;

    private static void Fail(string msg)
    {
        Console.Error.WriteLine("error: " + msg);
        Console.Error.WriteLine(Usage);
        Environment.Exit(2);
    }

    private static bool ApplyPreset(Sim.Config c, string name)
    {
        switch (name)
        {
            case "tiny":    c.Width = 512;  c.Height = 512;  c.Agents = 65536;    c.Ticks = 1000; break;
            case "small":   c.Width = 1024; c.Height = 1024; c.Agents = 262144;   c.Ticks = 1000; break;
            case "medium":  c.Width = 2048; c.Height = 2048; c.Agents = 1048576;  c.Ticks = 1000; break;
            case "large":   c.Width = 4096; c.Height = 4096; c.Agents = 4194304;  c.Ticks = 500;  break;
            case "huge":    c.Width = 8192; c.Height = 8192; c.Agents = 16777216; c.Ticks = 100;  break;
            case "browser": c.Width = 1024; c.Height = 1024; c.Agents = 262144;   c.Ticks = 0;    break;
            default: return false;
        }
        c.Preset = name;
        return true;
    }

    public static int Main(string[] argv)
    {
        var c = new Sim.Config();
        bool wantJson = false;
        string? dumpGrid = null;
        var inv = CultureInfo.InvariantCulture;

        for (int i = 0; i < argv.Length; i++)
        {
            string a = argv[i];
            switch (a)
            {
                case "-h" or "--help": Console.WriteLine(Usage); return 0;
                case "--json": wantJson = true; continue;
                case "--headless": continue;
                case "--no-simd": c.Simd = false; continue;
                case "--simd": c.Simd = true; continue;
                case "--simd-portable": c.Simd = true; c.SimdPortable = true; continue;
            }

            // Everything below takes exactly one value.
            if (i + 1 >= argv.Length) { Fail(a + " requires a value"); return 2; }
            string v = argv[++i];

            int I()
            {
                if (int.TryParse(v, NumberStyles.Integer, inv, out int n)) return n;
                Fail($"'{v}' is not an integer");
                return 0;
            }
            float F()
            {
                if (float.TryParse(v, NumberStyles.Float, inv, out float f)) return f;
                Fail($"'{v}' is not a number");
                return 0f;
            }

            switch (a)
            {
                case "--preset": if (!ApplyPreset(c, v)) Fail($"unknown preset '{v}'"); break;
                case "--width":  c.Width = I();  c.Preset = "custom"; break;
                case "--height": c.Height = I(); c.Preset = "custom"; break;
                case "--agents": c.Agents = I(); c.Preset = "custom"; break;
                case "--ticks":  c.Ticks = I(); break;
                case "--warmup": c.Warmup = I(); break;
                case "--seed":   c.Seed = (uint)I(); break;
                case "--threads": c.Threads = I(); break;
                // Spatial ordering of the agent arrays; the argument is
                // how many ticks between re-sorts. 0 keeps creation order.
                case "--agent-tile": c.AgentTile = I(); break;
                case "--hash-every":   c.HashEvery = I(); break;
                case "--sensor-steps": c.SensorSteps = I(); break;
                case "--rot-steps":    c.RotSteps = I(); break;
                case "--sensor-dist":  c.SensorDist = F(); break;
                case "--step":         c.Step = F(); break;
                case "--deposit":      c.Deposit = F(); break;
                case "--decay":        c.Decay = F(); break;
                case "--dump-grid":    dumpGrid = v; break;
                case "--display-max":  break;   // CLI compatibility, unused here
                case "--update":
                    if (v is not ("serial" or "deferred")) Fail("--update must be serial|deferred");
                    c.Update = v;
                    break;
                case "--deposit-reduce":
                    if (v is not ("private" or "binned")) Fail("--deposit-reduce must be private|binned");
                    c.Reduce = v;
                    break;
                // SPEC-1 section 10: never silently ignore an unknown flag.
                default: Fail($"unknown argument '{a}'"); break;
            }
        }

        Sim s;
        try { s = new Sim(c); }
        catch (ArgumentException e) { Console.Error.WriteLine("error: " + e.Message); return 2; }

        bool logTicks = Environment.GetEnvironmentVariable("SLIMEBENCH_TICK_MS") == "1";
        string cls = "S";
        // The variant names the width the runtime picked, as impl/c names the
        // instruction set: "vector256" and "vector512" are different machine
        // code from one source and should not share a row.
        string variant = c.Simd ? Simd.Name(c.SimdPortable) : "scalar";
        if (c.Simd && !Simd.Available(c.SimdPortable))
        {
            Console.Error.WriteLine("error: --simd requested but no vector unit is available");
            return 2;
        }
        double msTotal;
        double[] tickMs;

        if (c.Threads > 1)
        {
            cls = "P";
            variant = c.Reduce;
            var r = Parallel.Run(s, c.Warmup, c.Ticks, logTicks);
            msTotal = r.MsTotal;
            tickMs = r.TickMs;
        }
        else
        {
            for (int i = 0; i < c.Warmup; i++) s.Tick();
            s.NsAgents = 0;
            s.NsDiffuse = 0;

            tickMs = new double[c.Ticks];
            long start = System.Diagnostics.Stopwatch.GetTimestamp();
            for (int t = 0; t < c.Ticks; t++)
            {
                long a = System.Diagnostics.Stopwatch.GetTimestamp();
                s.Tick();
                tickMs[t] = Sim.ToNs(System.Diagnostics.Stopwatch.GetTimestamp() - a) / 1e6;
                if (logTicks)
                    Console.Error.WriteLine(string.Format(inv, "tick_ms {0} {1:F6}", t, tickMs[t]));
                if (c.HashEvery != 0 && (t + 1) % c.HashEvery == 0)
                    Console.Error.WriteLine($"tick {t + 1} grid=0x{s.HashGrid():X8} agents=0x{s.HashAgents():X8}");
            }
            msTotal = Sim.ToNs(System.Diagnostics.Stopwatch.GetTimestamp() - start) / 1e6;
        }

        // Raw little-endian f32, one word per cell -- the same bytes every
        // other port writes, so the tolerant conformance gate has one reader.
        if (dumpGrid != null)
        {
            using var fs = File.Create(dumpGrid);
            var buf = new byte[s.Grid.Length * 4];
            Buffer.BlockCopy(s.Grid, 0, buf, 0, buf.Length);
            fs.Write(buf);
        }

        GcStats(c.Ticks);

        if (wantJson) Console.WriteLine(ResultJson(s, cls, variant, msTotal, tickMs));
        else PrintHuman(s, variant, msTotal);
        return 0;
    }

    /// <summary>
    /// What the collector did, under SLIMEBENCH_GC_STATS=1. The interesting
    /// answer is "almost nothing": the arrays are allocated once and written
    /// into thereafter, so this benchmark runs a garbage-collected runtime
    /// with an idle collector.
    /// </summary>
    private static void GcStats(int ticks)
    {
        if (Environment.GetEnvironmentVariable("SLIMEBENCH_GC_STATS") != "1") return;
        Console.Error.WriteLine(string.Format(CultureInfo.InvariantCulture,
            "gc_stats collections={0}/{1}/{2} allocated_mib={3:F1} heap_mib={4:F1} ticks={5}",
            GC.CollectionCount(0), GC.CollectionCount(1), GC.CollectionCount(2),
            GC.GetTotalAllocatedBytes(false) / 1048576.0,
            GC.GetTotalMemory(false) / 1048576.0, ticks));
    }

    private static void PrintHuman(Sim s, string variant, double msTotal)
    {
        var inv = CultureInfo.InvariantCulture;
        var c = s.Cfg;
        Console.Write(string.Format(inv, "{0} {1}x{2} agents={3} ticks={4} update={5} variant={6}",
            c.Preset, c.Width, c.Height, c.Agents, c.Ticks, c.Update, variant));
        if (c.Threads > 1) Console.Write(string.Format(inv, " threads={0} reduce={1}", c.Threads, c.Reduce));
        Console.WriteLine();
        Console.WriteLine($"  grid_hash  0x{s.HashGrid():X8}");
        Console.WriteLine($"  agent_hash 0x{s.HashAgents():X8}");
        Console.WriteLine(string.Format(inv, "  total      {0:F2} ms  ({1:F4} ms/tick)",
            msTotal, c.Ticks > 0 ? msTotal / c.Ticks : 0.0));
        Console.WriteLine(string.Format(inv, "  agents     {0:F2} ms", s.NsAgents / 1e6));
        Console.WriteLine(string.Format(inv, "  diffuse    {0:F2} ms", s.NsDiffuse / 1e6));
    }

    private static string ResultJson(Sim s, string cls, string variant, double msTotal, double[] tickMs)
    {
        var inv = CultureInfo.InvariantCulture;
        int n = tickMs.Length;
        var sorted = (double[])tickMs.Clone();
        Array.Sort(sorted);
        double median = 0, p99 = 0, mean = 0;
        if (n > 0)
        {
            median = sorted[n / 2];
            p99 = sorted[Math.Min(n - 1, (int)(n * 0.99))];
            foreach (double v in tickMs) mean += v;
            mean /= n;
        }
        var c = s.Cfg;
        double cells = (double)c.Width * c.Height;
        double maups = msTotal > 0 ? (double)c.Agents * n / msTotal / 1000.0 : 0.0;
        double mcups = msTotal > 0 ? cells * n / msTotal / 1000.0 : 0.0;

        return string.Format(inv,
            "{{\"schema\":1,\"impl\":\"csharp\",\"backend\":\"headless\",\"class\":\"{0}\","
            + "\"preset\":\"{1}\",\"variant\":\"{2}\",\"width\":{3},\"height\":{4},"
            + "\"agents\":{5},\"ticks\":{6},\"seed\":{7},\"update\":\"{8}\",\"threads\":{9},"
            + "\"grid_hash\":\"0x{10:X8}\",\"agent_hash\":\"0x{11:X8}\",\"dirtable_hash\":\"0x{12:X8}\","
            + "\"ms_total\":{13:F4},\"ms_agents\":{14:F4},\"ms_diffuse\":{15:F4},"
            + "\"ms_per_tick_mean\":{16:F6},\"ms_per_tick_median\":{17:F6},\"ms_per_tick_p99\":{18:F6},"
            + "\"maups\":{19:F4},\"mcups\":{20:F4}}}",
            cls, c.Preset, variant, c.Width, c.Height, c.Agents, n, c.Seed, c.Update, c.Threads,
            s.HashGrid(), s.HashAgents(), Sim.DirtableHashRuntime(),
            msTotal, s.NsAgents / 1e6, s.NsDiffuse / 1e6,
            mean, median, p99, maups, mcups);
    }
}
