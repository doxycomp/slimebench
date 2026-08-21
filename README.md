# slimebench

A Physarum (slime mould) simulation in ten languages — with a verification
mechanism that proves the same simulation really is running everywhere, and a
harness for performance and footprint comparisons across languages, rendering
backends and compilers.

[![CI](https://github.com/doxycomp/slimebench/actions/workflows/ci.yml/badge.svg)](https://github.com/doxycomp/slimebench/actions/workflows/ci.yml)

| | |
|---|---|
| **What it is** | [docs/PROJECT.md](docs/PROJECT.md) |
| **Where it is going** | [docs/BUILDPLAN.md](docs/BUILDPLAN.md) |
| **The rules** | [spec/SPEC.md](spec/SPEC.md) — normative |

## Status

| Language | headless | class P | SDL2 | raylib | HUD | Conformance |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| C | ✅ | ✅ | ✅ | ✅ | ✅ | tier A (reference) |
| C++ | ✅ | ✅ | ✅ | ✅ | ✅ | tier A |
| Rust (safe + unchecked) | ✅ | ✅ | ✅ | ✅ | ✅ | tier A |
| Haskell (2 styles) | ✅ | ✅ | ✅ | ✅ | — | tier A |
| Go | ✅ | ✅ | — | — | — | tier A |
| Swift | ✅ | ✅ | — | — | — | tier A |
| Lean 4 | ✅ | — | — | — | — | tier A |
| Java | ✅ | ✅ | — | — | — | tier A |
| C# / .NET | ✅ | ✅ | — | — | — | tier A, 4 build strategies |
| OCaml | ✅ | — | — | — | — | tier A, B with `--f64-intermediates` |
| Fortran | ✅ | — | — | — | — | tier A |
| TypeScript / Node | ✅ | ✅ | — | — | — | tier A |
| TypeScript / Canvas | — | — | ✅ browser | — | sliders | tier A |
| Python / numpy | ✅ | ✅ | ✅ pygame | ✅ | — | tier A, `deferred` only |
| Python / numba | ✅ | — | — | — | — | tier A, tier C with `--fastmath` |
| Python / pure | ✅ | — | — | — | — | tier B, A with `--strict-f32` |
| Perl | ✅ | ✅ | ✅ | ✅ | — | tier B, A with `--strict-f32` |

Plus two GPU hosts that are not languages of their own: CUDA and GLSL compute
(the latter driven from C and from Python, out of the same shader source).

Every number in [docs/RESULTS.md](docs/RESULTS.md) comes from one series on one
machine in one sitting. Numbers from two series are not comparable, and the
document does not mix them.

**All fourteen languages pass `bench/run.py conformance`.** Most are bit-exact
against the C reference on both the grid *and* the agent checksum, across
`micro`/`tiny`/`small` × `serial`/`deferred` × tick counts {1, 10, 100, 1000},
plus one case built to catch a fused multiply-add. Perl and pure Python reach
bit-exactness with `--strict-f32`; OCaml is exact by default and offers the
inexact mode as a measurement. Python also reaches tier A with no flag at all
once the same loops go through numba, which is a finding in itself.

Measurements: [docs/RESULTS.md](docs/RESULTS.md).

The same simulation, `medium` (2048², 1 M agents), 100 ticks:

![Class overview](docs/charts/classes.svg)

| Class | best configuration | ms | vs. 1 CPU core |
|---|---|---:|---:|
| S — one thread | C, gcc `-O3 -march=native` | 4391 | 1× |
| P — 32 threads | **Go**, `binned` | 516 | **8.5×** |
| G — GPU | CUDA, RTX 5080 | **44** | **100×** |

Class P exists in nine of the ten languages, every one of them bit-identical
to the serial run — and it is won by neither C nor C++, but by Go:

![Scaling across languages](docs/charts/scaling-langs.svg)

Every number comes from **one** run over the whole matrix. First check what
the machine can actually measure:

```bash
bench/preflight.sh
```

Then measure — on WSL2 after staging onto the Linux filesystem, natively
straight away:

```bash
scripts/stage-wsl.sh && bench/full-run.sh    # WSL2
bench/full-run.sh                            # native Linux
```

The run detects WSL versus native Linux itself and sets the D3D12 environment
variables only where they belong; with no display it skips class R rather than
inventing a number.

## Quick start

The canonical environment is WSL2 / Ubuntu. All you need is `gcc`, `make` and
`node` — `scripts/setup-wsl.sh` installs the rest on demand.

Build and run the C reference:

```bash
make -C impl/c CC=gcc PROFILE=o2 headless && ./impl/c/build/gcc-o2/slimebench-headless --preset small --ticks 600
```

The same thing in TypeScript, with an identical result:

```bash
node --experimental-strip-types impl/ts/src/main-node.ts --preset small --ticks 600
```

Check that every implementation agrees:

```bash
python3 bench/run.py conformance
```

CI runs the same gate on every push, over the subset a GitHub runner can host
without installing a toolchain — C, C++, Rust, Go, TypeScript, Python and Perl,
under both gcc and clang. It also re-runs the three code generators and fails
if their output differs from what is committed. It deliberately measures no
performance: a shared runner varies by more than most of the effects in
[docs/RESULTS.md](docs/RESULTS.md), and a benchmark you cannot trust is worse
than no benchmark.

Install further toolchains (in phases: `base`, `render`, `rust`, `haskell`, `scripting`, `gpu`):

```bash
scripts/setup-wsl.sh all
```

Benchmark (from the Linux filesystem, or you are measuring the 9p bridge):

```bash
scripts/stage-wsl.sh bench --preset medium --reps 3
```

Parallel (class P, `deferred` only) — `binned` is bit-identical to the serial run:

```bash
./impl/c/build/gcc-o3-native/slimebench-headless --preset medium --ticks 100 --update deferred --threads 16 --deposit-reduce binned
```

Interactive in the browser, with sliders for every parameter:

```bash
cd impl/ts && npm install && npm run build:web && python3 -m http.server 8765 --directory ../web
```

Graphical C frontend (SDL2, runs under WSLg):

```bash
make -C impl/c CC=gcc PROFILE=o3-native sdl2 && ./impl/c/build/gcc-o3-native/slimebench-sdl2 --preset browser --render
```

The window carries an overlay with a tick counter, timings and every
parameter. `h` shows the key map, `Tab` hides the overlay, `space` pauses, `n`
advances one tick, `r` restarts, `c` writes the checksums to stderr.
Parameters sit on digit pairs rather than letter-plus-shift, because SDL2,
raylib, GLFW and the browser each report shift state differently — `1`/`2`
deposit, `3`/`4` decay, `5`/`6` sensor distance, `7`/`8` step length, `9`/`0`
rotation steps.

The moment a parameter is changed, the HUD marks the run `EDITED`: it has left
the SPEC-1 configuration and its checksums no longer reproduce anything. Under
`--json` the overlay is off, and its drawing time is subtracted from the
class R measurement in any case.

Hand-written AVX-512 diffusion kernel instead of the intrinsics (class V):

```bash
make -C impl/c CC=clang PROFILE=o3-native ASM=1 headless && ./impl/c/build/clang-o3-native-asm/slimebench-headless --preset medium --ticks 100 --update deferred --asm
```

CPython without the GIL against CPython with it, same worker, same phases:

```bash
bench/gil-matrix.sh results/P-gil-matrix.jsonl small 100
```

The same loops interpreted and JIT-compiled, plus what `--fastmath` breaks:

```bash
bench/numba-jit.sh results/S-numba-jit.txt
```

The JVM's warm-up ramp, and its interpreter against CPython's:

```bash
bench/jvm-warmup.sh results/S-jvm-warmup.txt
```

The same C# source through a JIT and ahead of time:

```bash
bench/dotnet-aot.sh results/S-dotnet-aot.txt
```

## The interesting details

- **Why bit-exactness is possible at all.** `sin`/`cos` are not bit-identical
  between glibc, V8 and GPU drivers, and Physarum is chaotic enough that 1 ULP
  shows up within 200 ticks. So agent headings are quantised to integers and
  the trig table is generated into every language as u32 bit patterns.
  Details: [SPEC §4](spec/SPEC.md).
- **Why JavaScript still reaches tier A.** `Math.fround(f64_op(a,b))` is
  provably identical to the f32 operation for `+ − × ÷`, because `53 ≥ 2·24+2`.
- **Why there are two update modes.** The reference mode `serial` lets an agent
  see the deposits of its predecessors within the same tick — faithful, but not
  deterministically parallelisable even in principle. `deferred` resolves that
  and is the basis of every parallel, SIMD and GPU variant.
- **Why numpy can only do `deferred`.** `serial` has a sequential dependency
  through the grid that cannot be vectorised. The implementation refuses the
  mode with a clear message rather than quietly computing something else — see
  the docstring in
  [slimebench_numpy.py](impl/python/slimebench_numpy.py).
- **What bounds checking costs in Rust.** A third in the diffusion pass,
  nothing measurable in the agent pass. See
  [docs/RESULTS.md §3](docs/RESULTS.md#3-compilers).
- **Why SIMD and GPU are not tier C here.** The vectorised stencil does no
  cross-lane reduction, and CUDA counts deposits as integers instead of adding
  them in f32. Both are bit-exact against the C reference — the spec originally
  assumed the opposite.
- **Why there are two reduction strategies for threads.** Thread-local deposit
  buffers are reproducible only *per thread count*, not bit-identical to the
  serial run. The spatially binned variant is — and from eight threads onward
  it is also faster. See [SPEC §5.6](spec/SPEC.md).
- **Why gcc wins at `-O2` and clang needs `-march=native`.** At `-O2` gcc is
  11 % faster; with `-march=native` clang is 15 % faster. Read one row of the
  matrix and you get the wrong answer. See
  [docs/RESULTS.md §3](docs/RESULTS.md#3-compilers).
- **Why `-Ofast` costs clang half its speed** while on gcc the effect is small
  enough to change sign between runs — the same flag, the same loop, and only
  one of the two compilers is actually affected.
- **What hand-written assembly still buys once the intrinsics exist.** About
  11 %, and not through better instructions but through fewer loads: the
  intrinsics kernel reads each row three times per output vector, the
  hand-written one reads it once and manufactures the shifted views with
  `VALIGND`. Side effect: the torus wrap becomes free, because it turns into a
  single `AND`. [impl/asm/sb_diffuse_avx512.S](impl/asm/sb_diffuse_avx512.S).
- **What the GIL costs.** With the same worker and the same phases, CPython
  3.12 with threads does not merely fail to scale — at 16 threads it is
  **7.3× slower** than with one. Without the GIL the same configuration is
  2.7× *faster*, and threads then beat processes wherever the reduction has
  many phases. [bench/gil-matrix.sh](bench/gil-matrix.sh).
- **What the interpreter actually costs.**
  [slimebench_numba.py](impl/python/slimebench_numba.py) is
  [slimebench_pure.py](impl/python/slimebench_pure.py) with `@njit` on the
  kernels — same loops, same order, same names — so the ratio between them is
  CPython and nothing else. Tier A against tier A it is **341×**, and what
  remains after the interpreter is 7 %: numba runs the identical source at
  1.07× of gcc `-O2`, and 4.4× *faster* than the hand-vectorised numpy target.
  Exactness inverts too — pure Python pays 2.2× for tier A, numba gets it free,
  because `float32` is a real type there.
- **What `--fastmath` breaks, and which checksum notices.** The grid hash
  diverges on tick 1. The agent hash keeps saying "conformant" for 400 ticks,
  because agent positions are exact by construction and only move once a low
  bit flips a comparison. A gate that hashed only the agents would have
  certified a fast-math build. [docs/RESULTS.md §2](docs/RESULTS.md#2-language-comparison-class-s).
- **Two of the spec's claims are proved, not just tested.** `binned` is
  bit-identical to the serial run — §5 checks that by running eight thread
  counts in ten languages; [impl/lean/Proofs/](impl/lean/Proofs) proves it for
  *every* thread count and every partition. And the bit-masked torus index is
  the modulo index, always inside the grid, and injective. Neither proof
  mentions floating point: Lean has no axioms about `Float32` at all, so the
  claim is restated as one about the *order* of operations, which then holds
  for any operation — f32 addition included. `lake build` checks them and CI
  greps for `sorryAx`.
- **What ahead-of-time compilation is worth.** .NET compiles the same source
  four ways, two of them on opposite sides of the JIT/AOT line — the only
  target here that can be asked. Native AOT lands **within 3 %** of the
  optimising JIT running with a full run's profile behind it, starts seven
  times faster, and has no ramp: 2.0× from first tick to best, where the JVM's
  is 26.3×. [docs/RESULTS.md §6](docs/RESULTS.md#6-warm-up-and-what-ahead-of-time-compilation-is-worth).
- **That "interpreted" is not one performance class.** The JVM can be pinned to
  its interpreter with `-Xint`, which makes it directly comparable to CPython
  on the identical algorithm at the identical conformance tier. **CPython is
  15.6× slower** — a bigger gap than the one between the JVM's interpreter and
  optimised C.
- **What exactness costs where there is no `float32`.** OCaml 4.14 has an
  unboxed `float array` and no single-precision type, so tier A means rounding
  through `Int32.bits_of_float`. That is not the boxing it looks like: the
  allocation count is identical either way, and the assembly shows **22 calls
  per cell** into the runtime. It costs 5.5×, and Lean — which boxes every
  element but has a native `Float32` — comes out ahead of it.
- **A conformance gate that could not fail.** gfortran with
  `-ffp-contract=fast` emits thirteen f32 FMAs into the agent pass and still
  matched the reference on every case, because the default `--step` is 1.0 and
  multiplying by a power of two is exact. No port in this project could have
  failed for letting its compiler fuse. The suite now has a case that can.
- **What a proof assistant does with a mutable-array workload.** Lean 4
  lands at 8.9× C, between TypeScript and pure Python — and gets there in
  native `Float32`, because Lean's is IEEE binary32 (verified against
  `round_f32(f64_op(a,b))` over 50 000 pairs). Its arrays are copy-on-write
  with refcounting, so a write loop is O(n), not O(n²).
  [impl/lean/Slimebench/Sim.lean](impl/lean/Slimebench/Sim.lean).
- **Everything that did not work.** PGO, the parallel prefix sum, the load
  balancer, the pure spin barrier — four plausible optimisations, one usable
  result. With reasoning in
  [docs/RESULTS.md §11](docs/RESULTS.md#11-what-did-not-work).

## Provenance

Model after Jeff Jones (2010), *Characteristics of pattern formation and
evolution in approximations of Physarum transport networks*. The starting
point for the parameters and the setup was
[programmingchaos.dev](https://www.programmingchaos.dev/physarum-simulations-programming-slime-molds/).
