//! Multi-threaded tick (SPEC-1 section 5.6, benchmark class P).
//!
//! Same two reduction strategies as the C reference, same phase order, same
//! deposit order -- so `binned` is bit-identical to the single-threaded run
//! here too, and the two implementations are comparable as implementations
//! rather than as two different algorithms.
//!
//! Structurally this differs from the C in one deliberate way: `std::thread::
//! scope` lets the workers run the *whole* tick loop, with thread 0 doing the
//! between-tick serial work at a barrier, instead of a master waking a pool
//! once per tick. That removes the condvar handshake C needs (mutex, two
//! condition variables, a generation counter) and with it one wake/sleep round
//! trip per tick. It is the shape the language pushes you towards, and
//! reporting it as "Rust's way of writing this" is more honest than
//! transliterating the C.
//!
//! ## Why there is `unsafe` in here
//!
//! Every phase partitions a buffer so that no two threads touch the same
//! element, but the partitions differ per phase (agents by index, cells by
//! row, deposits by row block) and are separated by barriers. Rust's borrow
//! checker cannot see that, and no safe abstraction expresses it without
//! either copying or per-element synchronisation -- which is what is being
//! measured. So the buffers are shared as raw pointers behind [`Shared`], with
//! the disjointness argument written out at each use.
//!
//! Note what is *not* handwaved: the sound parts stay safe. The agent rule
//! itself is `sim::agent_step_one`, shared verbatim with the single-threaded
//! path.

use crate::sim::{AgentBufs, Config, Reduce, Sim, Update};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Barrier;

/// A raw pointer that may cross thread boundaries.
///
/// Safety contract for every use below: at any instant, the set of indices one
/// thread dereferences through this pointer is disjoint from every other
/// thread's, and phases that change the partition are separated by a barrier
/// (which is also the required happens-before edge).
struct Shared<T>(*mut T);
unsafe impl<T> Send for Shared<T> {}
unsafe impl<T> Sync for Shared<T> {}

impl<T> Shared<T> {
    fn new(s: &mut [T]) -> Self {
        Shared(s.as_mut_ptr())
    }
    /// # Safety
    /// The caller must uphold the disjointness contract above, and `len` must
    /// not exceed the length of the original slice.
    #[allow(clippy::mut_from_ref)]
    unsafe fn all(&self, len: usize) -> &mut [T] {
        std::slice::from_raw_parts_mut(self.0, len)
    }
}

/// Contiguous split of `[0, n)` into `parts`; part `i` is `[lo, hi)`.
/// Identical to the C reference's `split`, deliberately -- the partition is
/// what makes `binned` reproduce the serial deposit order.
fn split(n: u32, parts: u32, i: u32) -> (u32, u32) {
    let base = n / parts;
    let rem = n % parts;
    let lo = i * base + if i < rem { i } else { rem };
    (lo, lo + base + u32::from(i < rem))
}

struct Pool {
    cells: usize,
    agents: usize,
    height: u32,
    width: u32,
    log2w: u32,
    xmask: u32,
    ymask: u32,
    nthreads: u32,
    deposit: f32,
    decay: f32,
    simd: bool,
    reduce: Reduce,

    // The two grid buffers, fixed for the whole run. Which one is live is
    // decided by tick parity rather than by swapping pointers -- see
    // `run_tick`. That is worth two barriers per tick at 32 threads.
    buf: [Shared<f32>; 2],
    dep: Shared<f32>,
    ax: Shared<f32>,
    ay: Shared<f32>,
    adir: Shared<u16>,
    arng: Shared<u32>,
    cos_tab: *const f32,
    sin_tab: *const f32,

    // Reduce::Private -- one full-grid deposit buffer per thread.
    priv_bufs: Shared<f32>, // nthreads * cells, one contiguous allocation

    // Reduce::Binned -- target cell per agent plus a stable counting sort of
    // the agent indices by row block.
    aidx: Shared<u32>,    // agents
    sorted: Shared<u32>,  // agents
    counts: Shared<u32>,  // nthreads * nthreads
    offsets: Shared<u32>, // nthreads * nthreads
    ybucket: Shared<u16>, // height -- row to owning thread
    rowcnt: Shared<u32>,  // nthreads * height
    rowsum: Shared<u32>,  // height
    adaptive: bool,

    barrier: Barrier,
    ns_total: AtomicU64,
}

// The two table pointers are read-only after construction.
unsafe impl Send for Pool {}
unsafe impl Sync for Pool {}

impl Pool {
    /// The live grid for `tick`, and the buffer the diffusion pass writes.
    ///
    /// # Safety
    /// Same disjointness contract as [`Shared::all`].
    #[allow(clippy::mut_from_ref)]
    unsafe fn grid(&self, tick: u64) -> &mut [f32] {
        self.buf[(tick & 1) as usize].all(self.cells)
    }
    /// # Safety
    /// Same disjointness contract as [`Shared::all`].
    #[allow(clippy::mut_from_ref)]
    unsafe fn scratch(&self, tick: u64) -> &mut [f32] {
        self.buf[((tick & 1) ^ 1) as usize].all(self.cells)
    }

    fn bucket_of(&self, idx: u32) -> u32 {
        // Table lookup, not arithmetic: this runs twice per agent per tick and
        // a division there would cost more than the rest of the step.
        unsafe { *self.ybucket.all(self.height as usize).get_unchecked((idx >> self.log2w) as usize) as u32 }
    }

    fn agent_bufs(&self) -> AgentBufs<'_> {
        unsafe {
            AgentBufs {
                ax: self.ax.all(self.agents),
                ay: self.ay.all(self.agents),
                adir: self.adir.all(self.agents),
                arng: self.arng.all(self.agents * 4),
                cos_tab: std::slice::from_raw_parts(self.cos_tab, crate::dirtable::NDIR as usize),
                sin_tab: std::slice::from_raw_parts(self.sin_tab, crate::dirtable::NDIR as usize),
            }
        }
    }

    // ---- Reduce::Private -------------------------------------------------

    /// Each thread owns agents `[lo, hi)` and its own full-grid buffer, so
    /// nothing is shared during the pass.
    fn agents_private(&self, p: &crate::sim::AgentParams, tid: u32, tick: u64) {
        let grid = unsafe { self.grid(tick) };
        let dep = unsafe {
            &mut self.priv_bufs.all(self.nthreads as usize * self.cells)
                [tid as usize * self.cells..(tid as usize + 1) * self.cells]
        };
        let AgentBufs { ax, ay, adir, arng, cos_tab, sin_tab } = self.agent_bufs();
        let (lo, hi) = split(self.agents as u32, self.nthreads, tid);
        for i in lo as usize..hi as usize {
            let idx = crate::sim::agent_step_one(
                p, grid, ax, ay, adir, arng, cos_tab, sin_tab, i) as usize;
            dep[idx] += self.deposit;
        }
    }

    /// Each thread owns cells `[lo, hi)` of every buffer -- disjoint by cell,
    /// so reading all T buffers at those indices is fine.
    ///
    /// Fixed thread order, so the result is reproducible for this thread
    /// count. It is NOT in general the same grouping as the serial chain; see
    /// SPEC-1 section 5.6.
    fn merge_private(&self, tid: u32, tick: u64) {
        let grid = unsafe { self.grid(tick) };
        let all = unsafe { self.priv_bufs.all(self.nthreads as usize * self.cells) };
        let (lo, hi) = split(self.cells as u32, self.nthreads, tid);
        for i in lo as usize..hi as usize {
            let mut acc = all[i];
            all[i] = 0.0;
            for t in 1..self.nthreads as usize {
                acc += all[t * self.cells + i];
                all[t * self.cells + i] = 0.0;
            }
            grid[i] += acc;
        }
    }

    // ---- Reduce::Binned --------------------------------------------------

    /// Writes `aidx[lo..hi]` (this thread's agents only) and row `tid` of
    /// `counts` and `rowcnt`.
    fn agents_binned(&self, p: &crate::sim::AgentParams, tid: u32, tick: u64) {
        let grid = unsafe { self.grid(tick) };
        let aidx = unsafe { self.aidx.all(self.agents) };
        let t = self.nthreads as usize;
        let cnt = unsafe { &mut self.counts.all(t * t)[tid as usize * t..(tid as usize + 1) * t] };
        cnt.fill(0);

        let AgentBufs { ax, ay, adir, arng, cos_tab, sin_tab } = self.agent_bufs();
        let (lo, hi) = split(self.agents as u32, self.nthreads, tid);

        if !self.adaptive {
            for i in lo as usize..hi as usize {
                let idx = crate::sim::agent_step_one(
                    p, grid, ax, ay, adir, arng, cos_tab, sin_tab, i);
                aidx[i] = idx;
                cnt[self.bucket_of(idx) as usize] += 1;
            }
            return;
        }

        let h = self.height as usize;
        let rc = unsafe {
            &mut self.rowcnt.all(t * h)[tid as usize * h..(tid as usize + 1) * h]
        };
        rc.fill(0);
        let yb = unsafe { self.ybucket.all(h) };
        for i in lo as usize..hi as usize {
            let idx = crate::sim::agent_step_one(
                p, grid, ax, ay, adir, arng, cos_tab, sin_tab, i);
            aidx[i] = idx;
            let y = (idx >> self.log2w) as usize;
            rc[y] += 1;
            cnt[yb[y] as usize] += 1;
        }
    }

    /// Prefix sum over (bucket, thread) in that order, by thread 0 alone.
    /// Because each thread owns a contiguous ascending agent range, walking
    /// threads in order inside a bucket lays the agents down in ascending
    /// global index -- which is what makes the deposit chain identical to the
    /// serial one.
    ///
    /// Parallelising this was tried in C and lost 18% at sixteen threads: the
    /// T^2 integer adds turn into T^2 cache-line transfers out of other cores.
    /// See the comment in `impl/c/sb_parallel.c`.
    fn prefix_binned(&self) {
        let t = self.nthreads as usize;
        let counts = unsafe { self.counts.all(t * t) };
        let offsets = unsafe { self.offsets.all(t * t) };
        let mut running = 0u32;
        for b in 0..t {
            for w in 0..t {
                offsets[w * t + b] = running;
                running += counts[w * t + b];
            }
        }
    }

    /// Reads row `tid` of `offsets` and its own agent range; the destination
    /// slots in `sorted` are disjoint across threads because the prefix sum
    /// handed each (thread, bucket) pair its own run.
    fn scatter_binned(&self, tid: u32) {
        let t = self.nthreads as usize;
        let aidx = unsafe { self.aidx.all(self.agents) };
        let sorted = unsafe { self.sorted.all(self.agents) };
        let off = unsafe { &mut self.offsets.all(t * t)[tid as usize * t..(tid as usize + 1) * t] };
        let (lo, hi) = split(self.agents as u32, self.nthreads, tid);
        for i in lo as usize..hi as usize {
            let b = self.bucket_of(aidx[i]) as usize;
            sorted[off[b] as usize] = i as u32;
            off[b] += 1;
        }
    }

    /// Thread `tid` applies exactly the deposits landing in its own row block,
    /// in ascending agent index. Cells in other blocks are never touched.
    fn deposit_binned(&self, tid: u32) {
        let t = self.nthreads as usize;
        let counts = unsafe { self.counts.all(t * t) };
        let aidx = unsafe { self.aidx.all(self.agents) };
        let sorted = unsafe { self.sorted.all(self.agents) };
        let dep = unsafe { self.dep.all(self.cells) };

        // Bucket `tid` occupies sorted[begin, end); begin is the offset the
        // prefix sum handed thread 0 for this bucket, before scatter advanced it.
        let mut begin = 0usize;
        for b in 0..tid as usize {
            for w in 0..t {
                begin += counts[w * t + b] as usize;
            }
        }
        let mut end = begin;
        for w in 0..t {
            end += counts[w * t + tid as usize] as usize;
        }

        for j in begin..end {
            let idx = aidx[sorted[j] as usize] as usize;
            dep[idx] += self.deposit;
        }
    }

    /// Partitioned by rows rather than cells so the same loop can also reduce
    /// the per-row histograms; a row range is a contiguous cell range anyway.
    fn merge_binned(&self, tid: u32, tick: u64) {
        let grid = unsafe { self.grid(tick) };
        let dep = unsafe { self.dep.all(self.cells) };
        let h = self.height;
        let (ylo, yhi) = split(h, self.nthreads, tid);

        for y in ylo..yhi {
            let base = (y as usize) << self.log2w;
            for x in 0..self.width as usize {
                let i = base + x;
                grid[i] += dep[i];
                dep[i] = 0.0;
            }
            if self.adaptive {
                let t = self.nthreads as usize;
                let rowcnt = unsafe { self.rowcnt.all(t * h as usize) };
                let rowsum = unsafe { self.rowsum.all(h as usize) };
                let mut sum = 0u32;
                for th in 0..t {
                    sum += rowcnt[th * h as usize + y as usize];
                }
                rowsum[y as usize] = sum;
            }
        }
    }

    /// Recompute row boundaries so every thread gets a similar number of
    /// deposits. Cannot change the result: the partition decides *which*
    /// thread applies a deposit, never the order deposits hit a cell.
    fn rebalance(&self) {
        let h = self.height as usize;
        let t = self.nthreads;
        let rowsum = unsafe { self.rowsum.all(h) };
        let ybucket = unsafe { self.ybucket.all(h) };

        let total: u64 = rowsum.iter().map(|&v| v as u64).sum();
        if total == 0 {
            return;
        }
        let mut b = 0u32;
        let mut acc = 0u64;
        for y in 0..h {
            ybucket[y] = b as u16;
            acc += rowsum[y] as u64;
            // Close bucket b once it holds its share, but never so early that
            // the remaining buckets cannot each get at least one row.
            while b + 1 < t
                && acc * t as u64 >= total * (b as u64 + 1)
                && (h - y - 1) >= (t - b - 1) as usize
            {
                b += 1;
            }
        }
    }

    /// Output cells are independent, so splitting the row range is
    /// unconditionally bit-identical.
    fn diffuse(&self, tid: u32, tick: u64) {
        let (lo, hi) = split(self.height, self.nthreads, tid);
        let mut st = crate::sim::Stencil {
            src: unsafe { self.grid(tick) },
            dst: unsafe { self.scratch(tick) },
            w: self.width,
            log2w: self.log2w,
            xmask: self.xmask,
            ymask: self.ymask,
            decay: self.decay,
        };
        if self.simd {
            crate::simd::run(&mut st, lo, hi);
        } else {
            st.run(lo, hi);
        }
    }

    /// One tick, run by every thread. Ends with a barrier, so on return the
    /// whole pool is quiesced and `tick + 1`'s buffers are safe to read.
    ///
    /// Six barriers for `binned`, matching the C reference's five phase
    /// barriers plus its master/worker handshake. Getting there needed two
    /// things the C does differently:
    ///
    /// * **No buffer swap.** Which of the two buffers is live follows from
    ///   `tick & 1`, so nobody has to serialise on exchanging pointers.
    /// * **The rebalance overlaps the diffusion pass.** It only reads `rowsum`
    ///   (finished at the merge barrier) and writes `ybucket`, which nothing
    ///   reads again until the next tick's agent phase -- on the far side of
    ///   the closing barrier.
    ///
    /// The naive version -- swap the pointers at a barrier of their own --
    /// cost two extra barriers and 1259 ms against 990 at 32 threads.
    fn run_tick(&self, p: &crate::sim::AgentParams, tid: u32, tick: u64) {
        match self.reduce {
            Reduce::Binned => {
                self.agents_binned(p, tid, tick);
                self.barrier.wait();
                if tid == 0 {
                    self.prefix_binned();
                }
                self.barrier.wait();
                self.scatter_binned(tid);
                self.barrier.wait();
                self.deposit_binned(tid);
                self.barrier.wait();
                self.merge_binned(tid, tick);
                self.barrier.wait();
                if tid == 0 && self.adaptive {
                    self.rebalance();
                }
            }
            Reduce::Private => {
                self.agents_private(p, tid, tick);
                self.barrier.wait();
                self.merge_private(tid, tick);
                self.barrier.wait();
            }
        }
        self.diffuse(tid, tick);
        self.barrier.wait();
    }
}

/// Result of a class-P run: what `main` needs that only the pool knows.
pub struct Run {
    pub ms_total: f64,
    pub tick_ms: Vec<f64>,
    pub scratch_bytes: usize,
}

/// Run `ticks` ticks of `sim` across `cfg.threads` threads.
///
/// Returns `Err` for the one case SPEC-1 forbids rather than silently
/// computing something else.
pub fn run(sim: &mut Sim, warmup: u32, ticks: u32, hash_every: u32) -> Result<Run, String> {
    let cfg: Config = sim.cfg.clone();
    if cfg.update != Update::Deferred {
        return Err(concat!(
            "--threads > 1 requires --update deferred.\n",
            "       SPEC-1 'serial' makes an agent's deposit visible to the\n",
            "       next agent in the same tick, which is a sequential\n",
            "       dependency; see SPEC-1 section 5.5."
        )
        .into());
    }

    let t = cfg.threads as usize;
    let cells = cfg.width as usize * cfg.height as usize;
    let agents = cfg.agents as usize;
    let h = cfg.height as usize;
    let adaptive = std::env::var_os("SLIMEBENCH_NO_REBALANCE").is_none();

    // Backing storage lives here, outside the scope, so the pool's raw
    // pointers stay valid for exactly as long as the threads do.
    let mut priv_bufs: Vec<f32> = if cfg.reduce == Reduce::Private {
        vec![0.0; t * cells]
    } else {
        Vec::new()
    };
    let binned = cfg.reduce == Reduce::Binned;
    let mut aidx: Vec<u32> = vec![0; if binned { agents } else { 0 }];
    let mut sorted: Vec<u32> = vec![0; if binned { agents } else { 0 }];
    let mut counts: Vec<u32> = vec![0; if binned { t * t } else { 0 }];
    let mut offsets: Vec<u32> = vec![0; if binned { t * t } else { 0 }];
    let mut rowcnt: Vec<u32> = vec![0; if binned && adaptive { t * h } else { 0 }];
    let mut rowsum: Vec<u32> = vec![0; if binned && adaptive { h } else { 0 }];

    // Row -> owning thread, using the same split as the diffusion pass so a
    // thread's deposits land in rows it already touches.
    let mut ybucket: Vec<u16> = vec![0; if binned { h } else { 0 }];
    if binned {
        for b in 0..cfg.threads {
            let (lo, hi) = split(cfg.height, cfg.threads, b);
            for y in lo..hi {
                ybucket[y as usize] = b as u16;
            }
        }
    }

    let scratch_bytes = if binned {
        2 * agents * 4 + 2 * t * t * 4 + h * 2 + if adaptive { (t + 1) * h * 4 } else { 0 }
    } else {
        t * cells * 4
    };

    let p = sim.agent_params();
    let log2w = sim.log2w();
    let (xmask, ymask) = sim.masks();
    let (grid, scratch, dep, bufs) = sim.parts();

    let pool = Pool {
        cells,
        agents,
        height: cfg.height,
        width: cfg.width,
        log2w,
        xmask,
        ymask,
        nthreads: cfg.threads,
        deposit: cfg.deposit,
        decay: cfg.decay,
        simd: cfg.simd,
        reduce: cfg.reduce,

        buf: [Shared::new(grid), Shared::new(scratch)],
        dep: Shared::new(dep),
        ax: Shared::new(bufs.ax),
        ay: Shared::new(bufs.ay),
        adir: Shared::new(bufs.adir),
        arng: Shared::new(bufs.arng),
        cos_tab: bufs.cos_tab.as_ptr(),
        sin_tab: bufs.sin_tab.as_ptr(),

        priv_bufs: Shared::new(&mut priv_bufs),
        aidx: Shared::new(&mut aidx),
        sorted: Shared::new(&mut sorted),
        counts: Shared::new(&mut counts),
        offsets: Shared::new(&mut offsets),
        ybucket: Shared::new(&mut ybucket),
        rowcnt: Shared::new(&mut rowcnt),
        rowsum: Shared::new(&mut rowsum),
        adaptive,

        barrier: Barrier::new(t),
        ns_total: AtomicU64::new(0),
    };

    let mut tick_ms: Vec<f64> = Vec::new();

    std::thread::scope(|s| {
        let pool = &pool;
        let tick_ms = &mut tick_ms;
        let total = warmup as u64 + ticks as u64;
        for tid in 1..cfg.threads {
            s.spawn(move || {
                for tick in 0..total {
                    pool.run_tick(&p, tid, tick);
                }
            });
        }

        // Thread 0 is a worker like the others; it just also holds the clock.
        // `run_tick` ends with a barrier, so reading the clock here is a
        // whole-pool measurement, not thread 0's own progress.
        for tick in 0..warmup as u64 {
            pool.run_tick(&p, 0, tick);
        }
        let t_start = crate::sim::now_ns();
        for tick in warmup as u64..total {
            let a = crate::sim::now_ns();
            pool.run_tick(&p, 0, tick);
            tick_ms.push((crate::sim::now_ns() - a) as f64 / 1e6);
        }
        pool.ns_total
            .store(crate::sim::now_ns() - t_start, Ordering::Relaxed);
    });

    // Tick `n` writes into `buf[(n & 1) ^ 1]`, so after an odd number of ticks
    // the live grid is what the Sim still calls `scratch`.
    if (ticks as u64 + warmup as u64) % 2 == 1 {
        sim.swap_buffers();
    }

    let ms_total = pool.ns_total.load(Ordering::Relaxed) as f64 / 1e6;
    sim.ns_agents = pool.ns_total.load(Ordering::Relaxed);

    if hash_every != 0 {
        eprintln!(
            "final grid=0x{:08X} agents=0x{:08X}",
            sim.hash_grid(),
            sim.hash_agents()
        );
    }

    Ok(Run { ms_total, tick_ms, scratch_bytes })
}
