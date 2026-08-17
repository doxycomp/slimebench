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
    pub sensor_dist: f32,
    pub step: f32,
    pub deposit: f32,
    pub decay: f32,
    pub sensor_steps: u32,
    pub rot_steps: u32,
    pub simd: bool,
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
            sensor_dist: 9.0,
            step: 1.0,
            deposit: 10.0,
            decay: 0.94,
            sensor_steps: 144,
            rot_steps: 144,
            simd: false,
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
struct AgentParams {
    xmask: u32,
    ymask: u32,
    log2w: u32,
    fw: f32,
    fh: f32,
    sdist: f32,
    step: f32,
    deposit: f32,
    ss: i32,
    rs: i32,
    ndir: i32,
    agents: usize,
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
    pub fn tick(&mut self) {
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

    /// SPEC-1 section 5.3.
    fn agent_pass(&mut self) {
        let p = AgentParams {
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
        };

        // Disjoint field borrows; no aliasing anywhere.
        let Self {
            grid, dep, ax, ay, adir, arng, cos_tab, sin_tab, ..
        } = self;

        if self.cfg.update == Update::Deferred {
            agent_loop::<false>(p, grid, dep, ax, ay, adir, arng, cos_tab, sin_tab);
        } else {
            // `read` is unused when INPLACE; pass an empty slice to prove it.
            agent_loop::<true>(p, &[], grid, ax, ay, adir, arng, cos_tab, sin_tab);
        }
    }

    pub fn log2w(&self) -> u32 { self.log2w }

    /// Disjoint borrows of the two grid buffers, for the vectorised kernel.
    pub fn grid_and_scratch(&mut self) -> (&[f32], &mut [f32]) {
        (&self.grid, &mut self.scratch)
    }

    /// SPEC-1 section 5.4 over rows `[y0, y1)`, scalar. Output cells are
    /// independent, so splitting the range is unconditionally bit-identical.
    pub fn diffuse_rows(&mut self, y0: u32, y1: u32) {
        let w = self.cfg.width;
        let log2w = self.log2w;
        let xmask = self.xmask;
        let ymask = self.ymask;
        let decay = self.cfg.decay;
        let src = &self.grid;
        let dst = &mut self.scratch;

        for y in y0..y1 {
            let rowm = (y.wrapping_sub(1) & ymask) << log2w;
            let row0 = y << log2w;
            let rowp = ((y + 1) & ymask) << log2w;

            for x in 0..w {
                let xm = x.wrapping_sub(1) & xmask;
                let xp = (x + 1) & xmask;

                let mut acc = at!(src, rowm | xm);
                acc = acc + at!(src, rowm | x);
                acc = acc + at!(src, rowm | xp);
                acc = acc + at!(src, row0 | xm);
                acc = acc + 4.0 * at!(src, row0 | x);
                acc = acc + at!(src, row0 | xp);
                acc = acc + at!(src, rowp | xm);
                acc = acc + at!(src, rowp | x);
                acc = acc + at!(src, rowp | xp);

                *at_mut!(dst, row0 | x) = (acc / 12.0) * decay;
            }
        }
    }

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
        for i in 0..self.cfg.agents as usize {
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

/// The agent loop. `INPLACE` selects SPEC-1's `serial` semantics, where the
/// deposit target is also the sensing source; `read` is then unused.
#[allow(clippy::too_many_arguments)]
fn agent_loop<const INPLACE: bool>(
    p: AgentParams,
    read: &[f32],
    write: &mut [f32],
    ax: &mut [f32],
    ay: &mut [f32],
    adir: &mut [u16],
    arng: &mut [u32],
    cos_tab: &[f32],
    sin_tab: &[f32],
) {
    // Reading through a short-lived reborrow of `write` is sound; the borrow
    // ends before the next store.
    macro_rules! cell {
        ($i:expr) => {{
            let _idx = $i;
            if INPLACE {
                at!(write, _idx)
            } else {
                at!(read, _idx)
            }
        }};
    }
    macro_rules! sense {
        ($x:expr, $y:expr, $d:expr) => {{
            let sx = wrapf($x + at!(cos_tab, $d) * p.sdist, p.fw);
            let sy = wrapf($y + at!(sin_tab, $d) * p.sdist, p.fh);
            cell!((((sy as u32) & p.ymask) << p.log2w) | ((sx as u32) & p.xmask))
        }};
    }

    for i in 0..p.agents {
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

        let idx = (((y as u32) & p.ymask) << p.log2w) | ((x as u32) & p.xmask);
        *at_mut!(write, idx) += p.deposit;

        adir[i] = d as u16;
        ax[i] = x;
        ay[i] = y;
    }
}

pub fn now_ns() -> u64 {
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    ORIGIN.get_or_init(Instant::now).elapsed().as_nanos() as u64
}
