# CUDA — and why a GPU can still be bit-exact

**What class G measures is not the language.** The host code here allocates
buffers and launches three kernels; Rust or Python would produce the same
numbers. This target is the ceiling for the problem on this hardware, and the
report says so rather than letting it read as a language result.

SPEC-1 §8 originally assumed GPU work lands in conformance tier C. Three things
have to hold for that assumption to be wrong, and all three do here:

1. **The diffusion pass** is element-wise with a fixed summation order, one
   output cell per thread — the same argument as the SIMD kernel (§8.1). It
   needs `-fmad=false` to stop nvcc contracting `4.0f*c + acc` into an FMA, and
   the default precise division for `/12.0f`.
2. **The agent pass** is per-agent and reads a read-only grid in `deferred`
   mode. The PRNG, the direction table and the wrap arithmetic are integer or
   exact-f32 operations that CUDA implements to IEEE rules.
3. **The deposits** are the hard part. `atomicAdd(float*)` is the obvious
   choice and is *not* deterministic — the order threads land decides the
   rounding. Instead `atomicAdd(unsigned*)` counts hits per cell, which is
   exact and order-independent, and the multiplication by `deposit` happens
   once afterwards.

Point 3 carries the same limitation as the CPU `private` strategy: it works
because SPEC-1's deposit is a constant. With a deposit that depends on the
agent, CUDA diverges too — checked, not assumed.

Verified against the C reference at all five presets, grid **and** agent hash.

## Targets

<!-- sb:impl targets -->
| Target | Class | Backend | Compilers | Profiles |
|---|:-:|---|---|---|
| `cuda` | G | cuda | nvcc | `default` |
<!-- /sb:impl -->

## Files

<!-- sb:impl files -->
| File | Lines | What |
|---|---:|---|
| `slimebench.cu` | 466 | CUDA implementation of SPEC-1 (benchmark class G) |
| `Makefile` | 54 | CUDA implementation (benchmark class G) |
<!-- /sb:impl -->

## Reading order

One file. The header is the argument above; the three kernels follow it.

## Building

```bash
make -C impl/cuda PROFILE=default
```

Class G is [docs/RESULTS.md](../../docs/RESULTS.md) §9, which also has what
CUDA does and does not tell you about the machine.
