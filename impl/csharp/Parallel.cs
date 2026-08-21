namespace Slimebench;

/// <summary>
/// Class P for the C# target (SPEC-1 section 5.6).
///
/// <para>Phase for phase the C reference's decomposition, because class P
/// compares the same decomposition across languages. What is deliberately C#
/// is <see cref="System.Threading.Barrier"/> from the base class library --
/// the direct counterpart of Java's CyclicBarrier, and the reason these two
/// rows are worth reading next to each other. Section 5 of docs/RESULTS.md
/// shows the barrier is where languages actually differ at high thread
/// counts, so substituting a hand-rolled one would remove the thing being
/// measured.</para>
///
/// <para>Dedicated threads, not the thread pool and not tasks. The workers
/// live for the whole run and spend their time at a barrier; handing that to a
/// pool designed for short work items would measure the pool.</para>
/// </summary>
internal sealed class Parallel
{
    internal sealed class Result
    {
        public double MsTotal;
        public double[] TickMs = [];
    }

    private readonly Sim _s;
    private readonly int _t, _cells, _agents, _height, _log2w;
    private readonly float _deposit;
    private readonly bool _binned;
    private readonly System.Threading.Barrier _bar;

    private readonly int[] _aidx;
    private readonly int[]? _sorted, _counts, _offsets, _ybucket;
    private readonly float[]? _priv;

    private Parallel(Sim s, int t)
    {
        _s = s;
        _t = t;
        _cells = s.Cfg.Width * s.Cfg.Height;
        _agents = s.Cfg.Agents;
        _height = s.Cfg.Height;
        _log2w = s.Log2W;
        _deposit = s.Cfg.Deposit;
        _binned = s.Cfg.Reduce == "binned";
        _bar = new System.Threading.Barrier(t);

        _aidx = new int[_agents];
        if (_binned)
        {
            _sorted = new int[_agents];
            _counts = new int[t * t];
            _offsets = new int[t * t];
            _ybucket = new int[_height];
            for (int y = 0; y < _height; y++)
            {
                // Fixed, even row blocks. The adaptive variant the C reference
                // carries bought 5.9 % and is not the shipping config -- see
                // section 11 of docs/RESULTS.md.
                int b = 0;
                while (b < t - 1 && y >= Hi(_height, t, b)) b++;
                _ybucket[y] = b;
            }
        }
        else
        {
            _priv = new float[t * _cells];
        }
    }

    /// <summary>Contiguous split of [0,n) into parts; identical to the C reference's.</summary>
    private static int Lo(int n, int parts, int i) => i * (n / parts) + Math.Min(i, n % parts);

    private static int Hi(int n, int parts, int i) =>
        Lo(n, parts, i) + n / parts + (i < n % parts ? 1 : 0);

    private int BucketOf(int idx) => _ybucket![idx >>> _log2w];

    // ---- private ----------------------------------------------------------

    private void AgentsPrivate(int tid)
    {
        int a = Lo(_agents, _t, tid), b = Hi(_agents, _t, tid);
        _s.AgentPass(a, b, _aidx);
        int baseIdx = tid * _cells;
        for (int i = a; i < b; i++) _priv![baseIdx + _aidx[i]] += _deposit;
    }

    private void MergePrivate(int tid)
    {
        int a = Lo(_cells, _t, tid), b = Hi(_cells, _t, tid);
        float[] g = _s.Grid, priv = _priv!;
        for (int i = a; i < b; i++)
        {
            float acc = priv[i];
            priv[i] = 0.0f;
            for (int k = 1; k < _t; k++)
            {
                acc += priv[k * _cells + i];
                priv[k * _cells + i] = 0.0f;
            }
            g[i] += acc;
        }
    }

    // ---- binned -----------------------------------------------------------

    private void AgentsBinned(int tid)
    {
        int a = Lo(_agents, _t, tid), b = Hi(_agents, _t, tid);
        int cbase = tid * _t;
        for (int i = 0; i < _t; i++) _counts![cbase + i] = 0;
        _s.AgentPass(a, b, _aidx);
        for (int i = a; i < b; i++) _counts![cbase + BucketOf(_aidx[i])]++;
    }

    private void PrefixBinned()
    {
        int running = 0;
        for (int b = 0; b < _t; b++)
            for (int w = 0; w < _t; w++)
            {
                _offsets![w * _t + b] = running;
                running += _counts![w * _t + b];
            }
    }

    private void ScatterBinned(int tid)
    {
        int a = Lo(_agents, _t, tid), b = Hi(_agents, _t, tid);
        int obase = tid * _t;
        for (int i = a; i < b; i++)
            _sorted![_offsets![obase + BucketOf(_aidx[i])]++] = i;
    }

    /// <summary>
    /// Applies exactly the deposits landing in this worker's row block, in
    /// ascending agent index. No two workers write the same cell, so no
    /// atomics are needed and the order matches the serial chain.
    /// </summary>
    private void DepositBinned(int tid)
    {
        int begin = 0;
        for (int b = 0; b < tid; b++)
            for (int w = 0; w < _t; w++) begin += _counts![w * _t + b];
        int end = begin;
        for (int w = 0; w < _t; w++) end += _counts![w * _t + tid];

        float[] d = _s.Dep!;
        for (int j = begin; j < end; j++) d[_aidx[_sorted![j]]] += _deposit;
    }

    // ---- the tick ---------------------------------------------------------

    private void RunTick(int tid)
    {
        if (_binned)
        {
            AgentsBinned(tid);
            _bar.SignalAndWait();
            if (tid == 0) PrefixBinned();
            _bar.SignalAndWait();
            ScatterBinned(tid);
            _bar.SignalAndWait();
            DepositBinned(tid);
            _bar.SignalAndWait();
            _s.MergeRows(Lo(_height, _t, tid), Hi(_height, _t, tid));
            _bar.SignalAndWait();
        }
        else
        {
            AgentsPrivate(tid);
            _bar.SignalAndWait();
            MergePrivate(tid);
            _bar.SignalAndWait();
        }

        _s.DiffuseRows(Lo(_height, _t, tid), Hi(_height, _t, tid));
        _bar.SignalAndWait();

        // Two array references are shared, so exactly one worker swaps them,
        // between two barriers -- everyone else is parked.
        if (tid == 0) _s.SwapBuffers();
        _bar.SignalAndWait();
    }

    public static Result Run(Sim s, int warmup, int ticks, bool logTicks)
    {
        if (s.Dep == null)
            throw new ArgumentException("--threads > 1 requires --update deferred (SPEC-1 5.5)");

        int t = s.Cfg.Threads;
        var p = new Parallel(s, t);
        var r = new Result { TickMs = new double[ticks] };

        // Worker 0 runs on this thread and drives the loop; the others are
        // started once and stay for the whole run, so the measurement never
        // includes thread creation.
        int total = warmup + ticks;
        var workers = new Thread[t - 1];
        for (int k = 1; k < t; k++)
        {
            int tid = k;
            workers[k - 1] = new Thread(() =>
            {
                for (int i = 0; i < total; i++) p.RunTick(tid);
            }, 1 << 20) { Name = $"slimebench-{tid}", IsBackground = false };
            workers[k - 1].Start();
        }

        for (int i = 0; i < warmup; i++) p.RunTick(0);
        s.NsAgents = 0;
        s.NsDiffuse = 0;

        long start = System.Diagnostics.Stopwatch.GetTimestamp();
        for (int i = 0; i < ticks; i++)
        {
            long a = System.Diagnostics.Stopwatch.GetTimestamp();
            p.RunTick(0);
            r.TickMs[i] = Sim.ToNs(System.Diagnostics.Stopwatch.GetTimestamp() - a) / 1e6;
            if (logTicks)
                Console.Error.WriteLine(string.Format(
                    System.Globalization.CultureInfo.InvariantCulture,
                    "tick_ms {0} {1:F6}", i, r.TickMs[i]));
        }
        r.MsTotal = Sim.ToNs(System.Diagnostics.Stopwatch.GetTimestamp() - start) / 1e6;

        foreach (var w in workers) w.Join();
        return r;
    }
}
