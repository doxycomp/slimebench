//! slimebench -- Rust implementation of SPEC-1.
//!
//! Two indexing strategies, selected at compile time by the `unchecked`
//! feature. The point is to measure what bounds checking actually costs on
//! this workload rather than assert it, so both are first-class build targets
//! and the harness reports them side by side.
//!
//! Rust does not contract to FMA and does not reassociate float expressions,
//! so the arithmetic here is SPEC-1 conformance tier A without extra flags.
//!
//! ## A note on the `serial` update mode and aliasing
//!
//! In `Update::Serial` an agent's deposit must be visible to the next agent in
//! the same tick, i.e. reads and writes hit one buffer. The obvious way to
//! express that -- one `&[f32]` and one `&mut [f32]` over the same allocation
//! -- is undefined behaviour in Rust even though it "works". Instead the agent
//! loop is generic over `INPLACE` and, when in-place, reads through a
//! short-lived reborrow of the same `&mut` slice. Sound, and it costs nothing.

use crate::dirtable::{COS_BITS, NDIR, SIN_BITS};
use std::sync::OnceLock;
use std::time::Instant;

// Part of the public surface the SDL2/raylib frontends will use; not yet
// referenced by the headless binary.
#[allow(dead_code)]
pub const SPEC_VERSION: &str = "SPEC-1";

const FNV_OFFSET: u32 = 0x811C_9DC5;
const FNV_PRIME: u32 = 0x0100_0193;

/// Load an element. Every index reaching here has already been masked with
/// `width - 1` / `height - 1`, so the safe arm's check can never fire -- but
/// the compiler cannot prove that through a mask on a runtime-sized slice.
macro_rules! at {
    ($v:expr, $i:expr) => {{
        #[cfg(feature = "unchecked")]
        let _v = unsafe { *$v.get_unchecked($i as usize) };
        #[cfg(not(feature = "unchecked"))]
        let _v = $v[$i as usize];
        _v
    }};
}

macro_rules! at_mut {
    ($v:expr, $i:expr) => {{
        #[cfg(feature = "unchecked")]
        let _r = unsafe { $v.get_unchecked_mut($i as usize) };
        #[cfg(not(feature = "unchecked"))]
        let _r = &mut $v[$i as usize];
        _r
    }};
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Update {
    Serial,
    Deferred,
}

/// SPEC-1 section 5.6. `Binned` is bit-identical to the single-threaded run for
/// every thread count; `Private` only reproduces itself per thread count.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Reduce {
    Private,
    Binned,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub width: u32,
    pub height: u32,
    pub agents: u32,
    pub ticks: u32,
    pub warmup: u32,
    pub seed: u32,
    pub threads: u32,
    pub update: Update,
    pub reduce: Reduce,
    pub sensor_dist: f32,
    pub step: f32,
    pub deposit: f32,
    pub decay: f32,
    pub sensor_steps: u32,
    pub rot_steps: u32,
    pub simd: bool,
    /// Ticks between spatial re-sorts of the agent arrays; 0 = never.
    /// See `Sim::agent_sort` -- it changes which agent sits where, not
    /// what any of them computes.
    pub agent_tile: u32,
    pub hash_every: u32,
    pub preset: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            width: 1024,
            height: 1024,
            agents: 262_144,
            ticks: 1000,
            warmup: 0,
            seed: 12345,
            threads: 1,
            update: Update::Serial,
            reduce: Reduce::Binned,
            sensor_dist: 9.0,
            step: 1.0,
            deposit: 10.0,
            decay: 0.94,
            sensor_steps: 144,
            rot_steps: 144,
            simd: false,
            agent_tile: 0,
            hash_every: 0,
            preset: "custom".to_string(),
        }
    }
}

// ---- PRNG (SPEC-1 section 3.1) ------------------------------------------

#[inline(always)]
fn splitmix32(state: &mut u32) -> u32 {
    *state = state.wrapping_add(0x9E37_79B9);
    let mut z = *state;
    z = (z ^ (z >> 16)).wrapping_mul(0x21F0_AAAD);
    z = (z ^ (z >> 15)).wrapping_mul(0x735A_2D97);
    z ^ (z >> 15)
}

#[inline(always)]
fn xoshiro128pp(s: &mut [u32]) -> u32 {
    let result = s[0].wrapping_add(s[3]).rotate_left(7).wrapping_add(s[0]);
    let t = s[1] << 9;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = s[3].rotate_left(11);
    result
}

/// SPEC-1 section 3.2. Exact: `u >> 8 < 2^24`, and `2^24` is a power of two.
#[inline(always)]
fn rnd01(u: u32) -> f32 {
    ((u >> 8) as f32) / 16_777_216.0
}

/// SPEC-1 section 2.2.
#[inline(always)]
fn wrapf(mut v: f32, m: f32) -> f32 {
    if v < 0.0 {
        v += m;
    }
    if v >= m {
        v -= m;
    }
    v
}

/// Everything the agent loop needs that is not a buffer.
#[derive(Clone, Copy)]
pub struct AgentParams {
    pub xmask: u32,
    pub ymask: u32,
    pub log2w: u32,
    pub fw: f32,
    pub fh: f32,
    pub sdist: f32,
    pub step: f32,
    pub deposit: f32,
    pub ss: i32,
    pub rs: i32,
    pub ndir: i32,
    pub agents: usize,
}

/// The per-agent buffers, gathered so the single-threaded and the threaded
/// caller can hand the same set to [`agent_step_one`].
///
/// Callers destructure this into locals *before* their loop rather than
/// passing it in by reference. Reaching the slices through `&mut AgentBufs`
/// each iteration costs ~6% on the agent pass: LLVM reloads the slice
/// pointers from the struct instead of keeping them in registers.
pub struct AgentBufs<'a> {
    pub ax: &'a mut [f32],
    pub ay: &'a mut [f32],
    pub adir: &'a mut [u16],
    pub arng: &'a mut [u32],
    pub cos_tab: &'a [f32],
    pub sin_tab: &'a [f32],
}

// ---- simulation ----------------------------------------------------------

pub struct Sim {
    pub cfg: Config,
    log2w: u32,
    xmask: u32,
    ymask: u32,

    pub grid: Vec<f32>,
    scratch: Vec<f32>,
    dep: Vec<f32>,

    ax: Vec<f32>,
    ay: Vec<f32>,
    adir: Vec<u16>,
    arng: Vec<u32>,

    /// Spatial ordering (`Config::agent_tile`). `aid[j]` is the original index
    /// of the agent now in slot j and `slot[a]` is its inverse; everything
    /// that has to speak in agent indices rather than slots -- the deposit,
    /// the agent hash -- goes through one of them. Empty when ordering is off.
    aid: Vec<u32>,
    slot: Vec<u32>,
    agent_idx: Vec<u32>,
    sort_key: Vec<u32>,
    sort_f32: Vec<f32>,
    sort_u32: Vec<u32>,
    sort_u16: Vec<u16>,
    ticks_done: u32,

    cos_tab: Vec<f32>,
    sin_tab: Vec<f32>,

    pub ns_agents: u64,
    pub ns_diffuse: u64,
}

impl Sim {
    pub fn new(cfg: Config) -> Result<Self, String> {
        if cfg.width == 0 || !cfg.width.is_power_of_two() {
            return Err("width must be a power of two".into());
        }
        if cfg.height == 0 || !cfg.height.is_power_of_two() {
            return Err("height must be a power of two".into());
        }

        let cells = cfg.width as usize * cfg.height as usize;
        let agents = cfg.agents as usize;

        let mut s = Self {
            log2w: cfg.width.trailing_zeros(),
            xmask: cfg.width - 1,
            ymask: cfg.height - 1,
            grid: vec![0.0; cells],
            scratch: vec![0.0; cells],
            dep: if cfg.update == Update::Deferred {
                vec![0.0; cells]
            } else {
                Vec::new()
            },
            ax: vec![0.0; agents],
            ay: vec![0.0; agents],
            adir: vec![0; agents],
            arng: vec![0; agents * 4],
            aid: if cfg.agent_tile > 0 { (0..agents as u32).collect() } else { Vec::new() },
            slot: if cfg.agent_tile > 0 { (0..agents as u32).collect() } else { Vec::new() },
            agent_idx: if cfg.agent_tile > 0 { vec![0; agents] } else { Vec::new() },
            sort_key: if cfg.agent_tile > 0 { vec![0; agents] } else { Vec::new() },
            sort_f32: if cfg.agent_tile > 0 { vec![0.0; agents] } else { Vec::new() },
            sort_u32: if cfg.agent_tile > 0 { vec![0; agents * 4] } else { Vec::new() },
            sort_u16: if cfg.agent_tile > 0 { vec![0; agents] } else { Vec::new() },
            ticks_done: 0,
            cos_tab: COS_BITS.iter().map(|&b| f32::from_bits(b)).collect(),
            sin_tab: SIN_BITS.iter().map(|&b| f32::from_bits(b)).collect(),
            ns_agents: 0,
            ns_diffuse: 0,
            cfg,
        };
        s.init();
        Ok(s)
    }

    /// SPEC-1 section 3.3.
    fn init(&mut self) {
        let mut sm = self.cfg.seed ^ 0x5BF0_3635;
        for v in self.grid.iter_mut() {
            *v = rnd01(splitmix32(&mut sm)) * 100.0;
        }

        let fw = self.cfg.width as f32;
        let fh = self.cfg.height as f32;
        for i in 0..self.cfg.agents as usize {
            let mut sm_a = self
                .cfg
                .seed
                .wrapping_add(0x9E37_79B9u32.wrapping_mul(i as u32 + 1));
            let r = &mut self.arng[i * 4..i * 4 + 4];
            r[0] = splitmix32(&mut sm_a);
            r[1] = splitmix32(&mut sm_a);
            r[2] = splitmix32(&mut sm_a);
            r[3] = splitmix32(&mut sm_a);
            if r[0] | r[1] | r[2] | r[3] == 0 {
                r[0] = 1;
            }
            self.ax[i] = rnd01(xoshiro128pp(r)) * fw;
            self.ay[i] = rnd01(xoshiro128pp(r)) * fh;
            self.adir[i] = (xoshiro128pp(r) % NDIR) as u16;
        }
    }

    /// SPEC-1 section 5.2.
    /// A counting sort of the agent arrays into 8x8 tiles of the grid, so
    /// that three sensor reads of neighbouring agents land in neighbouring
    /// cache lines. impl/c/sb_core.c carries the measurement behind the tile
    /// size; this is the same algorithm, and what it is worth in Rust rather
    /// than C is the question the two rows answer.
    fn agent_sort(&mut self) {
        const TILE_SHIFT: u32 = 3; // 8x8 cells
        let n = self.cfg.agents as usize;
        let (xmask, ymask) = (self.xmask, self.ymask);
        let tw = (self.cfg.width + (1 << TILE_SHIFT) - 1) >> TILE_SHIFT;
        let th = (self.cfg.height + (1 << TILE_SHIFT) - 1) >> TILE_SHIFT;

        let mut count = vec![0u32; (tw as usize) * (th as usize) + 1];
        for j in 0..n {
            let x = (self.ax[j] as u32) & xmask;
            let y = (self.ay[j] as u32) & ymask;
            let key = (y >> TILE_SHIFT) * tw + (x >> TILE_SHIFT);
            self.sort_key[j] = key;
            count[key as usize + 1] += 1;
        }
        for t in 1..count.len() {
            count[t] += count[t - 1];
        }

        // Stable: walking the agents in their current order keeps a re-sort
        // cheap when almost nothing has moved.
        for j in 0..n {
            let key = self.sort_key[j] as usize;
            let dst = count[key] as usize;
            count[key] += 1;
            self.sort_f32[dst] = self.ax[j];
            self.sort_u16[dst] = self.adir[j];
            self.sort_u32[dst * 4..dst * 4 + 4]
                .copy_from_slice(&self.arng[j * 4..j * 4 + 4]);
            self.sort_key[j] = dst as u32; // reused as the permutation
        }
        std::mem::swap(&mut self.ax, &mut self.sort_f32);
        std::mem::swap(&mut self.adir, &mut self.sort_u16);
        std::mem::swap(&mut self.arng, &mut self.sort_u32);
        for j in 0..n {
            self.sort_f32[self.sort_key[j] as usize] = self.ay[j];
        }
        std::mem::swap(&mut self.ay, &mut self.sort_f32);
        for j in 0..n {
            self.sort_u32[self.sort_key[j] as usize] = self.aid[j];
        }
        self.aid[..n].copy_from_slice(&self.sort_u32[..n]);
        for j in 0..n {
            self.slot[self.aid[j] as usize] = j as u32;
        }
    }

    pub fn tick(&mut self) {
        // Re-sort inside the timed region, not beside it: the ordering is only
        // worth having if it pays for itself.
        if self.cfg.agent_tile > 0 && self.ticks_done % self.cfg.agent_tile == 0 {
            self.agent_sort();
        }
        self.ticks_done += 1;

        let t0 = now_ns();
        self.agent_pass();
        let t1 = now_ns();

        if self.cfg.update == Update::Deferred {
            for (g, d) in self.grid.iter_mut().zip(self.dep.iter_mut()) {
                *g += *d;
                *d = 0.0;
            }
        }

        self.diffuse_pass();
        let t2 = now_ns();

        self.ns_agents += t1 - t0;
        self.ns_diffuse += t2 - t1;
    }

    pub fn agent_params(&self) -> AgentParams {
        AgentParams {
            xmask: self.xmask,
            ymask: self.ymask,
            log2w: self.log2w,
            fw: self.cfg.width as f32,
            fh: self.cfg.height as f32,
            sdist: self.cfg.sensor_dist,
            step: self.cfg.step,
            deposit: self.cfg.deposit,
            ss: self.cfg.sensor_steps as i32,
            rs: self.cfg.rot_steps as i32,
            ndir: NDIR as i32,
            agents: self.cfg.agents as usize,
        }
    }

    /// SPEC-1 section 5.3.
    fn agent_pass(&mut self) {
        let p = self.agent_params();
        let deferred = self.cfg.update == Update::Deferred;
        let tiled = self.cfg.agent_tile > 0;

        // Disjoint field borrows; no aliasing anywhere.
        let Self {
            grid, dep, ax, ay, adir, arng, cos_tab, sin_tab, aid, agent_idx, ..
        } = self;
        let b = AgentBufs { ax, ay, adir, arng, cos_tab, sin_tab };

        if tiled {
            // With spatial ordering the step order is no longer the agent
            // order, so the deposits are buffered and applied afterwards in
            // ascending *agent* index -- the same order, and therefore the
            // same floats, as the direct loop.
            agent_loop_tiled(p, grid, aid, agent_idx, b);
            for i in 0..p.agents {
                let idx = agent_idx[i];
                *at_mut!(dep, idx) += p.deposit;
            }
        } else if deferred {
            agent_loop::<false>(p, grid, dep, b);
        } else {
            // `read` is unused when INPLACE; pass an empty slice to prove it.
            agent_loop::<true>(p, &[], grid, b);
        }
    }

    pub fn log2w(&self) -> u32 { self.log2w }

    /// Raw views the thread pool needs. Every buffer is a separate allocation,
    /// so handing them out together cannot alias.
    pub fn parts(&mut self) -> (&mut [f32], &mut [f32], &mut [f32], AgentBufs<'_>) {
        let Self { grid, scratch, dep, ax, ay, adir, arng, cos_tab, sin_tab, .. } = self;
        (grid, scratch, dep, AgentBufs { ax, ay, adir, arng, cos_tab, sin_tab })
    }

    pub fn swap_buffers(&mut self) {
        std::mem::swap(&mut self.grid, &mut self.scratch);
    }

    /// Disjoint borrows of the two grid buffers, for the vectorised kernel.
    pub fn grid_and_scratch(&mut self) -> (&[f32], &mut [f32]) {
        (&self.grid, &mut self.scratch)
    }

    /// SPEC-1 section 5.4 over rows `[y0, y1)`, scalar.
    pub fn diffuse_rows(&mut self, y0: u32, y1: u32) {
        self.stencil().run(y0, y1);
    }

    /// The stencil view over this sim's two buffers.
    pub fn stencil(&mut self) -> Stencil<'_> {
        let Self { grid, scratch, cfg, log2w, xmask, ymask, .. } = self;
        Stencil {
            src: grid,
            dst: scratch,
            w: cfg.width,
            log2w: *log2w,
            xmask: *xmask,
            ymask: *ymask,
            decay: cfg.decay,
        }
    }

    pub fn masks(&self) -> (u32, u32) { (self.xmask, self.ymask) }

    /// SPEC-1 section 5.4. Summation order is normative -- do not reorder.
    fn diffuse_pass(&mut self) {
        let h = self.cfg.height;
        if self.cfg.simd {
            crate::simd::diffuse_rows_simd(self, 0, h);
        } else {
            self.diffuse_rows(0, h);
        }
        std::mem::swap(&mut self.grid, &mut self.scratch);
    }

    // ---- checksums (SPEC-1 section 6) ------------------------------------

    pub fn hash_grid(&self) -> u32 {
        let mut h = FNV_OFFSET;
        for v in &self.grid {
            h = (h ^ v.to_bits()).wrapping_mul(FNV_PRIME);
        }
        h
    }

    pub fn hash_agents(&self) -> u32 {
        let mut h = FNV_OFFSET;
        // In agent order, which is slot order only when the arrays have not
        // been spatially re-sorted. A checksum that changed with a performance
        // flag would defeat the point of having one.
        for a in 0..self.cfg.agents as usize {
            let i = if self.slot.is_empty() { a } else { self.slot[a] as usize };
            h = (h ^ self.ax[i].to_bits()).wrapping_mul(FNV_PRIME);
            h = (h ^ self.ay[i].to_bits()).wrapping_mul(FNV_PRIME);
            h = (h ^ self.adir[i] as u32).wrapping_mul(FNV_PRIME);
        }
        h
    }

    pub fn dirtable_hash() -> u32 {
        let mut h = FNV_OFFSET;
        for &b in COS_BITS.iter().chain(SIN_BITS.iter()) {
            h = (h ^ b).wrapping_mul(FNV_PRIME);
        }
        h
    }

    /// SPEC-1 section 11. Used by the windowed frontends.
    #[allow(dead_code)]
    pub fn render_gray(&self, out: &mut [u8], display_max: f32) {
        let scale = 255.0 / display_max;
        for (o, &v) in out.iter_mut().zip(self.grid.iter()) {
            *o = ((v * scale) as i32).clamp(0, 255) as u8;
        }
    }

    pub fn variant() -> &'static str {
        if cfg!(feature = "unchecked") {
            "unchecked"
        } else {
            "safe"
        }
    }
}

/// SPEC-1 section 5.4 over rows `[y0, y1)`. Summation order is normative --
/// do not reorder. Output cells are independent, so splitting the row range
/// across threads is unconditionally bit-identical.
///
/// The two grid buffers plus the geometry the stencil needs, so the
/// single-threaded path and the thread pool run literally the same kernel.
///
/// ## Why the buffers live in a struct instead of being two parameters
///
/// This looks like pointless indirection and is worth 2.1x. Written as
/// `fn(src: &[f32], dst: &mut [f32], ...)`, LLVM gets `noalias` on both, proves
/// the stencil's reads and writes are independent, and autovectorises the loop
/// -- but the indices go through `& xmask`, so it cannot prove they are
/// contiguous and emits **gathers**. On Zen 5 that is slower than the scalar
/// loop it replaced: 290 -> 602 ms at `small`/300, reproducibly, and neither
/// `inline(always)` nor `inline(never)` changes it.
///
/// Reaching both buffers through one `&mut self` withholds that `noalias`, so
/// LLVM must assume they may alias and leaves the loop scalar -- which is
/// faster here, and is also exactly the situation the C reference is in, since
/// it passes two plain `float *` without `restrict`. Matching it is what makes
/// the cross-language numbers comparable rather than a comparison of two
/// different compiler decisions.
///
/// The vectorisation that *does* pay is the hand-written one in `simd.rs`,
/// which knows the rows are contiguous and uses unaligned loads: 4.2x, against
/// autovectorisation's 0.48x.
pub struct Stencil<'a> {
    pub src: &'a [f32],
    pub dst: &'a mut [f32],
    pub w: u32,
    pub log2w: u32,
    pub xmask: u32,
    pub ymask: u32,
    pub decay: f32,
}

impl Stencil<'_> {
    /// SPEC-1 section 5.4 over rows `[y0, y1)`. Summation order is normative --
    /// do not reorder. Output cells are independent, so splitting the row range
    /// across threads is unconditionally bit-identical.
    pub fn run(&mut self, y0: u32, y1: u32) {
        for y in y0..y1 {
            let rowm = (y.wrapping_sub(1) & self.ymask) << self.log2w;
            let row0 = y << self.log2w;
            let rowp = ((y + 1) & self.ymask) << self.log2w;

            for x in 0..self.w {
                let xm = x.wrapping_sub(1) & self.xmask;
                let xp = (x + 1) & self.xmask;

                let mut acc = at!(self.src, rowm | xm);
                acc = acc + at!(self.src, rowm | x);
                acc = acc + at!(self.src, rowm | xp);
                acc = acc + at!(self.src, row0 | xm);
                acc = acc + 4.0 * at!(self.src, row0 | x);
                acc = acc + at!(self.src, row0 | xp);
                acc = acc + at!(self.src, rowp | xm);
                acc = acc + at!(self.src, rowp | x);
                acc = acc + at!(self.src, rowp | xp);

                *at_mut!(self.dst, row0 | x) = (acc / 12.0) * self.decay;
            }
        }
    }
}

/// One agent's step: sense, turn, move, and report the cell it lands on.
/// **Applying the deposit is the caller's job** -- that is the one thing the
/// serial, deferred and threaded paths do differently, and everything else has
/// to stay identical between them. Keeping the rule in a single function is
/// what stops the parallel path drifting away from it; the C reference splits
/// it the same way (`sb_agent.h`).
///
/// `field` is what the agent senses: the grid in `deferred`, and in `serial` a
/// short-lived reborrow of the very buffer the caller is depositing into.
#[inline(always)]
#[allow(clippy::too_many_arguments)]
pub fn agent_step_one(
    p: &AgentParams,
    field: &[f32],
    ax: &mut [f32],
    ay: &mut [f32],
    adir: &mut [u16],
    arng: &mut [u32],
    cos_tab: &[f32],
    sin_tab: &[f32],
    i: usize,
) -> u32 {
    macro_rules! sense {
        ($x:expr, $y:expr, $d:expr) => {{
            let sx = wrapf($x + at!(cos_tab, $d) * p.sdist, p.fw);
            let sy = wrapf($y + at!(sin_tab, $d) * p.sdist, p.fh);
            at!(field, (((sy as u32) & p.ymask) << p.log2w) | ((sx as u32) & p.xmask))
        }};
    }

    let mut d = adir[i] as i32;
    let mut x = ax[i];
    let mut y = ay[i];

    let dl = (d - p.ss + p.ndir) % p.ndir;
    let dr = (d + p.ss) % p.ndir;

    let fl = sense!(x, y, dl);
    let fc = sense!(x, y, d);
    let fr = sense!(x, y, dr);

    if fc >= fl && fc >= fr {
        // straight on
    } else if fc < fl && fc < fr {
        if xoshiro128pp(&mut arng[i * 4..i * 4 + 4]) & 1 != 0 {
            d = (d + p.rs) % p.ndir;
        } else {
            d = (d - p.rs + p.ndir) % p.ndir;
        }
    } else if fl > fr {
        d = (d - p.rs + p.ndir) % p.ndir;
    } else {
        d = (d + p.rs) % p.ndir;
    }

    x = wrapf(x + at!(cos_tab, d) * p.step, p.fw);
    y = wrapf(y + at!(sin_tab, d) * p.step, p.fh);

    adir[i] = d as u16;
    ax[i] = x;
    ay[i] = y;

    (((y as u32) & p.ymask) << p.log2w) | ((x as u32) & p.xmask)
}

/// The agent loop. `INPLACE` selects SPEC-1's `serial` semantics, where the
/// deposit target is also the sensing source; `read` is then unused.
/// The same step, in slot order, writing each target cell to the agent's
/// original index instead of depositing. Deferred only: the tiled path is
/// refused for `serial` in the CLI, for the reason SPEC-1 5.5 gives.
fn agent_loop_tiled(
    p: AgentParams,
    read: &[f32],
    aid: &[u32],
    out: &mut [u32],
    b: AgentBufs<'_>,
) {
    let AgentBufs { ax, ay, adir, arng, cos_tab, sin_tab } = b;
    for j in 0..p.agents {
        let idx = agent_step_one(&p, read, ax, ay, adir, arng, cos_tab, sin_tab, j);
        out[aid[j] as usize] = idx;
    }
}

fn agent_loop<const INPLACE: bool>(
    p: AgentParams,
    read: &[f32],
    write: &mut [f32],
    b: AgentBufs<'_>,
) {
    let AgentBufs { ax, ay, adir, arng, cos_tab, sin_tab } = b;
    for i in 0..p.agents {
        // In-place sensing reads through a short-lived reborrow of `write`;
        // the borrow ends before the store below, so this is sound.
        let idx = if INPLACE {
            agent_step_one(&p, &*write, ax, ay, adir, arng, cos_tab, sin_tab, i)
        } else {
            agent_step_one(&p, read, ax, ay, adir, arng, cos_tab, sin_tab, i)
        };
        *at_mut!(write, idx) += p.deposit;
    }
}

pub fn now_ns() -> u64 {
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    ORIGIN.get_or_init(Instant::now).elapsed().as_nanos() as u64
}
