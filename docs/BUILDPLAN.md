# Build plan

The order is not arbitrary. It follows two rules:

1. **Spec and verification first.** Every port is checked against reference
   checksums before it is measured. A port without a green conformance run is
   not a data point, it is a source of error.
2. **Finish the language axis (class S) before parallelism.** Parallelise only
   once every language stands single-threaded — otherwise you end up comparing
   thread pools instead of languages.

Status: ✅ done · 🔨 next · ⬜ open

> The numbers inside each phase are the ones that were measured **when that
> phase was done**, and they are left as they were: this file is a record of
> how the project got here. For current figures — all from one series — see
> [RESULTS.md](RESULTS.md).

---

## Phase 0 — Foundation ✅

- ✅ `spec/SPEC.md` — the normative specification
- ✅ direction-table codegen (`spec/tools/gen_dirtable.py`)
- ✅ `bench/run.py` — build, measurement, conformance, report
- ✅ `bench/targets.toml` — registry of language × compiler × profile
- ✅ `scripts/setup-wsl.sh`, `scripts/stage-wsl.sh`
- ✅ reference vectors `spec/testvectors/SPEC-1.json`

## Phase 1 — Reference implementations ✅

- ✅ **C headless** — the normative reference. All vectors are generated from it.
- ✅ **C + SDL2** — windowed frontend, shared core
- ✅ **TypeScript** — core + Node headless
- ✅ **HTML5 canvas** — interactive frontend with parameter sliders
- ✅ Demonstrated: C / Node / Chrome byte-identical after 300 ticks

**What that establishes:** the spec is implementable and bit-exact across
languages. Everything else depends on it.

---

## Phase 2 — The compiled languages ✅

- ✅ **C++** — idiomatic (`std::vector`, `std::bit_cast`, RAII), not a C
  transliteration. Bit-exact.
- ✅ **Rust** — two variants behind a cargo feature: `safe` and `unchecked`.
  Both bit-exact.
- ✅ **Haskell** — two styles, both bit-exact and checked against each other:
  `IOUArray` in `IO` with `unsafeRead`/`unsafeAt`, and an idiomatic version
  over immutable `Data.Vector.Unboxed`. The comparison is in
  [RESULTS.md §4](RESULTS.md#4-how-much-programming-style-matters-haskell) —
  among other things, that four characters (`(!)` → `unsafeAt`) were worth
  1.46×.
- ✅ Conformance gate green.

---

## Phase 3 — The scripting languages ✅

- ✅ **Pure Python** — tier B by default, tier A with `--strict-f32`
  (demonstrably bit-exact, surcharge 2.2×).
- ✅ **Python numpy** — tier A, but **`deferred` only**: `serial` has a
  sequential dependency through the grid. The implementation refuses the mode
  with a clear message. The vectorised xoshiro advance (only dead-end agents
  may step their stream) and `np.add.at` reproduce the spec semantics exactly.
- ✅ **Perl** — tier B by default, tier A with `--strict-f32` (surcharge 3.3×).
- ✅ **Tolerant conformance gate** — metrics instead of hashes, separated into
  conserved quantities (1e-6) and structure-sensitive ones (2e-2).
- ✅ **Python numba** — tier A with no strictness flag, and tier C on the
  `fastmath` profile from the same source. Deliberately a line-for-line copy of
  the pure-Python target so the pair isolates the interpreter: 341× tier A
  against tier A, and 1.07× of gcc `-O2` once it is gone.

---

## Phase 4 — Rendering backends ✅

Both backends receive exactly the same greyscale buffer; `--freeze-sim` halts
the simulation so that only the upload path grid → texture → screen is
measured.

| Language | SDL2 | raylib |
|---|---|---|
| C | ✅ | ✅ |
| C++ | ✅ | ✅ |
| Rust | ✅ `sdl2` crate | ✅ `raylib` crate |
| Haskell | ✅ `sdl2` | ✅ `foreign import` + shim |
| Python | ✅ `pygame` | ✅ `raylib-python-cffi` |
| Perl | ✅ `FFI::Platypus` | ✅ `FFI::Platypus` + shim |

For Haskell/raylib and Perl/raylib the tree deliberately does not use the
ecosystem package: `h-raylib` and the Perl raylib distributions vendor raylib
and build their own copy, which would compare a language against a *different
build* of the library. Both bind the same `/usr/local/lib/libraylib.so` as
everyone else — and both hit the same limit, because raylib passes `Image`,
`Texture2D` and `Color` by value. The five affected calls share
[`impl/shim/raylib_shim.c`](../impl/shim/raylib_shim.c).

raylib wins everywhere, on the GPU by over 2×. It is the pixel format, not the
library: raylib takes the 8-bit greyscale buffer directly, SDL2 needs ARGB8888
and therefore an expansion loop over a million pixels per frame.

The actual finding, though, is that **the four compiled languages land within
10 % of each other on raylib**. Once the backend is fixed, the language barely
matters in this class — unlike in class S. And SDL2 is *slower* on the real GPU
than on the software rasteriser, in all four: both paths are CPU-bound at
1024². Details in [RESULTS.md §9](RESULTS.md#9-rendering-class-r).

---

## Phase 5 — Compiler matrix ✅

The stated main goal. Fully automated through `bench/run.py bench`.

| Axis | Values |
|---|---|
| C | gcc, clang |
| C++ | g++, clang++ |
| Rust | rustc (LLVM), optionally `-Zbuild-std` |
| Haskell | GHC NCG vs. the LLVM backend (`-fllvm`) |
| Go | default vs. `-gcflags=all=-B` |
| Swift | `release` vs. `-Ounchecked` |
| Profiles | `-O0 -O1 -O2 -O3 -Os`, `-march=native`, LTO, PGO, `-Ofast` |

**PGO was measured and buys nothing** — on clang it costs 6 %. The four-way
branch on the sensor values is data-dependent and close to uniformly
distributed; PGO can only improve *predictable* branches. The guess at this
point was wrong. Details in
[RESULTS.md §11](RESULTS.md#11-what-did-not-work).

---

## Phase 6 — Parallelism ✅

`deferred` update mode only (SPEC §5.5) — `serial` cannot be deterministically
parallelised in principle.

**The determinism rule in the first version was wrong.** It required
thread-local buffers with a fixed reduction order and called that
deterministic. That only delivers reproducibility *per thread count*:
`(Σ thread 0) + (Σ thread 1) + …` is a different parenthesisation from the
serial chain. SPEC §5.6 now distinguishes two strategies, and both are
measured.

| Language | Approach | Status |
|---|---|---|
| C | pthreads, `binned` + `private` | ✅ |
| C++ | `std::jthread` + `std::barrier`, both strategies | ✅ |
| Rust | `std::thread::scope`, both strategies | ✅ |
| Go | goroutines + `sync.Cond` barrier, both strategies | ✅ |
| Swift | `Foundation.Thread` + `NSCondition`, both strategies | ✅ |
| TypeScript | `worker_threads` + `SharedArrayBuffer`, both strategies | ✅ |
| Haskell | `forkOn` + `-threaded`, MVar barrier, both strategies | ✅ |
| Python | `multiprocessing` + `shared_memory`, and threads (phase 11) | ✅ |
| Perl | `fork` + pipes, replicated reduction | ✅ |

**Every port is bit-identical to its own serial run**, and the ones using the
`private` strategy even produce the same *wrong* hash (`0xE82B2012`) at
`--deposit 0.1` and T=4.

**Perl needed a design of its own.** `threads::shared` costs 7.6× per random
read-modify-write on this machine; the diffusion stencil reads nine cells per
output cell, so a shared grid could never win. Pushing a whole block through
`pack`/`unpack`, by contrast, costs about as much as *one* traversal of a
normal array. So: `fork` with private grids and packed binary over pipes — and
a third reduction strategy, **replicated**, that SPEC §5.6 does not define:
every process applies every deposit in ascending agent index, which is exactly
the serial chain. Bit-identical for any process count without the `binned`
sort, at the price of running the deposit and merge passes N times.

**Barriers are the bottleneck**, not work distribution: 35 % of the runtime at
T=16, 53 % at T=32. A spinning barrier gains 7 % there but costs 55 % at 32
threads (the spinners take execution resources from their SMT siblings). The
hybrid variant — spin, then park on a futex — is never worse than `pthread` and
is selected through `SLIMEBENCH_BARRIER`. The gain stays small, because the
time is in the *waiting*, not in the waking.

---

## Phase 7 — SIMD ✅ (C, C++, Rust)

| Language | Status |
|---|---|
| C | ✅ AVX2 + AVX-512 for the diffusion pass, `--simd` |
| C++ | ✅ the same intrinsics |
| Rust | ✅ `core::arch` (not `std::simd`, which is nightly-only) |
| Haskell, Python, Perl, TS | — no honest route; documented as such |

**The assumption "reordered reduction ⇒ tier C" was wrong.** The kernel has no
cross-lane reduction; each lane computes one output cell with the same
operation sequence as the scalar loop. The result is bit-identical —
demonstrated under gcc and clang, in both update modes, and combined with 16
threads. Conditions: no FMA, a real division. See SPEC §8.1.

**Result:** the diffusion pass is 4.5× faster (AVX-512), 1.25× overall on one
thread. But AVX2 at half the lane count reaches 4.3× — doubling the vector
width buys only 10–18 %, because the stencil is bandwidth-bound. And combined
with eight threads, SIMD buys **nothing** at all, because both attack the same
resource.

The agent pass stays scalar: several agents per vector depositing into the same
cell would need conflict resolution, and that really would be tier C.

---

## Phase 8 — GPU ✅ (CUDA + OpenGL)

| Route | Status |
|---|---|
| CUDA | ✅ **conformance tier A**, 100× against one CPU core |
| GLSL 4.3 compute | ✅ tier A on llvmpipe, ~2 ULP off on D3D12/NVIDIA |
| WGSL via wgpu-native | ❌ not viable, see below |

**The originally recommended route does not work under WSL2.** Vulkan does not
see the NVIDIA GPU: the ICD files under `/usr/lib/wsl/drivers/` point at
`nvoglv64.dll`, i.e. Windows drivers that cannot be loaded from Linux. That
rules out wgpu-native, and with it the WGSL idea of "one shader source for
everything".

Two routes are viable instead, and both are implemented:

* **CUDA** — NVIDIA only, but officially supported under WSL2 and the fastest.
  The toolkit here (12.0) does not know Blackwell; compiling to PTX for
  `compute_90` and letting the driver JIT works.
* **OpenGL 4.3 compute** — reaches the RTX 5080 through Mesa's D3D12 backend
  (`GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA`) and runs from
  any language that can get a GL context. That is closer to the original goal
  than wgpu would have been.

**The assumption "class G is necessarily tier C" was wrong** — for CUDA at
least. It needs `-fmad=false`, correctly rounded division and integer deposit
atomics instead of `atomicAdd(float*)`. Details in SPEC §8.2 and
[RESULTS.md §8](RESULTS.md#8-gpu-class-g).

---

## Phase 9 — Evaluation ✅

[`docs/RESULTS.md`](RESULTS.md) is organised thematically rather than
chronologically: an overall table across all classes first, then one section
per class, footprint, negative results, and a list of the places where the spec
or this build plan was refuted by measurement.

`bench/charts.py` generates SVGs into `docs/charts/`. Hand-written SVG rather
than matplotlib: the rest of the repo builds with nothing but the toolchains
under test, and a chart generator is a poor reason for the first Python
dependency. Side effect: the output is diffable, which matters when the charts
are checked in.

```bash
python3 bench/charts.py
```

**Addendum.** The numbers in the document had accumulated over a dozen sessions
on different days — harmless within a series, quietly misleading across series,
and the document drew several cross-series comparisons. There is now

```bash
bench/full-run.sh
```

which measures every class in one go into `results/run-<date>/` and writes the
toolchain versions and the commit alongside, plus `bench/tables.py` which
generates the markdown tables from it. Every number in RESULTS.md has come from
one run since.

---

## Phase 10 — Scale and a second GPU host ✅

- ✅ A `huge` preset (8192², 16.8 M agents) — because `medium` does not
  saturate an RTX 5080, which makes the measured speedup a lower bound rather
  than an answer.
- ✅ A second GLSL host, in Python, over the same shader source. Both hosts
  print an FNV-32 of their compiled shader; they agree, so class G demonstrably
  measures the driver rather than the host language.
- ✅ `bench/preflight.sh` — report what a machine can actually measure before a
  two-hour run discovers it.

The phase also produced the worst bug in the project so far:
`glDispatchCompute` is limited to 65 535 workgroups per dimension, `medium`
needs 65 536, and the driver reports nothing. The diffusion pass simply did not
run, and the resulting number was plausible. See
[RESULTS.md §12](RESULTS.md#12-where-i-was-wrong).

---

## Phase 11 — More languages, more of class V, and a HUD ✅

- ✅ **Go** — tier A. Notable because the ban on FMA is enforced by the
  language rather than a flag: `acc + float32(4.0*src[i])` forbids the fusion
  because the conversion is a guaranteed rounding point. Wins class P.
- ✅ **Swift** — tier A, and needs nothing at all: it does not contract by
  default.
- ✅ **Free-threaded CPython** — the class P pool grew a `threads` backend, so
  3.12-with-GIL and 3.14t-without can be measured against each other with
  everything else held fixed. [RESULTS.md §6](RESULTS.md#6-what-the-gil-costs-cpython-314t).
- ✅ **Hand-written AVX-512** — `impl/asm/sb_diffuse_avx512.S`, a different
  memory strategy rather than a transliteration of the intrinsics.
  [RESULTS.md §7](RESULTS.md#7-simd-and-hand-written-assembly-class-v).
- ✅ **HUD and keyboard control** on six native frontends plus the browser, out
  of one shared bitmap font.

---

## Phase 12 — Lean 4 ✅

The tenth language, and the one whose blocker turned out not to exist. The
open item used to read "blocked on which of three near-identical array idioms
the compiler turns into a destructive update". The arithmetic refutes it: at
7.9 ns per element on an 8 M array, a copying `set!` would be years of work.
Every idiom was already destructive, because Lean's arrays are copy-on-write
with refcounting.

Three things were measured before a line of the port was written, which is the
only reason it landed bit-exact on the first run:

- write loops are O(n) — confirmed by running the same fill at n and 4n and
  reading the ratio, which was 3.5 to 4.9, not 16;
- `Float32` is IEEE binary32 — 50 000 pairs against `round_f32(f64_op(a,b))`,
  zero mismatches, and `0.94` gives `0x3F70A3D7`;
- the representation barely matters — `Array UInt32` of bit patterns, which
  should have beaten the boxing in `Array Float32`, measured 13.2 against
  12.8 ns/cell, inside a 25 % run-to-run spread.

Tier A on the full conformance set. 8.9× C at 256², class S only.

Class P was then measured and declined. Lean has `Task` and `IO.asTask`, so
the machinery exists, but its arrays are reference-counted: two tasks holding
one destination buffer would each copy it. Three ownership shapes were
measured, all bit-exact, and with the natural `Array Float32` every one of them
is *slower* than serial at every thread count — a shared array is marked
multi-threaded and its boxed elements are then reference-counted atomically,
nine times per cell. Storing bit patterns in an `Array UInt32` removes that and
reaches 1.52× at eight tasks, but costs 19 % serially, so the end-to-end win is
1.27× against 6.8–9.5× elsewhere. The experiment stays in the tree as
`bench/lean-tasks.sh`; the target stays class S. Reasoning in
[RESULTS.md §2](RESULTS.md#2-language-comparison-class-s).

## Open

- **A native Linux GL driver.** The GL numbers include Mesa's D3D12
  translation; constant throughput across four orders of magnitude says that
  layer, not the GPU, is the bottleneck.
- **Class R at a grid size that saturates the GPU.**
- **Why Go wins class P.** The explanation in RESULTS §5 is plausible and
  unmeasured, and that category has a poor record.
- **The HUD in Haskell, Perl and Python.** The 5×7 font is deliberately data in
  a header so a port can adopt it.
- **CI.** `.github/workflows/` builds the C reference and runs the conformance
  gate on every push; extending it to more toolchains is a matter of runner
  minutes, not design.

## Deliberately out of scope

So that the project can end:

- Still more languages (Zig, Java, C#). The spec makes ports cheap — Go and
  Swift took an afternoon each — but the matrix is large enough that each new
  one costs more in measurement time than it adds in insight.
- Distributed / multi-node.
- A different Physarum model (multiple species, food sources, 3D). Appealing,
  but a different simulation and therefore a different spec.
