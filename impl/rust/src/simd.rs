//! Explicitly vectorised diffusion pass (benchmark class V).
//!
//! Same kernel and the same reasoning as `impl/c/sb_simd.h`: element-wise, one
//! output cell per lane, no cross-lane reduction, therefore conformance tier A
//! rather than tier C. No FMA, and a real division by twelve.
//!
//! ## Why this uses `core::arch` and not `std::simd`
//!
//! `std::simd` is still nightly-only. `core::arch` is stable, and it is also
//! the closer analogue to what the C and C++ targets do -- the point of this
//! target is to compare the same intrinsics expressed in three languages, not
//! to compare an intrinsic against a portable abstraction.
//!
//! ## One thing Rust makes harder than C
//!
//! The C kernel selects AVX-512 or AVX2 with `#ifdef __AVX512F__`, which
//! `-march=native` sets. Rust has `cfg!(target_feature = "avx512f")`, which
//! `-C target-cpu=native` sets the same way -- but a function using AVX-512
//! intrinsics must additionally carry `#[target_feature(enable = "avx512f")]`
//! and is then `unsafe` to call. So the dispatch is a compile-time cfg *and*
//! an unsafe call, where C needed neither.

#![allow(unsafe_op_in_unsafe_fn)]

use crate::sim::{Sim, Stencil};

/// Widest ISA compiled in.
pub fn simd_name() -> &'static str {
    if cfg!(target_feature = "avx512f") {
        "avx512f"
    } else if cfg!(target_feature = "avx2") {
        "avx2"
    } else {
        "scalar"
    }
}

pub fn simd_available() -> bool {
    cfg!(any(target_feature = "avx512f", target_feature = "avx2"))
}

/// One output cell, scalar. Used for the two wrapping columns, which the
/// vector body cannot reach with plain unaligned loads.
#[inline(always)]
fn diffuse_cell(
    src: &[f32],
    dst: &mut [f32],
    x: u32,
    rowm: u32,
    row0: u32,
    rowp: u32,
    xmask: u32,
    decay: f32,
) {
    let xm = (x.wrapping_sub(1)) & xmask;
    let xp = (x + 1) & xmask;

    let mut acc = src[(rowm | xm) as usize];
    acc = acc + src[(rowm | x) as usize];
    acc = acc + src[(rowm | xp) as usize];
    acc = acc + src[(row0 | xm) as usize];
    acc = acc + 4.0 * src[(row0 | x) as usize];
    acc = acc + src[(row0 | xp) as usize];
    acc = acc + src[(rowp | xm) as usize];
    acc = acc + src[(rowp | x) as usize];
    acc = acc + src[(rowp | xp) as usize];

    dst[(row0 | x) as usize] = (acc / 12.0) * decay;
}

#[cfg(all(target_arch = "x86_64", target_feature = "avx512f"))]
mod kernel {
    use std::arch::x86_64::*;
    pub const VW: u32 = 16;
    pub type Vec_ = __m512;
    #[inline(always)]
    pub unsafe fn load(p: *const f32) -> Vec_ { _mm512_loadu_ps(p) }
    #[inline(always)]
    pub unsafe fn store(p: *mut f32, v: Vec_) { _mm512_storeu_ps(p, v) }
    #[inline(always)]
    pub unsafe fn set1(x: f32) -> Vec_ { _mm512_set1_ps(x) }
    #[inline(always)]
    pub unsafe fn add(a: Vec_, b: Vec_) -> Vec_ { _mm512_add_ps(a, b) }
    #[inline(always)]
    pub unsafe fn mul(a: Vec_, b: Vec_) -> Vec_ { _mm512_mul_ps(a, b) }
    #[inline(always)]
    pub unsafe fn div(a: Vec_, b: Vec_) -> Vec_ { _mm512_div_ps(a, b) }
}

#[cfg(all(target_arch = "x86_64", target_feature = "avx2", not(target_feature = "avx512f")))]
mod kernel {
    use std::arch::x86_64::*;
    pub const VW: u32 = 8;
    pub type Vec_ = __m256;
    #[inline(always)]
    pub unsafe fn load(p: *const f32) -> Vec_ { _mm256_loadu_ps(p) }
    #[inline(always)]
    pub unsafe fn store(p: *mut f32, v: Vec_) { _mm256_storeu_ps(p, v) }
    #[inline(always)]
    pub unsafe fn set1(x: f32) -> Vec_ { _mm256_set1_ps(x) }
    #[inline(always)]
    pub unsafe fn add(a: Vec_, b: Vec_) -> Vec_ { _mm256_add_ps(a, b) }
    #[inline(always)]
    pub unsafe fn mul(a: Vec_, b: Vec_) -> Vec_ { _mm256_mul_ps(a, b) }
    #[inline(always)]
    pub unsafe fn div(a: Vec_, b: Vec_) -> Vec_ { _mm256_div_ps(a, b) }
}

pub fn diffuse_rows_simd(sim: &mut Sim, y0: u32, y1: u32) {
    run(&mut sim.stencil(), y0, y1);
}

/// SPEC-1 section 5.4 over rows `[y0, y1)`, vectorised.
/// Bit-identical to `sim::diffuse_rows_raw`.
#[cfg(any(target_feature = "avx512f", target_feature = "avx2"))]
pub fn run(s: &mut Stencil<'_>, y0: u32, y1: u32) {
    use kernel::*;

    let (w, log2w, xmask, ymask, decay) = (s.w, s.log2w, s.xmask, s.ymask, s.decay);

    // Narrow grids leave no vector body worth entering.
    if w < 2 * VW {
        s.run(y0, y1);
        return;
    }
    let src: &[f32] = s.src;
    let dst: &mut [f32] = s.dst;

    unsafe {
        let vfour = set1(4.0);
        let vtwelve = set1(12.0);
        let vdecay = set1(decay);

        for y in y0..y1 {
            let rowm = (y.wrapping_sub(1) & ymask) << log2w;
            let row0 = y << log2w;
            let rowp = ((y + 1) & ymask) << log2w;

            let pm = src.as_ptr().add(rowm as usize);
            let p0 = src.as_ptr().add(row0 as usize);
            let pp = src.as_ptr().add(rowp as usize);
            let out = dst.as_mut_ptr().add(row0 as usize);

            // Column 0 wraps to w-1 on the left.
            diffuse_cell(src, dst, 0, rowm, row0, rowp, xmask, decay);

            // Vector body over the interior. Same nine terms, same order, one
            // output cell per lane.
            let mut x = 1u32;
            while x + VW <= w - 1 {
                let i = x as usize;
                let mut acc = load(pm.add(i - 1));
                acc = add(acc, load(pm.add(i)));
                acc = add(acc, load(pm.add(i + 1)));
                acc = add(acc, load(p0.add(i - 1)));
                acc = add(acc, mul(vfour, load(p0.add(i))));
                acc = add(acc, load(p0.add(i + 1)));
                acc = add(acc, load(pp.add(i - 1)));
                acc = add(acc, load(pp.add(i)));
                acc = add(acc, load(pp.add(i + 1)));
                store(out.add(i), mul(div(acc, vtwelve), vdecay));
                x += VW;
            }

            // Remainder plus the wrapping last column.
            while x < w {
                diffuse_cell(src, dst, x, rowm, row0, rowp, xmask, decay);
                x += 1;
            }
        }
    }
}

#[cfg(not(any(target_feature = "avx512f", target_feature = "avx2")))]
pub fn run(s: &mut Stencil<'_>, y0: u32, y1: u32) {
    s.run(y0, y1);
}
