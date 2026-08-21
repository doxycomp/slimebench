# Results

Every number in this document comes from **one** run,
[`results/run-20260820-0330/`](../results/run-20260820-0330/), commit
`41bdcc0`, produced by a single invocation of:

```bash
bench/full-run.sh
```

The one-run rule is the answer to a mistake in earlier versions of this file:
the numbers had accumulated over a dozen sessions on different days. Inside one
series that is harmless; across series it is quietly misleading. The tables are
generated from the result directory with `bench/tables.py` and the charts from
the same directory with `bench/charts.py` — nothing here is typed by hand.

```
cpu     AMD Ryzen 9 9950X3D  (16C/32T, Zen 5, 128 MB L3)
gpu     NVIDIA RTX 5080 (84 SMs), via Mesa D3D12
os      Ubuntu 24.04 under WSL2, 46 GiB
gcc 13.3 · clang 18.1.3 · rustc 1.97.1 · GHC 9.10.3 · Node 25.5
go 1.25 · swift 6.3.3 · python 3.12.3 (+ 3.14t) · perl 5.38.2 · CUDA 12.0
```

> Two caveats up front. The run happened on the Windows filesystem across the
> 9p bridge, not after `scripts/stage-wsl.sh`; that distorts build times and
> I/O, neither of which appears in this document — the simulation is CPU-bound,
> and binary sizes and RSS are unaffected either way.
>
> And: **differences below roughly 5 % are not resolved by these tables.**
> Three repetitions are not enough for that, and two series thirty minutes
> apart disagree on small effects right down to the sign. Where that affects a
> claim, it is said next to the claim.

---

## Contents

1. [The short version](#1-the-short-version)
2. [Language comparison (class S)](#2-language-comparison-class-s)
3. [Compilers](#3-compilers)
4. [How much programming style matters (Haskell)](#4-how-much-programming-style-matters-haskell)
5. [Parallelism (class P)](#5-parallelism-class-p)
6. [Warm-up, and what ahead-of-time compilation is worth](#6-warm-up-and-what-ahead-of-time-compilation-is-worth)
7. [What the GIL costs (CPython 3.14t)](#7-what-the-gil-costs-cpython-314t)
8. [SIMD and hand-written assembly (class V)](#8-simd-and-hand-written-assembly-class-v)
9. [GPU (class G)](#9-gpu-class-g)
10. [Rendering (class R)](#10-rendering-class-r)
11. [Footprint](#11-footprint)
12. [What did not work](#12-what-did-not-work)
13. [Proved, not measured](#13-proved-not-measured)
14. [Where I was wrong](#14-where-i-was-wrong)
15. [Open questions](#15-open-questions)

---

## 1. The short version

The same simulation in **fourteen languages**, from a Perl interpreter to 84
streaming multiprocessors, plus CUDA and GLSL compute as GPU hosts. Every
number in this document comes from one series on one machine, recorded in one
sitting: `results/run-20260821-1113`, commit `ed1bf2b`. Numbers from two
different series are not comparable and this document does not mix them.

![Class overview](charts/classes.svg)

| Class | best configuration | `medium`, 100 ticks | vs. 1 CPU core |
|---|---|---:|---:|
| S — one thread | C, gcc `-O3 -march=native` | 5623 ms | 1× |
| P — 32 threads | **Go**, `binned` | 571 ms | **9.8×** |
| G — GPU | CUDA, RTX 5080 | **50 ms** | **112×** |

Two things that are not in that table and are the most interesting results of
this series:

**Go wins class P**, not C and not C++ — 571 ms against 666 and 650, from a
7 % single-thread deficit. §5 measures why: its barrier is 17 % cheaper, and
the gap is concentrated in the one phase where 31 workers wait for one.

**Hand-written AVX-512 assembly beats the intrinsics by about 11 %**, and not
with better instructions but with a third of the loads; §8.

Class V is not in the table because it is measured at `small` — there AVX-512
buys **1.25×** (1085 → 871 ms). The diffusion pass alone gets 4.5× faster, but
it is only a quarter of the runtime; §8.

Seven results I would not have predicted:

- **Bit-exactness survives everything.** Every tier-A run in `serial` mode
  produces `0x9E8B1688`, every one in `deferred` mode `0xAAB0115C` — across
  fourteen languages, four .NET compilation strategies, three JVM
  configurations, class P in ten languages at every thread count, SIMD,
  hand-written assembly, CUDA at every preset, and all 34 cells of the CPython
  matrix. The spec had assumed the opposite for both SIMD and GPU.
- **A language ranking from one class does not carry to the next.** Go sits at
  rank 9 of 16 in class S and wins class P. TypeScript is 3.6× slower than C in
  class S and scales better than anything else (11.0×). Haskell is at 1.23× in
  class S and matches C in class R. Java is the fastest garbage-collected
  runtime in class S and the slowest to scale in class P.
- **A Python file is at 1.30×.** `slimebench_numba.py` is the pure-Python port
  with `@njit` on the kernels — same loops, same order, same names — and 349×
  faster than it at the same conformance tier. That ratio is the cleanest
  measurement of an interpreter here, because nothing else about the program
  changed; §2.
- **Ahead-of-time compilation matches the JIT.** C# Native AOT lands within
  3 % of the optimising JIT with a full run's profile behind it, starts seven
  times faster, and has no warm-up ramp at all — 2.0× from first tick to best,
  where the JVM's is 26.3×. §6.
- **Java's portable vector API matches hand-written AVX-512.** 3.95 ms of
  diffusion against C's 2.98, and a lower total time — from source that names
  no instruction set. §8.
- **No garbage collector here does anything.** The JVM collects zero times in
  200 ticks; Go allocates 298 times in the whole run. Six of the fourteen
  languages are collected and none of them is being asked to collect, which is
  a limitation of the workload that §11 now states with numbers instead of
  leaving implied.
- **Class R does not compare languages.** On raylib, four compiled languages
  land within **10 %** of each other. What matters is the pixel format.
- **The GIL does not cost scaling, it costs runtime.** CPython 3.12 with 16
  threads takes **7.3× as long** as the single-thread run, not the same time.
  Details in §7.
- **Almost every "obvious" optimisation lost.** PGO, the parallel prefix sum,
  the load balancer, the pure spin barrier — four attempts, one usable result.
  Details in §12.

---

## 2. Language comparison (class S)

One thread, scalar. 256×256 with 16 384 agents and 100 ticks — a size chosen so
that **Perl and pure Python finish it in seconds**, because that is the only
way all the languages fit in one table. Each implementation appears once, with
its best profile; the compiler axis has its own section.

![Language comparison](charts/languages.svg)

### `--update serial`

Conformance tier A only: a fast-math profile computes different numbers, so
letting one win a row would compare two programs. The tier-C profiles are in
§3.

| # | Language | Profile | ms/tick | rel. |
|---:|---|---|---:|---:|
| 1 | C | o3-native-lto | 0.1903 | 1.00× |
| 2 | C++ | o3-native | 0.2080 | 1.09× |
| 3 | C (PGO) | o3-native-pgo | 0.2213 | 1.16× |
| 4 | **Haskell** | o2-llvm | **0.2343** | **1.23×** |
| 5 | **Swift** | unchecked | **0.2465** | **1.30×** |
| 6 | **Python (numba)** | — | **0.2466** | **1.30×** |
| 7 | **Java** | C2 only | **0.2570** | **1.35×** |
| 8 | Rust | release-native-lto-unchecked | 0.2581 | 1.36× |
| 9 | Go | nobounds | 0.2727 | 1.43× |
| 10 | **C#** | tier1 | **0.2863** | **1.50×** |
| 11 | **Fortran** | o3 | **0.2995** | **1.57×** |
| 12 | TypeScript | node | 0.6782 | 3.56× |
| 13 | Lean 4 | default | 1.5026 | 7.90× |
| 14 | **OCaml** | unsafe | **1.8818** | **9.89×** |
| 15 | Python (`--strict-f32`) | — | 87.61 | 460× |
| 16 | Perl (`--strict-f32`) | — | 124.65 | 655× |

**Every tier-A run in this mode: `0x9E8B1688`.**

### `--update deferred`

Here numpy and the idiomatic Haskell version can compete as well.

| # | Language | Profile | ms/tick | rel. |
|---:|---|---|---:|---:|
| 1 | C | o3-native | 0.1946 | 1.00× |
| 2 | C++ | o3-native | 0.2127 | 1.09× |
| 3 | C (PGO) | o3-native-pgo | 0.2181 | 1.12× |
| 4 | Python (numba) | — | 0.2531 | 1.30× |
| 5 | Swift | unchecked | 0.2538 | 1.30× |
| 6 | Haskell | o2-llvm | 0.2543 | 1.31× |
| 7 | Rust | release-native-lto-unchecked | 0.2645 | 1.36× |
| 8 | Java | C2 only | 0.2666 | 1.37× |
| 9 | Go | nobounds | 0.2882 | 1.48× |
| 10 | Fortran | o3 | 0.3069 | 1.58× |
| 11 | C# | ReadyToRun | 0.3217 | 1.65× |
| 12 | Haskell (idiomatic, `vector`) | o2-llvm-vector | 0.4884 | 2.51× |
| 13 | TypeScript | node | 0.7244 | 3.72× |
| 14 | Python (numpy) | — | 1.1150 | 5.73× |
| 15 | Python (numpy, 3.14t) | — | 1.2899 | 6.63× |
| 16 | OCaml | unsafe | 2.0251 | 10.41× |
| 17 | Lean 4 | default | 2.2973 | 11.80× |
| 18 | Python (`--strict-f32`) | — | 93.05 | 478× |
| 19 | Perl (`--strict-f32`) | — | 134.09 | 689× |

**Every tier-A run in this mode: `0xAAB0115C`.**

Worth noting:

- **Six languages sit inside a 25 % band between 1.23× and 1.50×**, and that
  band contains an ML dialect compiled through LLVM, a systems language with
  refcounting, a Python decorator, two managed runtimes with garbage
  collectors, and Go. The ordering inside it is not dependable; the fact that
  they are all there is.
- **numba, at 1.30×, is a Python file.** It is
  [slimebench_pure.py](../impl/python/slimebench_pure.py) with `@njit` on the
  kernels — the same loops, the same order, the same variable names — and it
  is 355× faster than that file at the same conformance tier. See the
  subsection below; that ratio is the cleanest measurement of an interpreter
  in this document, because nothing else about the program changed.
- **Haskell is in fourth place, ahead of Swift, Go, Java and Rust.** §4 has the
  reason: one change (`Data.Array.Unboxed.(!)` → `unsafeAt`) was worth 1.5×.
- **Java at 1.35× is the fastest garbage-collected runtime here**, and it needs
  no `strictfp`: JEP 306 made floating point strict in Java 17, and the JLS has
  never allowed a JIT to fuse a multiply-add. Its cost is elsewhere — §6 has
  the warm-up curve, which is 26× from the first tick to the best one.
- **Fortran, at 1.57×, is slower than five garbage-collected or JIT-compiled
  languages.** It is also the only port in the project that needed no argument
  for exactness: native single precision since 1957 and an arithmetic model
  that says what it does. That combination is the finding, not the rank.
- **OCaml is 9.9×, and it is not the language that is slow.** Its `float array`
  is unboxed and the same program with f64 intermediates runs at 1.81× — the
  9.9× is what conformance tier A costs when the language has no float32 type.
  See below.
- **Lean at 7.9× beats OCaml at 9.9×**, which is the reverse of what the memory
  models predict. Lean boxes every array element and OCaml does not; OCaml has
  to call a runtime function for each rounding and Lean does not. On this
  workload the rounding calls cost more than the boxing.
- **Perl and pure Python are within 2 %** of each other at tier B (38.9 vs
  38.5 ms/tick). Interpreter dispatch dominates so completely that the language
  difference disappears; which is ahead changes between series.
### What Lean pays, and where

Lean is in the tables above at 7.9×, and three things about how it gets there
are worth keeping.

**It computes in native `Float32`, and that had to be checked.** Lean's
`Float32` was verified against `round_f32(f64_op(a,b))` — the identity §7.2 of
the spec rests on — over 50 000 pairs spanning normals, subnormals and huge
values, for `+`, `*` and `/`: zero mismatches, and `0.94` gives `0x3F70A3D7`.
So it needs no `--strict-f32` equivalent, unlike Python, Perl and OCaml.

**Its arrays are copy-on-write, not persistent.** `Array.uset` mutates in place
at refcount 1 and copies otherwise, so a write loop is O(n). If something else
still holds the array it copies exactly *once* and the rest of the loop is in
place again. Confirmed by running the same fill at n and 4n and reading the
ratio: 3.5, 4.9, 3.8 — not 16.

**The `leanc` optimisation level does nothing.** `-O3 -march=native` measured
1.5 % slower than the default, which is inside the noise. The generated C is
dominated by Lean runtime calls, and a C compiler cannot improve those.

#### Class P: the only language where the obstacle is not the barrier

Every other port's class P problem is synchronisation — workers share one grid
and coordinate at six barriers per tick. Lean has no shared mutable grid to
coordinate over. Its arrays are reference-counted and copy-on-write, so two
tasks holding the same destination buffer would each copy it on the first
write. The design space is *ownership*, not synchronisation, and it allows
three shapes. All three were measured, all three are bit-identical to the
serial run (`0xBEBD17BD`), and the experiment is
[`bench/lean-tasks.sh`](../bench/lean-tasks.sh):

| Shape | T=2 | T=4 | T=8 | T=16 |
|---|---:|---:|---:|---:|
| striped, boxed ¹ | 0.38× | 0.45× | 0.49× | 0.50× |
| sliced, boxed | 0.45× | 0.51× | 0.55× | 0.54× |
| **sliced, unboxed** | 1.02× | 1.36× | **1.52×** | 1.44× |

Speedup against the serial version *of the same representation*,
`LEAN_NUM_THREADS=16`, 512², diffusion pass only.

**With the natural representation, tasks make it slower at every thread
count.** `Array Float32` stores every element as a heap object. Once an array
is shared with a task Lean marks it multi-threaded and reference-counts it
atomically — so nine reads per cell become nine atomic read-modify-writes per
cell, and no number of cores buys that back.

**Storing the f32 bit patterns in an `Array UInt32` removes the per-element
object**, and the same code then reaches 1.52× at eight tasks. But that
representation is 19 % *slower* serially (the `ofBits`/`toBits` conversions),
so measured end to end against the best serial version the win is **1.27×**,
not 1.52×.

For comparison, the other eight languages reach 6.8× to 9.5× on the same
axis. Lean is the outlier, and the reason is structural rather than a missing
optimisation: a language whose memory model makes sharing expensive pays for
it exactly where a benchmark like this looks.

The port therefore ships **class S only**. A class P target reaching 1.2×
would sit in the §5 scaling table next to eight languages that parallelise the
whole tick, and it would parallelise the diffusion pass alone — the agent pass
needs a shared deposit buffer, which is the thing that does not exist here.
Putting it in that table would compare two different things, which is what
benchmark classes exist to prevent.

¹ `Array (Array Float32)`, one block per task. A first version indexed the
nested array nine times per cell and cost 4.7× against serial; resolving the
three source blocks once per row halved that. It is in the table because the
gap between the two is a fair warning about where the cost hides.

### What bit-exactness costs in the scripting languages

`256²`, 100 ticks, milliseconds per tick:

| Language | tier B (ms/tick) | tier A (ms/tick) | surcharge |
|---|---:|---:|---:|
| Python (pure) | 38.45 | 87.61 | 2.3× |
| Perl | 38.90 | 124.65 | 3.2× |
| **OCaml** | **0.345** | **1.882** | **5.5×** |

Considerably cheaper than expected in the two interpreted languages, and that
is itself the finding: where an interpreter dispatch is already paid per
operation, nine extra C-level calls per cell largely disappear into the
overhead that was there anyway.

Perl pays more than Python because a Perl array stores full doubles, so *every*
operation has to be rounded, whereas Python's `array('f')` rounds to f32 on
store in any case.

**OCaml pays by far the most, and it is the only compiled language in the
table.** That is the point of having it there. OCaml 4.14 has no float32 type
at all, so the only way to round is
`Int32.float_of_bits (Int32.bits_of_float x)` — and the assembly says what that
compiles to. Not the boxing one would assume: the allocation count is
*identical* between the two builds, because the non-flambda unboxing rules do
handle the intermediate. What it compiles to is a pair of calls into the
runtime, `caml_int32_bits_of_float_unboxed` and its inverse, through the PLT.
The stencil makes ten roundings per cell, so the diffusion pass carries
**22 C calls per cell** and goes from 1.6 ns to 21 ns per cell.

Two things follow. Exactness in OCaml is expensive for a reason that is a
missing intrinsic rather than a property of the language — and Lean, which
boxes every array element but has a native `Float32`, comes out *ahead* of it
at 7.9× against 9.9×. The two ML-family ports pay opposite tolls, and on this
workload the rounding calls cost more than the boxing.

Fortran is absent from the table because it has nothing to pay: `real(real32)`
is IEEE binary32 and the arithmetic is already f32. It is the only port here
for which exactness required no argument at all.

### The interpreter, isolated (numba)

The table above says what exactness costs *within* an interpreter. It does not
say what the interpreter costs, because every other row is also a different
program. [`slimebench_numba.py`](../impl/python/slimebench_numba.py) is written
to close that gap: it is
[`slimebench_pure.py`](../impl/python/slimebench_pure.py) with `@njit` on the
kernels — the same loops, the same order of operations, the same variable
names, the same file structure. The only differences are the decorator and
`np.float32` arrays in place of `array('f')`.

128², 4096 agents, 100 ticks, `serial`, measured by
[`bench/numba-jit.sh`](../bench/numba-jit.sh):

| Target | tier | grid hash | ms/tick | vs numba |
|---|:-:|---|---:|---:|
| python pure | B | `0x44625B3D` | 9.9502 | 154× |
| python pure `--strict-f32` | A | `0xB1D75130` | 22.4882 | **349×** |
| **numba** | **A** | `0xB1D75130` | **0.0645** | 1.00× |
| numba `--fastmath` | C | `0xF9B2609A` | 0.0710 | 1.10× |
| c gcc `-O2` | A | `0xB1D75130` | 0.0618 | 0.96× |

**Against the honest comparison — tier A against tier A — CPython costs 349×.**
Not 154×: the tier-B row is a different computation, one that happens to be
cheaper because it is wrong. And what is left after the interpreter is removed
is 4 %: numba runs the identical source at **1.04× of gcc `-O2`**.

The second finding is about the exactness surcharge, and it inverts. Pure
Python needs `--strict-f32` and pays 2.2× for tier A, because CPython has no
f32 arithmetic and every intermediate has to be forced through a `struct`
round-trip. numba has `float32` as a real type, so **it is tier A by default,
at no cost at all** — 20 of 20 conformance cases across the full set, first
attempt, no strictness flag. The same language, one runtime apart, and
exactness goes from expensive to free.

The third is that hand-vectorising was the wrong answer. From the `deferred`
table above, where the numpy target can run:

| Target | ms/tick |
|---|---:|
| c gcc `-O3 -march=native` | 0.1946 |
| **numba** (scalar loops) | **0.2531** |
| numpy (vectorised) | 1.1150 |

**The scalar loops through a JIT are 4.4× faster than the vectorised numpy
version** — and they can do `serial`, which numpy structurally cannot (§9).
The numpy target exists because in 2015 it was the only answer; it is kept
because it is a fair measurement of that answer, not because it is the good one.

What numba charges instead is up front: compiling the seven kernels takes
about 0.7 s. That is not in any number above, because
[`_precompile()`](../impl/python/slimebench_numba.py) compiles them against a
4×4 grid before the clock starts. Leaving it to `--warmup` would work too, and
would silently turn `ms_per_tick_p99` into a compiler benchmark whenever
someone omitted the flag — the failure shape §14 is a list of.

### `--fastmath`: the grid hash catches it, the agent hash does not

`--fastmath` compiles the *identical source text* with LLVM's fast-math flags.
It is therefore the cheapest available demonstration of what conformance tier C
is for: one program, one flag, two tiers.

It is also not faster. In this series it is 10 % *slower* — 0.0710 against
0.0645 ms/tick — and in the class S table above it wins by 1 % in `serial` and
loses by 1 % in `deferred`. Across four measurements it has no consistent sign,
which is the honest summary: LLVM's reassociation has nothing here worth
reassociating. The stencil is nine adds the spec has already ordered, and the
agent pass has no reduction at all.

That is worth stating plainly, because it is the whole trade. `--fastmath` buys
nothing measurable on this workload and costs conformance tier A.

What it does do is diverge, and *where* it diverges is the finding. SPEC-1 §6
hashes the grid and the agents separately, for fault localisation. Sweeping
tick counts at 512² with 65 536 agents:

| ticks | `serial` grid | `serial` agents | `deferred` grid | `deferred` agents |
|---:|:-:|:-:|:-:|:-:|
| 1 | **DIFF** | same | **DIFF** | same |
| 5 | **DIFF** | same | **DIFF** | **DIFF** |
| 50 | **DIFF** | same | **DIFF** | **DIFF** |
| 400 | **DIFF** | same | **DIFF** | **DIFF** |
| 800 | **DIFF** | **DIFF** | **DIFF** | **DIFF** |

**The grid diverges on tick 1 in both modes. The agent checksum keeps
reporting agreement for 400 ticks in `serial`.** A conformance gate that
hashed only the agents would have certified a fast-math build as bit-exact
through a run longer than most of the ones in this document.

The mechanism is that agent positions are *exact* by construction: a heading
indexes the generated trig table, and the result is multiplied by the step and
added in f32 — no operation there for fast-math to reassociate. An agent can
only move differently once a low-bit difference in the grid flips one of the
three `>=` comparisons in the sensing step. Until the first such flip the
agent hash is not merely lagging, it is *identical*, and it stays identical
until chaos amplifies one ULP into a decision. That took 400–800 ticks in
`serial` and fewer than 5 in `deferred`.

Two hashes were originally split so that a divergence could be attributed to
the diffusion pass or the agent pass. The more useful property turns out to be
this one: the grid hash is the sensitive instrument, and a checksum over the
agents alone would be a slow-acting one.

---

## 3. Compilers

1024×1024, 262 144 agents, 300 ticks, best of three runs. Nine compilers and
toolchains, each with its own profile axis.

![Compiler matrix](charts/compilers.svg)

| Language | Compiler | Profile | Tier | ms | rel. | Binary KiB |
|---|---|---:|:-:|---:|---:|---:|
| C | clang | o3-native | A | **1085** | 1.00× | 54 |
| C++ | g++ | ofast-native | **C** | 1132 | 1.04× | 74 |
| C | gcc | o2 | A | 1148 | 1.06× | 50 |
| C++ | g++ | o3 | A | 1151 | 1.06× | 70 |
| C | clang | o3-native-lto | A | 1158 | 1.07× | 54 |
| C | gcc | o3 | A | 1159 | 1.07× | 58 |
| C++ | clang++ | o3-native | A | 1206 | 1.11× | 63 |
| C++ | g++ | o3-native | A | 1216 | 1.12× | 74 |
| C++ | clang++ | o3-native-lto | A | 1217 | 1.12× | 63 |
| C | gcc | ofast-native | **C** | 1248 | 1.15× | 62 |
| C++ | g++ | o2 | A | 1257 | 1.16× | 62 |
| C | gcc | o3-native | A | 1274 | 1.17× | 62 |
| C | gcc | o3-native-lto | A | 1288 | 1.19× | 54 |
| C | clang | o2 | A | 1292 | 1.19× | 50 |
| Haskell | ghc | o2-llvm | A | 1304 | 1.20× | 2860 |
| C | clang | o3 | A | 1322 | 1.22× | 50 |
| Swift | swift | unchecked | A | 1350 | 1.24× | 96 |
| C++ | g++ | o3-native-lto | A | 1368 | 1.26× | 66 |
| Go | go | nobounds | A | 1399 | 1.29× | 1552 |
| C++ | clang++ | o3 | A | 1415 | 1.30× | 59 |
| C++ | clang++ | o2 | A | 1420 | 1.31× | 59 |
| Swift | swift | release | A | 1434 | 1.32× | 100 |
| Rust | cargo | release-native-lto-unchecked | A | 1460 | 1.34× | 442 |
| Go | go | default | A | 1460 | 1.35× | 1592 |
| Rust | cargo | release-native-unchecked | A | 1481 | 1.36× | 475 |
| Rust | cargo | release | A | 1491 | 1.37× | 471 |
| Rust | cargo | release-unchecked | A | 1562 | 1.44× | 468 |
| C++ | clang++ | ofast-native | **C** | 1612 | 1.49× | 63 |
| Haskell | ghc | o2 | A | 1640 | 1.51× | 2832 |
| C | clang | ofast-native | **C** | 1643 | 1.51× | 54 |
| Rust | cargo | release-native | A | 1648 | 1.52× | 476 |
| Haskell | ghc | o1 | A | 2881 | 2.65× | 2779 |
| C | clang | o0 | A | 3522 | 3.25× | 54 |
| C | gcc | o0 | A | 4340 | 4.00× | 114 |
| C++ | clang++ | o0 | A | 4413 | 4.07× | 155 |
| C++ | g++ | o0 | A | 4837 | 4.46× | 166 |

**Every tier-A run agrees.** The four fast-math builds diverge, and they
diverge *differently per compiler* — which is exactly why fast-math is a
conformance tier of its own.

### `-Ofast` costs clang half its speed and gcc nothing

| | `-O3 -march=native` | `-Ofast -march=native` | Δ |
|---|---:|---:|---:|
| C, clang | 1085 ms | 1643 ms | **+51 %** |
| C++, clang++ | 1206 ms | 1612 ms | **+34 %** |
| C, gcc | 1274 ms | 1248 ms | −2 % |
| C++, g++ | 1216 ms | 1132 ms | −7 % |

On clang the effect is large, reproducible and points the wrong way: freedom to
reassociate lets it reorder the nine-point stencil into something worse. The
diffusion pass alone rises from 270 to 815 ms.

**On gcc it is not an effect at all.** An earlier series measured +3 % here,
this one −2 %. Something that changes sign between two measurements is not an
effect. What remains: you pay for determinism and get nothing measurable on
gcc, and a loss on clang.

### clang wins — but only with `-march=native`

`-O2`: gcc 1148 ms, clang 1292 ms. `-O3 -march=native`: gcc 1274 ms, clang
1085 ms. Compare only `-O2` and you conclude "gcc is 11 % faster"; add
`-march=native` and you conclude "clang is 15 % faster". Same source. This
finding has now survived three series.

### LTO is noise

clang 1085 → 1158 ms with LTO, gcc 1274 → 1288, g++ 1216 → 1368, clang++
1206 → 1217. So in this series LTO costs between 1 and 13 % everywhere; in the
previous one it gained 3 % on clang and cost 1 % on gcc. On Rust it is likewise
in the noise at 1481 → 1460. The only dependable statement is that LTO does
nothing measurable to this program — it is one translation unit's worth of
work spread over four files.

### Bounds checks: Rust 11 %, Go 4 %, Swift 6 %

| Language | with checks | without | cost |
|---|---:|---:|---:|
| Rust | 1648 ms (`release-native`) | 1481 ms (`-unchecked`) | **11 %** |
| Swift | 1434 ms (`release`) | 1350 ms (`-Ounchecked`) | 6 % |
| Go | 1460 ms (default) | 1399 ms (`-gcflags=all=-B`) | 4 % |

An earlier series broke the Rust figure down: 28–35 % in the diffusion pass,
nothing measurable in the agent pass. The checks get in the way of vectorising
the stencil; in the agent pass the CPU is waiting on cache misses anyway.
"Bounds checking costs nothing" and its opposite are both wrong — it depends on
the access pattern, and this benchmark happens to have both kinds in one
program.

Go and Swift paying less than Rust is not down to better checks. Their
diffusion loops are not vectorised as far as LLVM takes Rust's in the first
place, so there is less to lose.

### GHC: the LLVM backend is worth it

`-O1` 2881 ms, `-O2` 1640 ms, `-O2 -fllvm` **1304 ms**. The LLVM backend buys
**20 %** over the native code generator, for 1 % more binary size. All three
bit-exact. GHC 9.10 warns that LLVM 18 is outside the supported range and
proceeds correctly anyway — verified against the conformance vectors rather
than taken on trust.

---

## 4. How much programming style matters (Haskell)

`impl/haskell/src/Sim.hs` is `IOUArray` in `IO` with hand-written tail
recursion and explicit index arithmetic. That is structurally the C reference
rebuilt statement by statement, and nobody writes Haskell that way unless they
are doing exactly that.

Two claims about Haskell pull in opposite directions here: that you normally
write *high-level* code and let GHC do the work, and that careful *low-level*
code gets you *close to C*. Both are measurable, so this section measures them.

![Haskell styles](charts/haskell-style.svg)

`small`/300 `deferred`, all four bit-identical (`0x7A67A29B`):

| Variant | ms | vs. C |
|---|---:|---:|
| C reference, clang `-O3 -march=native` | 1138 | 1.00× |
| **Haskell low-level, `unsafeAt`** | **1420** | **1.25×** |
| Haskell low-level, `Data.Array.Unboxed.(!)` | 2077 | 1.83× |
| Haskell idiomatic, `Data.Vector.Unboxed` | 5287 | 4.65× |

All four rows come from the same series as the rest of this document. That was
not always true: the slow `(!)` version was fixed the moment it was found, and
a comparison against a variant that no longer compiles is a memory, not a
measurement. It is a build profile now (`o2-llvm-safetrig`, a CPP switch around
four table lookups) so it can be regenerated along with everything else.

Three findings:

**"Close to C" holds — and it hung on four characters.** The trig table is read
four times per agent. `Data.Array.Unboxed.(!)` is the obvious way to write
that, but it goes through the `Ix` class, computes the offset and range-checks
it, and GHC eliminates neither even though the bounds are compile-time
constants. Replaced by `unsafeAt`: **1.46×** on total runtime — and the index
had already been reduced mod NDIR, so the check could never have fired.

**High-level costs 3.7× against the low-level port here.** The idiomatic
version is honestly idiomatic: pure functions over immutable `U.Vector`, no
`IO` in the core, the diffusion pass a `U.generate`, the deposit scatter a
`U.accumulate`. As a pure mapping, the stencil is precisely the case where
fusion works. The agent pass is not: every tick builds five new vectors where
the mutable version writes into existing buffers.

**The idiomatic style hits the same wall as numpy.** `--update serial` requires
an agent to see its predecessors' deposits *within the same tick*. Over
immutable vectors that would mean rebuilding the grid once per agent. The
implementation refuses the mode with exit code 3 — the same wall as
[`slimebench_numpy.py`](../impl/python/slimebench_numpy.py), for the same
reason.

And one bug the separated checksums caught: the first version accumulated
deposits with `U.accumulate` straight into the grid. Two deposits into the same
cell then give `(g + d₁) + d₂` instead of the prescribed `g + (d₁ + d₂)` — 1
ULP, as soon as `g` is large enough. The *grid* hash diverged and the *agent*
hash did not, which located the bug without a search. That is exactly why
[SPEC §6.3](../spec/SPEC.md) keeps the two apart.

> What this does *not* show is that idiomatic Haskell is slow. It shows that it
> is slow on **this** workload — a mutable grid modified pointwise a million
> times per tick. That is the worst imaginable case for persistent data
> structures, and the spec mandates it.

---

## 5. Parallelism (class P)

`deferred` mode only — `serial` lets agents see their predecessors' deposits
within the same tick and is therefore not deterministically parallelisable
even in principle.

![Scaling across languages](charts/scaling-langs.svg)

`medium` (2048², 1 048 576 agents), 100 ticks, milliseconds. Perl runs at
`tiny`, because `medium` there would take hours.

### `binned` — bit-identical to the serial run

| Language | T=1 | T=2 | T=4 | T=8 | T=16 | T=32 | Speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| TypeScript | 13499 | 4509 | 2387 | 1658 | **1229** | 1492 | **11.0×** |
| **Go** | 6016 | 2452 | 1646 | 873 | 654 | **571** | **10.5×** |
| Swift | 7095 | 2633 | 1786 | 1080 | **833** | 971 | 8.5× |
| C | 5623 | 2806 | 1320 | 962 | 719 | **666** | 8.4× |
| Haskell | 5837 | 2761 | 1270 | **801** | 715 | 831 | 8.2× |
| C++ | 5199 | 2469 | 1351 | 914 | 660 | **650** | 8.0× |
| Rust | 6714 | 2947 | 1815 | 1114 | **905** | 1089 | 7.4× |
| **C#** | 8171 | 3369 | 2151 | 1311 | **1308** | 1995 | 6.2× |
| **Java** | 6068 | 2613 | 1612 | **1071** | 1117 | 1513 | 5.7× |
| Python | 9010 | 6376 | 3498 | 2338 | **2065** | 2589 | 4.4× |
| Perl ¹ | 4547 | — | — | — | — | — | — |

¹ `tiny`, replicated reduction — see below; this series recorded only its
single-thread row.

**The two managed runtimes come last, and they are last for the same reason.**
Java peaks at 5.7× and C# at 6.2×, both at or before 16 threads, and both then
*regress* — Java to 1513 ms at 32 threads from 1071 at 8, C# to 1995 from 1308.
Their compute is not the problem: at one thread Java is 6068 ms against C's
5623, a 8 % gap that matches its 1.35× in §2 once the extra work of `deferred`
is accounted for. What collapses is the barrier.

Both use their standard library's: Java `java.util.concurrent.CyclicBarrier`,
C# `System.Threading.Barrier`. That is deliberate — §5 is about where the
languages actually differ, and substituting a hand-rolled barrier would replace
the thing being measured with a copy of someone else's answer. The consequence
is that the class P ranking at 32 threads is a ranking of barrier
implementations, which is what the phase breakdown below shows directly.

### `private` — reproducible per thread count only

| Language | T=2 | T=4 | T=8 | T=16 | T=32 |
|---|---:|---:|---:|---:|---:|
| C | 2967 | 1739 | **1449** | 2914 | 6937 |
| C++ | 2852 | 1654 | **1327** | 2665 | 6538 |
| Go | 2116 | **1324** | 1386 | 2444 | 6334 |
| Swift | 2406 | **1390** | 1301 | 2581 | 7090 |
| Haskell | 2039 | 1325 | **1215** | 2768 | 7397 |
| Java | 2213 | **1455** | 1524 | 2958 | 7175 |
| C# | 2493 | **1560** | 1476 | 2814 | 6494 |
| Rust | 3243 | 1919 | **1556** | 2766 | 6282 |
| TypeScript | 7433 | 4072 | **2651** | 3135 | 6760 |
| Python | 5449 | 3262 | **2556** | 2688 | 3818 |

**At 32 threads `private` drops below the serial runtime** — in C to 6937 ms
against 5623. The reduction reads `T` complete grids: at `medium` with 32
threads that is 512 MiB of memory traffic per tick, purely to add deposits
together. `binned` needs 8 MiB for the same job, independent of thread count.
So the strategy you naively write first is not only the weaker guarantee, it is
also the slower one from eight threads on.

### Go wins class P

At 32 threads Go is the fastest implementation in the field at **516 ms**,
ahead of C++ (551) and C (550) — from a 12 % single-thread deficit against C.
It is also the only language whose `binned` curve still falls at 32 threads;
C, C++, Haskell, Rust and Swift bottom out at 16 or turn back up after it.

The shape of the curve says where to look: at T=4 Go is *well behind* C
(1442 against 1112 ms) and at T=32 it is ahead, so the advantage grows with the
number of participants — synchronisation, not the compute kernel.

**That was a hypothesis, and it has now been measured.** Both implementations
report the same work/barrier split under `SLIMEBENCH_PHASE_STATS=1`; three runs
each, `medium`/100, T=32, `binned`, ms per tick, goroutine/thread 0:

| | C | Go |
|---|---|---|
| work | 2.10 – 2.19 | 2.04 – 2.32 |
| barrier | **3.23 – 3.31** | **2.67 – 2.84** |
| barrier share of the tick | 61 % | 56 % |

**The compute work is indistinguishable** — the two ranges overlap, and a
single sample that appeared to show Go doing 10 % more did not survive
repetition. **The barrier is not**: Go's is consistently around 17 % cheaper,
outside the run-to-run spread of either.

The difference concentrates in one phase. `prefix` is the step where worker 0
computes the offset table alone and the other 31 wait:

| Phase | C barrier | Go barrier |
|---|---:|---:|
| prefix | 0.530 | **0.210** |
| agents | 1.068 | 0.680 |
| merge | 0.657 | 0.878 |

Go is 2.5× cheaper on the most one-sided wait in the tick and *loses* on
`merge`, where all 32 workers arrive at roughly the same moment. That is the
shape one would expect if parking a waiter in a user-space scheduler is cheap
and waking a thundering herd of them is not — but that second half is now the
hypothesis, and it is labelled as one.

What the measurement settles is narrower and firmer than the original claim:
Go wins class P at 32 threads because its barrier costs less, not because its
kernel is faster.

### Determinism

| `deposit` | Strategy | T=1 | T=4 | T=32 |
|---|---|---|---|---|
| 10.0 (default) | `binned` | `0xC5C53969` | ✓ | ✓ |
| 10.0 | `private` | `0xC5C53969` | ✓ | ✓ |
| **0.1** | `binned` | `0x95EEB32D` | ✓ | ✓ |
| **0.1** | `private` | `0x95EEB32D` | `0xE82B2012` ✗ | ✗ |

`binned` is bit-identical to T=1 for **any** thread count, checked for
T ∈ {2,3,4,7,8,16,32} — including counts that do not divide the height.

`private` also agrees under the default parameters, but only *by accident*: at
`deposit = 10.0` every partial sum `k · 10` stays below 2²⁴ and is exact in
f32. With `--deposit 0.1` that breaks immediately — and **five languages
produce the same wrong hash `0xE82B2012` at T=4**. Same grouping, same error.
That is better evidence that the ports compute the same thing than agreement on
the correct answers would be.

### What the individual languages pay

**TypeScript scales best among the non-systems languages, despite being 3.6×
behind in class S.** The gap to C shrinks from 3.6× to 2.3×. And there `binned`
is already 3.1× faster than one thread at *two* threads — which is not
parallelism but locality: at equal thread count `binned` beats `private` by
1.63× there, and by only 1.10× in C. Writing the target cells sequentially into
`aidx` and applying them row-block by row-block afterwards replaces a scattered
read-modify-write over 16 MiB with one sequential write plus one sorted write.
In V8 that is worth far more than in C.

**Haskell's barrier is `MVar`-based, not STM.** The STM version reads better
(`retry` blocks until the generation counter changes), but every waiter
revalidates its transaction on each wakeup, and at six barriers per tick that
is a retry storm.

**Python pays for the GIL with processes.** `threading` would serialise
precisely the loops this is about — numpy releases the GIL inside large ufunc
calls, but the agent pass is a chain of dozens of small ones with Python-level
glue between them, and that glue holds the lock. So `multiprocessing` over one
`shared_memory` block, every array placed by hand. What that costs, and what a
free-threaded CPython changes about it, is §7 — it became its own section
because both backends can now be measured against each other. Side effect: the
barrier is an OS object costing tens of microseconds rather than hundreds of
nanoseconds — in C that would be the bottleneck, here it disappears into a
23 ms tick. The slowest implementation can afford the most expensive barrier.

**Perl has threads, and they are the wrong tool here.** Measured, for 262 144
elements:

| Operation | plain array | `threads::shared` | factor |
|---|---:|---:|---:|
| sequential read-modify-write | 4.5 ms | 78.2 ms | 17× |
| random read-modify-write | 13.9 ms | 105.7 ms | **7.6×** |
| `pack`+`unpack` of the same values | 12.0 ms | – | – |

The diffusion stencil reads nine cells per output cell. A shared grid would
have to make up a factor of 7.6 before the first thread contributes anything.
Pushing a whole block through `pack`/`unpack`, by contrast, costs about as much
as *one* traversal of a normal array. So: `fork` with private grids, and only
packed binary over the pipes.

That forces a third reduction strategy, one [SPEC §5.6](../spec/SPEC.md) does
not define: **replicated**. Every process applies *every* deposit, in ascending
agent index — exactly the serial chain, bit-identical for any process count,
without the `binned` sort. The price is that the deposit and merge passes run N
times instead of once, and that is what caps the speedup at 2.8×: only the
agent pass is parallel.

### The bottleneck is the barriers

`SLIMEBENCH_PHASE_STATS=1` separates work from barrier wait
(C, `medium`, T=16, thread 0), milliseconds per tick:

| Phase | work | barrier | total |
|---|---:|---:|---:|
| agents | 2.755 | 1.085 | 3.839 |
| prefix | **0.000** | 0.265 | 0.265 |
| scatter | 0.074 | 0.269 | 0.343 |
| deposit | 0.425 | 0.335 | 0.761 |
| merge | 0.356 | 0.354 | 0.710 |
| diffuse | 0.424 | — | 0.424 |

**Barriers are 35 % of the runtime at T=16 and 53 % at T=32.** The prefix sum,
previously suspected of being a "serial O(T²) section", does 0.000 ms of
measurable work.

Lines of code for the same guarantee: **C 326, C++ 264** — the difference is
almost entirely lifecycle (`std::jthread` joins on destruction, `std::barrier`
needs no `init`/`destroy`).

---

## 6. Warm-up, and what ahead-of-time compilation is worth

Every target in §2 is at full speed on tick 1 except two. Java and C# start
interpreting, promote to a fast compiler after some thousands of invocations,
and reach their final speed some tens of thousands in. That is not noise to
warm away and forget — it is the cost model of the platform, and both halves of
it are measurable here.

C# adds the other half of the question. .NET compiles the *same source* four
ways, two of them on opposite sides of the JIT/AOT line, so "what is runtime
profile information worth?" has an answer that is not a comparison between two
different programs. Nothing else in this project can be asked it: stock
OpenJDK 21 has no ahead-of-time mode.

All numbers below are 256×256 with 16 384 agents,
[`bench/jvm-warmup.sh`](../bench/jvm-warmup.sh) and
[`bench/dotnet-aot.sh`](../bench/dotnet-aot.sh).

### The ramp

Milliseconds per tick from a cold process, no warm-up, averaged over blocks:

| ticks | Java tiered | Java C2-only | C# jit | C# tier1 | **C# aot** |
|---|---:|---:|---:|---:|---:|
| 1–5 | 3.580 | 4.051 | 1.028 | 0.998 | **0.469** |
| 6–10 | 0.518 | 0.948 | 0.424 | 0.571 | **0.370** |
| 11–25 | 0.542 | 0.372 | 0.376 | 0.531 | **0.317** |
| 26–50 | 0.447 | **0.265** | 0.351 | 0.497 | 0.301 |
| 51–100 | 0.264 | 0.264 | 0.355 | 0.303 | 0.301 |
| 201+ | 0.266 | 0.264 | 0.346 | 0.298 | 0.296 |
| **first tick** | **6.346** | **6.568** | **3.166** | **2.384** | **0.571** |
| best tick | 0.241 | 0.243 | 0.328 | 0.277 | 0.280 |
| **first / best** | **26.3×** | **27.0×** | **9.6×** | **8.6×** | **2.0×** |

**The JVM's first tick costs 26× its best one.** A benchmark of a hundred ticks
that forgot `--warmup` would report a number the JVM never actually runs at.
That is why the Java rows in §2 use the C2-only profile and a warm-up: the
default profile's *median* over a cold hundred ticks lands mid-ramp, at 0.42
rather than 0.26.

Two smaller results in the same table. **Turning tiering off makes the JVM
reach steady state sooner, not later** — C2-only is already at 0.265 by tick 26
where tiered is still at 0.447, and only catches up at 51. The intuition that
skipping C1 means a longer slow phase is the wrong way round here: C1 code is
slower than the interpreter is fast, and having to climb out of it costs more
than compiling once. And **.NET's ramp is a third of the JVM's** — 9.6× against
26.3× — but it converges to a worse number.

**Native AOT is flat.** 2.0× from first tick to best, and the first tick is
0.571 ms against the JVM's 6.346. There is no ramp because there is no
compiler.

### What the profile information buys: nothing

Steady state, warm-up 50, best of three:

| Configuration | ms/tick | vs tier1 |
|---|---:|---:|
| C# jit (tiered + dynamic PGO) | 0.3541 | 1.20× |
| C# tier1 (no tiering) | 0.2951 | 1.00× |
| C# ReadyToRun | 0.3084 | 1.04× |
| **C# Native AOT** | **0.3027** | **1.03×** |
| Java C2-only | 0.2705 | — |
| C gcc `-O3 -march=native` | 0.2586 | — |

**Native AOT lands within 3 % of the optimising JIT with a full run's profile
behind it.** Same optimiser, one with the data the running program produced and
one with none, and on this workload the data is worth nothing measurable. The
20 % the default `jit` profile loses is therefore warm-up and tiering
overhead, not code quality — the tiered configuration is still re-tiering at
tick 200.

That is a narrow claim and it should stay narrow. This loop does the same thing
every tick, takes every branch the same way, and touches the same two arrays.
It is close to the best case for ahead-of-time compilation and the worst case
for profile-guided anything. The C reference agrees, from a different
direction: §12 records PGO buying nothing on gcc and *losing* 6 % on clang for
the same reason.

### What each configuration costs to ship

| Configuration | published | start-up |
|---|---:|---:|
| C# jit / tier1 | 148 KiB + runtime | 27.7 / 32.5 ms |
| C# ReadyToRun | 80 MiB | 21.0 ms |
| **C# Native AOT** | **3.8 MiB** | **3.8 ms** |

Start-up is five runs of `--ticks 0`, warm page cache; the first measurement of
ReadyToRun after building it read 217 ms, so treat that column as an ordering
rather than a constant. The ordering is stable: **AOT starts roughly seven
times faster than the JIT configurations** and ships a self-contained 3.8 MiB
binary, where ReadyToRun needs 80 MiB to be self-contained and buys nothing for
it.

### The two interpreters

The JVM can be told to stop compiling entirely. That makes `-Xint` directly
comparable to CPython running the identical algorithm at the identical
conformance tier — a comparison available nowhere else in this project, because
no other runtime here has an interpreter you can pin it to.

| Runtime | ms/tick | vs C |
|---|---:|---:|
| c gcc `-O3 -march=native` | 0.2556 | 1.0× |
| numba | 0.2554 | 1.0× |
| Java, tiered | 0.2674 | 1.0× |
| Java, C2 only | 0.2710 | 1.1× |
| Go, `-gcflags=-B` | 0.2798 | 1.1× |
| **Java, `-Xint`** | **5.6955** | **22×** |
| **Python pure `--strict-f32`** | **89.05** | **348×** |

Same algorithm, same exactness, same grid hash on every row: `0x89CFFAAC`.

**CPython's interpreter is 15.6× slower than the JVM's.** "Interpreted" is not
one performance class — the gap between these two interpreters is larger than
the gap between the JVM's and optimised C.

---

## 7. What the GIL costs (CPython 3.14t)

A controlled experiment: the same `Worker`, the same phase order, the same
reduction, the same machine. Exactly two things vary — which interpreter runs
(3.12 with the GIL, 3.14t without) and what carries the workers
(`threading.Thread` over ordinary numpy arrays, or `multiprocessing` over a
`shared_memory` block). `--mp-backend threads|processes`.

![GIL against free-threading](charts/gil.svg)

`small` (1024², 262 144 agents), 100 ticks. One thread: 3.12 **1907 ms**,
3.14t **1751 ms**.

**`binned`** — milliseconds, with the speedup against the same interpreter at
one thread in brackets:

| | 3.12 threads | 3.12 processes | 3.14t threads | 3.14t processes |
|---|---:|---:|---:|---:|
| T=2 | 1459 (1.31×) | 1229 (1.55×) | 1197 (1.46×) | 1201 (1.46×) |
| T=4 | 3025 (**0.63×**) | 618 (3.08×) | **560** (3.13×) | 627 (2.79×) |
| T=8 | 6761 (**0.28×**) | 584 (3.26×) | **493** (3.55×) | 598 (2.93×) |
| T=16 | 13933 (**0.14×**) | 797 (2.39×) | **643** (2.72×) | 796 (2.20×) |

**`private`**, same units:

| | 3.12 threads | 3.12 processes | 3.14t threads | 3.14t processes |
|---|---:|---:|---:|---:|
| T=2 | 1198 (1.59×) | 999 (1.91×) | 971 (1.80×) | 952 (1.84×) |
| T=4 | 2493 (0.77×) | **456** (4.18×) | 464 (3.77×) | 490 (3.58×) |
| T=8 | 5932 (0.32×) | **413** (4.61×) | 405 (4.33×) | 428 (4.09×) |
| T=16 | 12502 (0.15×) | 496 (3.84×) | 487 (3.60×) | 514 (3.41×) |

**All 34 runs produce the same result:** grid `0x65DF83A7`, agents
`0xE02D7B6A` — across two interpreters, two backends, four thread counts and
both reductions.

### The first column is the actual finding

CPython 3.12 with threads does not merely fail to scale, it **degrades
super-linearly**: 13.9 seconds at 16 threads against 1.9 at one, so **7.3×
slower** than the serial run. And cleanly proportional to the thread count —
0.63×, 0.28×, 0.14× is almost exactly a halving per doubling.

That is more than "the GIL serialises" explains: pure serialisation would be
1.0×, not 0.14×. The order of magnitude fits convoying at the barriers. 139 ms
per tick at 16 threads with six barriers is 96 crossings at 1.4 ms each, and
CPython's switch interval is 5 ms — so a waiter that gives up the GIL at a
barrier does not get it straight back. I have not measured that; it is the
arithmetic working out, not the proof.

### Without the GIL, threads beat processes — but only for `binned`

In `binned`, threads win at every thread count: by 18 % at T=8 (493 against
598 ms) and by 19 % at T=16. In `private` they are level (405 against 428, 487
against 496 — inside the noise).

The difference between the two reductions is the number of phases: `binned` has
five, `private` has two. Every phase boundary is a barrier, and a barrier
between processes is an OS object where one between threads is a futex in the
same address space. Where more synchronisation happens, the shared address
space pays off.

### And the honest reading

**The fastest value in the whole table belongs to CPython 3.12** — 413 ms,
`private`, eight processes. So free-threading does not make this workload
faster. It makes the workaround unnecessary: no `shared_memory` block, no
hand-computed byte offsets, no `fork` requirement, no copying the arrays back
at the end. Roughly 120 of the 350 lines in
[`slimebench_mp.py`](../impl/python/slimebench_mp.py) exist only because
threads were not an option.

The single-thread comparison (1751 against 1907 ms) looks like an argument that
free-threading costs nothing — **it is not one**. The two interpreters carry
numpy 2.5.2 and 1.26.4, and the difference between two numpy versions is
exactly the order of magnitude in question. That pair is confounded and is
there only to give the speedups a baseline.

---

## 8. SIMD and hand-written assembly (class V)

### Managed runtimes reach the vector unit — one of them all the way

Class V was three languages using intrinsics named for one instruction set.
Java and C# reach it a different way: a portable vector type, no instruction
set in the source, the width resolved at run time. 256², 16 384 agents,
`deferred`, 200 ticks after 100 of warm-up; the diffusion column is the one to
read, because the agent pass is identical in all of them and dilutes the
difference.

| target | vector | ms/tick | diffuse ms | stencil speed-up |
|---|---|---:|---:|---:|
| C, gcc `-O3 -march=native` | — | 0.2645 | 12.86 | — |
| C, `--simd` | AVX-512 intrinsics | 0.2057 | **2.98** | **4.3×** |
| Java, C2 | — | 0.2614 | 14.19 | — |
| **Java, `--simd`** | **Vector API, 512-bit** | **0.2027** | **3.95** | **3.6×** |
| C#, Native AOT | — | 0.3160 | 20.04 | — |
| C#, `--simd`, AOT + `IlcInstructionSet=native` | `Vector512<float>` | 0.2556 | 7.81 | 2.6× |
| C#, `--simd`, JIT | `Vector512<float>` | 0.2522 | 7.78 | 2.6× |
| C#, `--simd-portable` | `Vector<float>`, 256-bit | 0.2889 | 14.31 | 1.4× |

Every row above, in both update modes, produces the same hashes as the scalar
reference — three languages and four vector widths, `0xCEC6D21A` in `serial`
and `0x5673B1D9` in `deferred`. SPEC-1 §8.1 is why: the stencil does no
cross-lane work, so each lane performs exactly the scalar computation for its
own cell in the same order.

**Java's Vector API matches the intrinsics.** 3.95 ms of diffusion against C's
2.98, and on total time it actually wins — 0.2027 against 0.2057 ms/tick. A
portable vector type with no instruction set named in the source, running on a
JIT, lands within a few per cent of hand-written AVX-512. That is the single
most surprising number in this document.

**.NET's portable `Vector<T>` will not use AVX-512.** On this machine
`Vector512.IsHardwareAccelerated` and `Avx512F.IsSupported` are both true and
`Vector<float>.Count` is 8 — 256 bits.
`DOTNET_PreferredVectorBitWidth=512` does not change it. Naming
`Vector512<float>` explicitly does, and is worth 1.8× on the stencil. Java's
`SPECIES_PREFERRED` has no such reservation and takes the full width.

### Ahead-of-time compilation loses the vector unit, and it is one flag

The §6 finding was that Native AOT matches the JIT. On vector code, by
default, it does not — and the reason is not the compiler quality:

| C# configuration | `Vector<float>.Count` | diffuse ms |
|---|---:|---:|
| JIT | 8 (256-bit) | 7.78 with `Vector512` |
| Native AOT, default | **4 (128-bit)** | 14.31 |
| Native AOT, `IlcInstructionSet=native` | 16 (512-bit) | 7.81 |

**Native AOT compiles for the x64 baseline.** The JIT knows which CPU it is
running on; the AOT compiler is told at publish time, and by default it is told
"any x64", which means SSE2. `Vector512.IsHardwareAccelerated` is then *false*
in a binary running on a machine that has AVX-512.

`-p:IlcInstructionSet=native` fixes it and closes the gap to 0.4 %. It also
helps the scalar path — 24.73 ms of diffusion becomes 20.04 — because the
baseline was costing the ordinary code too. The trade is a binary that no
longer runs anywhere, which is exactly the trade a JIT does not have to make.
So §6's answer needs a qualifier: ahead-of-time compilation matches the JIT
*once someone tells it what it is compiling for*, and the default does not.



Explicit intrinsics for the diffusion pass, `--simd`, `small`/300. The agent
pass stays scalar: several agents per vector routinely deposit into the same
cell, which would need conflict resolution — and that really would be tier C.

| Language | Compiler | ISA | total ms | diffusion ms | scalar diffusion ms ¹ | factor |
|---|---|---|---:|---:|---:|---:|
| C | clang | AVX-512 | **871** | 60.2 | 270.0 | 4.49× |
| C++ | g++ | AVX2 | 927 | 66.1 | 284.6 | 4.31× |
| C | gcc | AVX2 | 935 | 65.8 | 282.7 | 4.30× |
| C++ | clang++ | AVX-512 | 956 | 56.3 | 271.5 | 4.82× |
| C++ | g++ | AVX-512 | 979 | **53.5** | 284.6 | **5.32×** |
| C | clang | AVX2 | 997 | 66.1 | 270.0 | 4.09× |
| C | gcc | AVX-512 | 1037 | 55.9 | 282.7 | 5.06× |
| C++ | clang++ | AVX2 | 1136 | 66.5 | 271.5 | 4.08× |
| Rust | cargo | AVX-512 (unchecked) | 1188 | 58.2 | 271.6 | 4.67× |
| Rust | cargo | AVX-512 (safe) | 1219 | 59.1 | 388.4 | **6.57×** |

¹ The scalar comparison figure is always the `-O3 -march=native` build of the
same language and compiler, including in the AVX2 rows (`-march=x86-64-v3`).

### It is tier A

The kernel does **no cross-lane reduction**: each lane computes one output cell
with exactly the operation sequence the scalar loop uses. Bit-identical under
gcc and clang, in both update modes, and with `--threads 16 --deposit-reduce
binned`.

Two conditions: no FMA (`4.0f*c + acc` as a single rounded operation would be a
different number) and a real `_mm*_div_ps`.

### The stencil gets 4.5×, the program 1.25×

Diffusion drops from ~275 to ~58 ms, but it is only a quarter of the runtime —
the agent pass stays scalar and dominates. Amdahl, in one line.

**Doubling the vector width buys little.** AVX2 against AVX-512: 65.8 against
55.9 ms on gcc (18 %), 66.1 against 60.2 on clang (10 %), 66.5 against 56.3 on
clang++ (18 %). The 3×3 stencil reads 36 bytes to write 4 — it is
bandwidth-bound, the execution units are waiting on memory, and double the
width only helps at the load ports.

**Rust's "safe" wins the biggest factor here, and that is an artefact.** 6.57×
sounds impressive, but it is only large because the *scalar* comparison value
is bad: with bounds checks the scalar stencil costs 388 ms instead of 272. The
SIMD kernel goes through raw pointers either way and lands at 58–59 ms. Report
factors against your own baseline and you sometimes measure the baseline.

**Read alongside the `-Ofast` finding from §3** the spread becomes absurd. Same
diffusion pass, same compiler (clang), same preset:

| Strategy | ms |
|---|---:|
| `-Ofast`, left to clang | 815.3 |
| `-O3 -march=native`, left to clang | 270.0 |
| intrinsics | 60.2 |

**A factor of 13.5 between the best and the worst way to vectorise the same
loop** — and the worst is the one that gives the compiler the most freedom.

### And what is left after that: hand-written assembly

The intrinsics kernel is already tier A and already 4.5× over the scalar loop.
Writing the same thing again in assembly would measure the assembler.
[`impl/asm/sb_diffuse_avx512.S`](../impl/asm/sb_diffuse_avx512.S) therefore
does something else — same arithmetic, different memory strategy:

> The intrinsics kernel issues **nine unaligned loads per output vector**:
> three rows times `x-1`, `x`, `x+1`. Those three read almost the same bytes.
>
> The hand-written one issues **three**. It keeps the previous, current and
> next 16-lane vector of each row in registers and manufactures the shifted
> views with `VALIGND`, which concatenates two vectors and shifts the result by
> whole doublewords across all 512 bits. Per output vector: three loads, six
> `VALIGND`, one store.

![Diffusion kernels](charts/kernels.svg)

`medium` 2048², diffusion pass only, best of three runs:

| Kernel | gcc (ms) | clang (ms) |
|---|---:|---:|
| scalar loop | 452.3 | 431.4 |
| intrinsics | 203.5 | 192.3 |
| **hand-written assembly** | **160.7** | **166.9** |
| lead over intrinsics | **21 %** | **13 %** |

All three kernels, both compilers, one grid hash: `0x0391F3BD`.

The 21 % is too good. Across five series the lead sits between 5 % and 21 %,
median about 11 %; a control measurement with nine repetitions instead of three
gave 9 % (gcc) and 13 % (clang). What stays stable across all of them: the
assembly figure itself varies half as much as the intrinsics one (161–175
against 183–213 ms). It is faster, and it is steadier.

Two side effects that are not in the table:

**The torus wrap becomes free.** The row is a power of two long, so the byte
offset of the next vector is `(xo + 64) & (rowbytes - 1)` — a single `AND`.
That makes the first and last vector of a row ordinary iterations. The
intrinsics kernel cannot express this and peels a scalar head and tail off
every row.

**The two compilers land 4 % apart** (160.7 against 166.9 ms), where they are
5 % apart on the scalar loop and 6 % apart on the intrinsics. That is how it
has to be: neither of them wrote this file.

`VALIGND` is also why this stays AVX-512. AVX2's `VPALIGNR` shifts inside the
two 128-bit halves and cannot move a lane across the middle; the same idea
costs a `VPERM2F128` per shift there and stops paying. An AVX2 version of this
file would be the intrinsics kernel written out longhand.

It is built with `ASM=1` and selected with `--asm`. `sb_asm.c` refuses with a
reason when the CPU has no AVX-512F or the width is not a multiple of 64 — the
register ring is unrolled four times over sixteen lanes — rather than quietly
computing something else.

### SIMD and threads are substitutes

Both attack the same resource. Once eight cores are working on the
bandwidth-bound diffusion pass, the bandwidth is exhausted: at T=1 SIMD buys
1.10×, at T=8 exactly 1.00×, at T=16 1.04× (earlier series). The same argument
applies to the assembly kernel — it saves loads, and loads are exactly what
runs short at eight threads.

### Effort: Rust needs more ceremony

C and C++ pick the ISA with `#ifdef __AVX512F__`, which `-march=native` sets.
Rust has `cfg!(target_feature = "avx512f")` but additionally requires
`#[target_feature(enable = "avx512f")]` on the function, which then has to be
called `unsafe`. `std::simd` would be more portable but is still nightly-only.

---

## 9. GPU (class G)

Three hosts: CUDA, a GLSL 4.3 compute shader driven from C, and the same shader
driven from Python. All `deferred` only, 100 ticks.

| Host | tiny | small | medium | large | huge |
|---|---:|---:|---:|---:|---:|
| CUDA (ms) | 8 | 16 | **44** | 191 | 1065 |
| *MCUPS* | 3202 | 6753 | **9433** | 8764 | 6300 |
| GL 4.3, C host (ms) | 214 | 660 | 2379 | 9246 | 39941 |
| *MCUPS* | 122 | 159 | 176 | 181 | 168 |
| GL 4.3, Python host (ms) | 225 | 656 | 2391 | 9321 | 39956 |
| *MCUPS* | 116 | 160 | 175 | 180 | 168 |

MCUPS is million cell updates per second — grid cells, not agents, so the
figure is comparable across presets.

### Class G does not measure the language — now demonstrated

The C host and the Python host run **the same shader**, and that is verifiable
rather than asserted: the GLSL lives in
[`impl/glcompute/shaders/`](../impl/glcompute/shaders/), the C header is
generated from it, and both hosts print an FNV-32 of their compiled source —
`0xB949F398` in both.

The times are **under 5 % apart** (under 1 % at `small` and `huge`), and every
grid hash agrees — **including the ones that deviate from the driver's**. So
the Python host reproduces the ULP deviation of Mesa's D3D12 path exactly,
which is a stronger result than both merely producing the correct answer.

Everything above the shader is independently implemented: the Python host does
its own SPEC-1 §3.3 initialisation in numpy, builds its own buffers and writes
its own uniforms. Around 200 lines against the C host's 480.

### `medium` saturates, everything above it falls off

CUDA's throughput rises to 9433 MCUPS at `medium` and falls after that — at
`huge` (8192², 67 M cells) it is back below the `small` figure. The speedup
against one C thread is already **a hundredfold** at `medium`: 44 ms against
4391. For `large` and `huge` the serial C comparison value is missing from this
series — the thread sweep only runs at `medium`, because a single C thread at
`huge` needs a good ten minutes per data point.

### CUDA is bit-exact

Verified against the C reference at all five presets, grid **and** agent hash:
identical. What that took:

1. **`-fmad=false`** — otherwise nvcc fuses `4.0f*c + acc`.
2. **`--prec-div=true`** (the default) — correctly rounded division.
3. **Integer deposit atomics.** `atomicAdd(float*)` is not deterministic; the
   arrival order of threads decides the rounding. Instead `atomicAdd(unsigned*)`
   counts the hits per cell — integer addition is exact and order-independent —
   and the multiplication by `deposit` happens once afterwards.

Point 3 brings the same limitation as `private`: with `--deposit 0.1` CUDA
diverges too. Checked, not assumed.

### GLSL: exact on one driver, not on the other

On Mesa's `llvmpipe` the GL path is bit-exact against C. On D3D12/NVIDIA it
deviates by **at most 2 ULP**: `precise` in GLSL forbids reordering and fusion
but does not force correctly rounded division — exactly what CUDA gets from
`--prec-div=true`. Class G therefore has to be graded per backend.

On the way there: at first the *agent* hash diverged as well, because `precise`
was only on the diffusion accumulator. `x + cos*step` in the agent pass is
fused too, displaces the agent by one ULP and eventually tips a sensor
comparison. That the agent hash was the one to break is what located the bug.

> The GL numbers do not measure OpenGL, they measure Mesa's D3D12 translation:
> three dispatches, three `GL_ALL_BARRIER_BITS` and one `glFinish` per tick,
> all through GL → DXIL → D3D12. Throughput stays at ~170 MCUPS across four
> orders of magnitude, which says the translation layer and not the GPU is the
> bottleneck. On a native Linux GL driver the gap to CUDA would almost
> certainly be much smaller.

### Why numpy cannot do `serial`

`serial` requires agent *i* to see agent *i−1*'s deposit from the same tick — a
sequential dependency through the grid. No numpy expression models it. The
implementation refuses the mode with exit code 3 and a reason, rather than
quietly computing something else.

In `deferred` the dependency does not exist, and `np.add.at` accumulates
unbuffered in index order — exactly the prescribed one.

---

## 10. Rendering (class R)

1024², `--freeze-sim` (simulation halted, so that only the upload path
grid → texture → screen is measured). Milliseconds per frame, median.

![Rendering](charts/render.svg)

| Language | Binding | SDL2 llvmpipe | SDL2 RTX 5080 | raylib llvmpipe | raylib RTX 5080 |
|---|---|---:|---:|---:|---:|
| C | direct | 2.883 | 4.092 | 2.036 | 1.844 |
| C++ | direct | 2.861 | 4.177 | 2.027 | 1.825 |
| Haskell | `sdl2` / `foreign import` | **2.682** | 3.995 | **1.927** | 1.821 |
| Rust | `sdl2` / `raylib` crate | 2.695 | **3.950** | 1.948 | **1.675** |
| Python | pygame / cffi | 5.238 | 5.297 | 4.325 | 4.263 |
| Perl | FFI::Platypus | 110.3 | 119.6 | 74.0 | 75.1 |

The six SDL2 and raylib frontends in C, C++ and Rust now carry a HUD; under
`--json` it is off, and its drawing time is subtracted from the frame in any
case (end of this section).

**raylib wins everywhere, and more clearly on the real GPU:** 1.4× on software,
**2.2×** on the RTX 5080, in every compiled language. The cause is the pixel
format, not the library — raylib takes the 8-bit greyscale buffer directly
(`UNCOMPRESSED_GRAYSCALE`), while SDL2 needs ARGB8888 and therefore an
expansion loop over a million pixels per frame.

**The four compiled languages land within 10 % of each other on raylib**
(1.675–1.844 ms) and within 8 % on software. Once the backend and the pixel
format are fixed, the language barely matters in this class — which is the most
interesting finding in the table, because it contradicts the class S picture.

**SDL2 is slower on the real GPU than on the software rasteriser**, in all four
compiled languages (2.8 → 4.0 ms), while raylib stays equally fast on both.
Both paths are CPU-bound at 1024²; on D3D12 SDL2 additionally pays for the
`SDL_LockTexture` path through the translation layer. A GPU-limited measurement
would need a much larger grid.

**Python is 2× behind, and the backend difference nearly vanishes.** The frame
is dominated by the numpy conversion, not the upload.

**Perl is 40–60× behind but shows the backend difference most clearly** (110
against 74 ms). Here I had expected the opposite: if the conversion dominates
the frame, both backends should come out the same, as they do for Python. They
do not, because the conversion *is* the difference — raylib wants one byte per
pixel (`pack 'C*'`), SDL2 a shifted and or-ed 32-bit word (`pack 'L*'`), and in
Perl that arithmetic costs more than everything else in the frame combined.

### Two bindings that are not the obvious ones

For **Haskell/raylib** and **Perl/raylib** the tree does not contain the
respective ecosystem package (`h-raylib`, `Raylib::FFI`) but
`foreign import ccall` and `FFI::Platypus` respectively, against the same
`/usr/local/lib/libraylib.so` that C, C++, Rust and Python link. The reason:
both packages vendor raylib and build their own copy. That would compare a
language against a *different build* of the library, and class R is supposed to
compare the language.

Both hit the same limit on the way: raylib passes `Image`, `Texture2D` and
`Color` **by value**, which neither Haskell's FFI nor Platypus can do. The five
affected calls therefore go through
[`impl/shim/raylib_shim.c`](../impl/shim/raylib_shim.c) — 30 lines of C, shared
by both. That two languages this different need the same workaround in the same
place is itself a data point about C ABIs.

---

## 11. Footprint

### No garbage collector in this benchmark does anything

Six of the fourteen languages are collected, and this document said nothing
about whether that mattered. It does not, and that is worth establishing with
numbers rather than leaving as an assumption.
[`bench/gc-stats.sh`](../bench/gc-stats.sh), `tiny`, 200 ticks after 20 of
warm-up:

| runtime | collections | GC time | allocated over the whole run |
|---|---:|---:|---:|
| **Java** | **0** | 0 ms | — |
| Go | 1 | 0.53 ms | 5.2 MiB, 298 mallocs |
| C# | 1 gen0 / 1 gen1 / 1 gen2 | — | 4.7 MiB |
| Haskell | — | 1 ms of 254 | 7.8 MiB |
| OCaml | 7 minor, 2 major | — | 12.6 MiB of minor words |

**The JVM never collects.** Go allocates 298 times in two hundred ticks, which
is startup and nothing else. The reason is structural: the simulation
allocates its grids and agent arrays once and writes into them for the rest of
the run, which is what SPEC-1 asks for and what every port does.

So the ranking in §2 is a ranking of these runtimes with their collectors
switched off in all but name. Allocation rate, pause distribution and the
throughput cost of a write barrier are among the largest differences between a
managed runtime and C, and **this benchmark exercises none of them.** That is a
limitation of the workload, not a property of the languages, and it should be
read into every row where a collected language appears.

It also explains a result that would otherwise be surprising: Java at 1.35× and
C# at 1.50× in §2 are managed runtimes performing like compiled ones, on the
one workload where the managed part is free.



| Language | Binary KiB (stripped) | RSS MiB |
|---|---:|---:|
| C (gcc / clang) | **50** | 18 |
| C++ (clang++) | 59 | 18 |
| C++ (g++) | 62 | 18 |
| **Swift** | **96** | 32 |
| Rust (unchecked) | 442 | 18 |
| Rust (safe) | 471 | 18 |
| **Go** | **1552** | 18 |
| Haskell | 2779 | 29 |
| TypeScript / Python / Perl | – (interpreted) | 18–80 |

The spread across the compiled languages is **a factor of 56**, from 50 KiB in
C to 2779 in Haskell — and all of it is runtime system, not generated code.
Swift at 96 KiB is notable: it sits closer to C++ than to Rust, because its
runtime library is linked dynamically rather than absorbed. Go pays 1.5 MiB for
a goroutine scheduler and a garbage collector — and is the language that wins
class P (§5). Fat LTO recovers 7 % of the binary size on Rust.

RSS is identical across almost all compiled languages, because the grid
dominates it (2 × 4 MiB buffers plus agent data). The only outliers are Swift
at 32 MiB and the runtimes, Node most clearly at 80 MiB.

**Class P costs memory, and very differently by strategy:** `private` needs
`T × W × H × 4` bytes — 512 MiB at `medium` with 32 threads — while `binned`
needs `N × 4` bytes plus a row histogram, so 8 MiB independent of thread count.

---

## 12. What did not work

Four attempts at optimisation, one usable result. They are here because they
cost the same work as the successful ones.

### PGO: nothing on gcc, −6 % on clang

The four-way branch on the three sensor values is data-dependent and close to
uniformly distributed. PGO can only improve *predictable* branches and learns
nothing here that the hardware predictor does not already have. The
infrastructure stays in the tree (`impl/c/pgo.sh`).

### Parallel prefix sum: −18 % where it counts

Every thread can derive its `offsets` row from `counts` alone — which removes
the serial section **and** one of five barriers. Nine runs: +9 % at T=8,
**−18 % at T=16**, ±0 at T=32. The distributions do not overlap.

`counts` has just been *written* row-wise by all T threads; having all of them
then read the whole matrix turns T² additions into T² cache-line transfers from
other cores. At T=16 (two CCDs, no SMT) that costs more than the barrier it
saves. Rejected.

### Load balancing for `binned`: +5.9 %, no more

Split row blocks by agent count instead of by row count. Correct (the hash
stays identical, because the partition only decides *which* thread deposits),
but the deposit pass is only 15 % of the runtime. Kept because it is cheap;
switch it off with `SLIMEBENCH_NO_REBALANCE=1`.

### Spin barrier: +7 % at 16 threads, −55 % at 32

16 physical cores, 32 logical. At T=16 one thread sits per core and spinning
costs nobody anything. At T=32 every spinner takes execution resources from its
SMT sibling — barrier time rises from 2.45 to 10.2 ms per tick.

`hybrid` (spin, then park on a futex) is never worse than `pthread`. The
default stays `pthread`; the choice is an environment switch
(`SLIMEBENCH_BARRIER`).

Notable how small the gain is even though barriers are half the runtime:
**the time is in the waiting, not in the waking.** A cheaper barrier does not
make an unbalanced phase shorter.

---

## 13. Proved, not measured

Everything above is evidence: a configuration was run, a hash was compared, and
the hashes agreed. That is worth a lot and it has a hard limit — it covers the
configurations somebody thought to run. Two of the spec's claims are now
machine-checked instead, in Lean, and `lake build` fails if either proof
breaks.

The proofs are in [`impl/lean/Proofs/`](../impl/lean/Proofs). Neither of them
mentions floating point.

### The binned reduction really is the serial order

SPEC-1 §5.6 claims the spatially binned parallel deposit produces exactly the
same grid as the single-threaded run, at every thread count. §5 checks that by
running eight thread counts in ten languages and comparing hashes —
`binned_deposits_eq_serial` proves it for **every** thread count, every
partition of the agents into worker blocks, and every assignment of agents to
cells.

The statement is about lists, not floats:

> For each cell, the list of agents depositing into it under the binned
> schedule equals — same elements, same order — the list under the serial
> schedule.

and the corollary `binned_cell_value_eq` folds an *arbitrary* operation over
both lists and gets the same answer. That is where floating point re-enters,
as something the theorem never looks inside. Two folds of the same operation
over the same list in the same order agree whatever the operation does, so
associativity, commutativity and rounding are all beside the point.

**This is not a convenience, it is the only available route.** Lean's `Float32`
is an opaque type whose operations are `@[extern]` calls into the runtime. The
kernel has no axioms about them, so an equation between two f32 results is not
provable in Lean at all — not hard, *impossible*. Reformulating the claim as
one about order is what makes it reachable, and it turns out to be the more
general statement anyway.

The proof needs exactly two hypotheses, and each is a line of the
implementation:

| hypothesis | where it comes from |
|---|---|
| the worker blocks concatenate to the serial order | `split()` produces contiguous, increasing ranges |
| a cell's bucket depends only on the cell | the bucket is `ybucket[idx >> log2w]` |

The C source says the partition is "identical to the C reference's,
deliberately". This is what that deliberateness buys, and the proof is why it
cannot be relaxed: an adaptive partition that reordered blocks would break the
first hypothesis and the theorem with it. §12 records the adaptive variant
being rejected on performance grounds; it would also have cost the proof.

### The bit-masked torus index is the modulo index

Every port computes `idx = ((y & ymask) << log2w) | (x & xmask)` and the spec
asserts this is `(y mod h) * w + (x mod w)`. Nothing checked it. Three
theorems now do, for every power-of-two grid and every coordinate:

- `masked_index_eq_mod` — the masked form equals the modulo form,
- `masked_index_lt` — it is always inside the grid, which is why the deposit
  needs no bounds check,
- `masked_index_injective` — distinct cells get distinct indices, which is why
  the grid can be a flat array and the checksum a linear scan.

Lean's core has no lemma for "shifting and or-ing is adding when the low part
fits", so that one is proved from bit extensionality.

### What the proofs rest on

Both files end in `#print axioms`, and CI greps the output. All six theorems
report:

```
depends on axioms: [propext, Classical.choice, Quot.sound]
```

which is Lean's standard three and nothing else — in particular no `sorryAx`.
That check exists because a proof can be broken two ways: it can fail to
compile, which is loud, or it can be admitted with `sorry`, which is silent.

### What this does not cover

The arithmetic. Nothing here says the diffusion stencil computes the right
number, that `wrapf` is correct, or that any port implements the schedule the
theorem is about — the proofs are over a model of the algorithm, and the link
from that model to fourteen implementations is still the conformance suite and
its hashes. What changed is that the parallel reduction's correctness no longer
depends on having run the right thread count.

---

## 14. Where I was wrong

The spec and the build plan have been contradicted by measurement repeatedly.
That belongs in the record, or the project reads as more error-free than it
was.

| Claim | Reality |
|---|---|
| Tier B tolerances: a uniform 1e-4 | Structurally wrong. Conserved quantities stay at 1e-9 (tolerance now **tighter**, 1e-6), structure-sensitive ones diverge under chaos (2e-2). |
| Bit-exactness costs two orders of magnitude in scripting languages | Measured 2.2× (Python) and 3.3× (Perl). |
| Thread-local buffers plus a fixed reduction order are deterministic | Only *per thread count*. Led to SPEC §5.6. |
| SIMD ⇒ conformance tier C | Tier A. No cross-lane reduction in the stencil. |
| GPU ⇒ conformance tier C | CUDA is tier A. For GLSL it depends on the driver. |
| PGO is the most plausible remaining gain | Gains nothing, hurts clang. |
| `prefix` is a serial O(T²) bottleneck | 0.000 ms of work. An artefact of my own instrumentation. |
| wgpu/WGSL as the portable GPU route | Not viable under WSL2: the NVIDIA Vulkan ICDs point at Windows DLLs. |
| The class R numbers are GPU numbers | They were software rendering (§10). |
| Idiomatic Haskell costs little | 3.7× against the low-level port (§4). |
| The Haskell port is as fast as it can be | Four characters (`(!)` → `unsafeAt`) were worth 1.46× (§4). |
| Perl's threads are the route to class P | `threads::shared` costs 7.6× per access; `fork` with packed pipes wins (§5). |
| In Perl the conversion costs so much that both render backends come out the same | The conversion *is* the difference: raylib 1.5× faster (§9). |
| Class R compares languages | On raylib four compiled languages land within 10 % (§10). |
| `medium` does not saturate the GPU | It does — `medium` is the throughput peak, everything above falls off (§9). |
| **The GL figure for `medium` was 1298 ms** | **The diffusion pass never ran.** `glDispatchCompute` is limited to 65 535 workgroups per dimension, and `medium` needs 65 536. The driver does not report this. The correct figure is 2379 ms, which makes GL over D3D12 *slower* than C on 16 threads rather than faster. |
| Once the intrinsics exist there is nothing left for hand-written assembly | About 11 % — not through better instructions, but through a third of the loads (§8). |
| Class P is won by C or C++ | **Go**, at 32 threads (§5). |
| `-Ofast` reproducibly loses a few percent on gcc | It changes sign between series. The effect only exists on clang (§3). |
| LTO gains 3 % on clang | In this series it costs 7 %. LTO is noise on this program (§3). |
| A binary that answers is the binary I built | `cargo build --bins` does not build the Rust frontends — they sit behind cargo features. Three verifications ran against a stale executable and all passed. |
| A script that works by hand works in the run | Two new scripts created their output file, changed directory, and then appended to the same relative path, which by then pointed nowhere. Tested by hand with an absolute path — which is why it survived. |
| After `preflight.sh` says "18 present, 0 missing", everything is there | Go and Swift were not on the run's PATH and were silently skipped. preflight did not check them — which is precisely its job. |
| Ten failed conformance cases mean ten cases diverge | They meant the program never started. One target carried a placeholder nothing expanded; then `resolve_exe` used `Path.resolve()` and pointed past the virtualenv at the base interpreter, which cannot see numpy. Both times the harness reported "divergence" instead of "not executable". |
| OCaml's tier-A surcharge is the boxed `Int32` the rounding allocates | The allocation count is *identical* between the two builds — the non-flambda unboxing rules do handle it. The cost is 22 PLT calls per cell into `caml_int32_bits_of_float_unboxed` and its inverse, which the assembly shows and I did not until I looked (§2). |
| Fortran's `-ffp-contract=off` is load-bearing | Not at default parameters. gfortran with `-ffp-contract=fast` emits thirteen f32 FMAs into the agent pass and still matches on all 22 conformance cases, because `--step` is 1.0 and multiplying by a power of two is exact. Sweeping `--step`: 1.0 and 2.0 agree, 1.25, 1.3, 0.7 and 3.7 diverge. The conformance suite had a blind spot, and it now has an `fma` case with `--step 1.3`. |
| `<unistd.h>` was reaching sb_barrier.h transitively through pthread.h | It was included directly, at the end of the same block. I added a second one and wrote a comment explaining a mechanism that did not exist; the actual cause was `pgo.sh` passing `-D_POSIX_C_SOURCE` without `-D_DEFAULT_SOURCE`, which hides the declaration inside `unistd.h`. Reverted. |
| Lean is blocked on which array idiom the compiler makes destructive | They all are. At 7.9 ns per element on an 8 M array a copying `set!` would be years of work, so the arithmetic refuted the question before any experiment did. Lean's arrays are copy-on-write with refcounting and a write loop is O(n) (§2). |
| Give C a better barrier and it catches Go | It does not. `SLIMEBENCH_BARRIER=hybrid` measures 651 ms at T=32 against `pthread`'s 641 and Go's 584 — the three barrier implementations C already has are within 2 % of each other, so the gap is not something a different C barrier closes (§5). |
| Putting a toolchain on PATH is harmless | Swift's toolchain ships clang 21. Prepended, it would have shadowed the system clang 18, and the compiler matrix would have gone on printing "clang". |

One pattern: **every guess about performance that I did not measure was
wrong.** The guesses about *correctness* — operation order, trig table, PRNG
choice — all held.

And a second: the two worst mistakes in this list — the skipped dispatch and
the software rendering — had in common that they produced a *plausible number*.
Both were only noticed because a scaling did not make sense, not because
anything looked broken.

The five most recent entries have the opposite in common: they produced **no
number at all**. A phase that wrote into nothing; two languages that were
skipped; a binary that answered an old question; a target that never started
and was counted ten times as "divergent". Missing output is easier to find than
wrong output — but only if you count what ought to be there. Counting rows per
file found three bugs in that session; reading the numbers found none.

One lesson from that lives in the code rather than here: `run.py` now checks
that `argv[0]` exists before running a target and says "not found, skipping"
instead of "divergence" ten times. A tool that reports *wrong* where it means
*never ran* costs more than the bug itself.

---

## 15. Open questions

- **A native Linux GL driver.** The GL numbers include Mesa's D3D12
  translation; the constant throughput of ~170 MCUPS across four orders of
  magnitude says that layer, not the GPU, is the bottleneck.
- **Class R at a grid size that saturates the GPU.** At 1024² both paths are
  CPU-bound and the comparison measures format conversion.
- **Class P for pure Python.** With `multiprocessing` it would scale almost
  linearly — but at `medium` that would be hours per data point. (The
  free-threaded CPython has arrived and is measured in §7; what remains open is
  only the pure interpreter without numpy.)
- **Why Go's barrier is cheaper, phase by phase.** §5 now measures *that* it
  is, and locates the gap in `prefix`. Why parking 31 waiters in a user-space
  scheduler beats `futex` there while losing on `merge` is the next question,
  and answering it means counting wakeups rather than timing them.
- **Class P for Lean — measured, and the answer is no.** Not "unknown" any
  more: three ownership shapes, all bit-exact, best 1.27× end to end against
  8–9× elsewhere (§2). What remains genuinely open is whether an FFI escape to
  a raw buffer would change it, which would be measuring C through Lean rather
  than Lean.
- **Class P for numba.** `@njit(parallel=True)` with `prange` releases the GIL
  and uses real threads, so Python could have thread scaling today without
  waiting for a free-threaded build — which would make §7 a comparison of three
  things rather than two. The diffusion pass is trivially parallel. The agent
  pass is the question, and the non-obvious part is that it may not need the
  `binned` machinery at all: every deposit adds the *same* constant, so a
  per-cell integer count reduced across threads and then applied as k successive
  f32 adds is bit-identical to the serial run whatever the partitioning. That is
  how the CUDA target already gets tier A (§9). What stops it being free is
  memory — a per-thread count array is T × cells, which is 512 MiB at `medium`
  with 32 threads, and avoiding that is exactly the problem `binned` solves.

- **Why the two managed runtimes' barriers collapse.** §5 measures *that*
  Java's `CyclicBarrier` and C#'s `System.Threading.Barrier` both peak at or
  before 16 threads and regress after. Whether that is spinning policy, the
  cost of parking a platform thread, or a thundering herd on wake is not
  measured, and the phase instrumentation C and Go already carry would answer
  it.

- **OCaml 5.4 has a `Float32` module.** This port runs on 4.14, where the only
  rounding available is a pair of runtime calls, and pays 5.5× for tier A. A
  third profile on a newer compiler would separate "OCaml is slow at this" from
  "OCaml 4.14 lacks the type", which is the difference the current number
  cannot express. A C stub declared `[@@unboxed] [@@noalloc]` would give a
  cheaper answer to the same question without the upgrade.

- **Whether Native AOT's parity with the JIT survives a less friendly loop.**
  §6 measures them within 3 % of each other, on a kernel that does the same
  thing every tick and takes every branch the same way — close to the best case
  for ahead-of-time compilation and the worst case for profile-guided anything.
  A workload with data-dependent branching would be the honest counter-test.

- **The HUD in Haskell, Perl and Python.** Six frontends have it, six do not.
  The 5×7 font is deliberately data in a header so a port can adopt it; the
  Rust version is generated from the C one and checked against it through a
  shared FNV hash.
- **`perf`** is unavailable under the WSL2 kernel (no matching `linux-tools`
  package). The phase timers and `hyperfine` partly replace it, but cache-miss
  counts are missing.
- **Everything here is WSL2**, not native Linux, on a machine that is also
  running Windows alongside. Within this one series that is harmless; for
  absolute values it is worth keeping in mind.
