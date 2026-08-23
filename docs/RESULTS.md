# Results

Every number in this document comes from **one** run,
[`results/run-20260823-1622/`](../results/run-20260823-1622/), commit
`8a2d2db`, produced by a single invocation of:

```bash
bench/full-run.sh --profile thorough
```

Five repetitions of every timed row, 634 of them, 105 minutes, no failures,
no empty result files and no warnings. `bench/tables.py --check` holds all
thirty-one generated tables in this file against that directory, and CI runs
it — including, since this series, the directory the header names, because a
document that cited one run and tabulated another would have passed every
check the gate had before.

The previous series raised a thread-count warning that this one does not, and
it is worth keeping the reason: Go's single-thread class P row read 160 % CPU
where one thread should be about 100. Three clean re-runs of the same command
gave 100 % each, so it was something else on the machine rather than a target
using more of it than its label claims — the check reads whole-process CPU and
cannot tell those apart from one sample. It takes a second measurement before
warning now, and warned about nothing here.

The one-run rule is the answer to a mistake in earlier versions of this file:
the numbers had accumulated over a dozen sessions on different days. Inside one
series that is harmless; across series it is quietly misleading. Nine tables
that were still typed by hand moved under the same rule for this series — the
class overview, the barrier sweeps, the `-Ofast` and bounds-check comparisons,
the intrinsics kernels and the assembly ones — because every one of them had
drifted, and three were quoting a series that no longer existed. The tables are
generated from the result directory with `bench/tables.py` and the charts from
the same directory with `bench/charts.py` — nothing here is typed by hand.

```
cpu     AMD Ryzen 9 9950X3D  (16C/32T, Zen 5, 128 MB L3)
gpu     NVIDIA RTX 5080 (84 SMs), via Mesa D3D12
os      Ubuntu 24.04 under WSL2, 46 GiB
gcc 13.3.0 · clang 18.1.3 · gfortran 13.3.0 · rustc 1.97.1 · GHC 9.10.3
go 1.27.0 · swift 6.3.3 · JDK 21.0.11 · .NET 10.0.111 · OCaml 4.14.1
Lean 4.33.0 · Node 25.5.0 · python 3.12.3 (+ 3.14t, numba 0.67) · perl 5.38.2
CUDA 12.0.140
```

Those versions are pinned in [`versions.env`](../versions.env), which the
Dockerfile, `scripts/setup-wsl.sh` and `bench/preflight.sh` all read; preflight
reports in red where the machine it is running on has drifted from them.

> **How small a difference these tables resolve is measured, not asserted.**
> Every timed row is the minimum of at least three repetitions, and carries the
> spread `(max − min) / min` across them. Rows whose spread exceeds 5 % are
> marked ⚠ and are not ranked against a neighbour closer than that. The spread
> quoted is always the one belonging to the column the table sorts by — the
> per-tick median and the wall-clock total differ by an order of magnitude in
> noise, and quoting the wrong one puts a warning beside a number nobody is
> reading. [The full rule](#how-to-read-these-numbers).

---

## Contents

Read first:

- [What this measures, and what it does not](#what-this-measures-and-what-it-does-not)
- [How to read these numbers](#how-to-read-these-numbers)

Then:

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
13. [The machine, and whether it is telling the truth](#13-the-machine-and-whether-it-is-telling-the-truth)
14. [Proved, not measured](#14-proved-not-measured)
15. [Where I was wrong](#15-where-i-was-wrong)
16. [Open questions](#16-open-questions)

---

## How to read these numbers

**Every time is the minimum of three repetitions, and every table that can
show it shows the spread beside it.**

The minimum because interference is one-sided: another process, a migration, a
page fault can only make a run slower. The fastest repetition is the best
estimate of what the code costs when nothing else is happening, where a mean
would estimate the machine's mood. The spread — `(max − min) / min` — because
a minimum on its own invites the mistake this rule was written after: two rows
differing by less than the run-to-run variation, read as a ranking.

**A gap smaller than a row's own spread is not a ranking.** Rows above 5 %
carry a marker, in the generated tables and in the run log — and each table
quotes the spread of the column it sorts by. That distinction is not
pedantry: the first version of this rule measured the spread of the total
loop time and printed it beside a column ranked on the per-tick median, which
is an order of magnitude steadier — 0.7 % against 6.7 % over the same five
runs of the same binary. It marked a quarter of the rows in a series with a
warning about a number nobody was reading. The rule lives in
one place, [`bench/run.py`](../bench/run.py), and the standalone scripts under
[`bench/`](../bench) follow it; the two exceptions are pure Python and Perl,
where a single repetition is ninety seconds and the ratio being measured is
three hundredfold.

It was written after two near misses in one sitting — a claim about 0.5 %
resting on a measurement whose own spread was 6 %, and a work/barrier split
that moved 15 % between single samples. Both were caught by looking. The rule
exists so the next one is caught by the tooling.

---

## What this measures, and what it does not

One kernel, run fourteen ways. Everything below is conditional on that kernel,
and it is a narrow one.

**What the hot loop contains.** A flat `float32` array read nine times per
cell, a second one written once; a million agents each reading three cells,
taking a four-way branch, and adding a constant to one cell. That is the whole
program.

**What it therefore never touches:**

| | |
|---|---|
| allocation | none after start-up. §11 measures the consequence: the JVM collects **zero** times in 200 ticks, Go allocates 305 times in a whole run. Six of the fourteen languages have a garbage collector and none of them is asked to collect. |
| data structures | flat arrays only. No map, no tree, no string, no object graph, nothing with a pointer in it. |
| abstraction | no dynamic dispatch, no virtual calls, no interfaces, no closures in the hot path. Every port was written to avoid them, because the spec fixes the order of operations. |
| branching | one distribution, measured: 76.6 % / 11.0 % / 11.1 % / 1.3 %. A workload whose branches are unpredictable would ask a different question of every JIT here. |
| I/O and syscalls | none inside the measured region. |
| numeric variety | `f32`, and *bit-exact* `f32`. Most numeric code does not demand that and lets the compiler reassociate; §8's fast-math rows are the only place this document lets it. |
| the machine | one CPU, one OS, one memory configuration. §16 has the list. |

**So the cross-language ranking in §2 is a ranking on flat numeric array
code.** For C, C++, Fortran and Rust that is home ground. For Java, C#, OCaml,
Haskell and Go it is the narrowest slice of what those languages are for — no
allocation, no abstraction, no collector. Java at 1.32× is a real result about
a real program, and it is not a claim that Java is 1.32× C.

**The results that do not depend on the workload this way** are the ones that
hold the program constant and change one thing about how it runs:

- the conformance result — fourteen languages producing identical bits, which
  is a property of the spec and the ports rather than of the kernel;
- the two machine-checked proofs (§14), which quantify over all thread counts
  and all inputs;
- JIT against ahead-of-time compilation (§6), interpreted against compiled
  (§6), boxed against unboxed (§2), portable vectors against intrinsics (§8),
  and the class P work/barrier split (§5) — each of those changes exactly one
  variable, with the same source on both sides.

Those are the parts worth quoting. The ranking is the part worth qualifying.

---

## 1. The short version

The same simulation in **fourteen languages**, from a Perl interpreter to 84
streaming multiprocessors, plus CUDA and GLSL compute as GPU hosts. Every
number in this document comes from the one series named at the top of this
file, on one machine, recorded in one sitting. Numbers from two different
series are not comparable and this document does not mix them.

![Class overview](charts/classes.svg)

<!-- sb:table overview -->
| Class | best configuration | `medium`, 100 ticks | vs. 1 CPU core |
|---|---|---:|---:|
| S — one thread | C, gcc `o3-native` | 3 970 ms | 1× |
| P — 32 threads | **Go**, `binned` | 532 ms | **7.5×** |
| G — GPU | cuda, sm_120 | 47 ms | **84.0×** |
| V — one thread, vectorised and spatially ordered | C, `--simd-agents --agent-tile` | 1 649 ms | **2.4×** |
<!-- /sb:table -->

Two things that are not in that table and are the most interesting results of
this series:

**Go wins class P**, not C and not C++ — 532 ms against 564 and 586. No
language reaches 10× in this series; Go's 9.4× is the best of them. §5 measures
why: at 32 threads its barrier costs 35 % less than C's (2.50 against 3.84 ms
per tick), and the gap is concentrated in the one phase where 31 workers wait
for one.

**Hand-written AVX-512 assembly beats the intrinsics by 15 %**, and not
with better instructions but with a third of the loads; §8.

**The agent pass had never been vectorised, and it is seven eighths of a
tick.** Everything class V measured until this series — five languages, plus
hand-written AVX-512 — addressed the diffusion stencil, which is 12 % of a
tick at `medium`. Vectorising the agent pass and sorting the agents into
spatial tiles is **7.6× on that phase and 3.6× on the whole program** at
`large`, against the 1.09 × vectorising the stencil returns on the same
program. The ordering alone is worth 1.6× to 3.0× in eight languages, and on a
grid that fits in cache it is a net loss. §8.

Eleven results I would not have predicted:

- **Bit-exactness survives everything.** Every tier-A run in `serial` mode
  produces `0x89CFFAAC`, every one in `deferred` mode `0x1DFDF34B` — across
  fourteen languages, five .NET compilation strategies, three JVM
  configurations, class P in ten languages at every thread count, class V in
  five languages across four vector widths, hand-written assembly, CUDA at
  every preset, Vulkan on a software device at every preset, and all 34 cells
  of the CPython matrix. The spec had assumed the opposite for both SIMD and
  GPU.
- **A language ranking from one class does not carry to the next.** Go sits at
  rank 10 of 23 in class S and wins class P. TypeScript is 3.4× slower than C in
  class S and scales as well as Go does (9.3× against 9.4×). Haskell is at 1.17×
  in class S and matches C in class R. Java is the fastest garbage-collected
  runtime in class S and the slowest of the compiled languages to scale in
  class P.
- **A Python file is at 1.18×.** `slimebench_numba.py` is the pure-Python port
  with `@njit` on the kernels — same loops, same order, same names — and 350×
  faster than it at the same conformance tier. That ratio is the cleanest
  measurement of an interpreter here, because nothing else about the program
  changed; §2.
- **Ahead-of-time compilation matches the JIT.** C# Native AOT lands within
  3 % of the optimising JIT with a full run's profile behind it, starts seven
  times faster, and has no warm-up ramp at all — 2.0× from first tick to best,
  where the JVM's is 26.0×. §6.
- **The two managed runtimes fail class P differently.** C#'s compute scales
  better than C's and its barrier costs three times as much; Java's barrier is
  nearly fine and its work stops halving after eight threads. An earlier
  version of this document blamed the barrier for both. §5.
- **Ahead-of-time compilation keeps up on branchy code too.** The agent pass
  makes a data-dependent four-way decision that goes 76.6 / 11.0 / 11.1 / 1.3,
  and Native AOT is within 1.9 % of the JIT there — against run-to-run spreads
  of 0.5–3.3 %. §6.
- **A portable vector type costs 16–22 % against hand-written intrinsics.**
  C#'s `Vector512<float>` is at 1.16× of the best AVX-512 C++ and Java's
  Vector API — naming no width at all — at 1.22×. Both land within the
  measured spread of the AVX2 intrinsics written in C (1.17×), which is to say
  this series cannot separate them from it. §8.
- **No garbage collector here does anything.** The JVM collects zero times in
  200 ticks; Go collects once, for 0.76 ms, after 305 allocations in the whole
  run. Six of the fourteen
  languages are collected and none of them is being asked to collect, which is
  a limitation of the workload that §11 now states with numbers instead of
  leaving implied.
- **Class R does not compare languages.** On raylib, four compiled languages
  land within **8 %** of each other. What matters is the pixel format.
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

<!-- sb:table s-serial -->
| # | Language | Profile | Tier | ms/tick | rel. | spread | RSS MiB |
|---:|---|---:|:-:|---:|---:|---:|---:|
| 1 | C (clang) | o3-native | A | 0.219 | 1.00× | 1.3% | 18 |
| 2 | C++ (clang++) | o3-native | A | 0.221 | 1.01× | 0.4% | 18 |
| 3 | C (gcc) | o3 | A | 0.227 | 1.04× | 1.8% | 18 |
| 4 | C++ (g++) | o3 | A | 0.227 | 1.04× | 3.5% | 18 |
| 5 | Haskell | o2-llvm | A | 0.237 | 1.08× | 1.4% | 18 |
| 6 | Swift (swift) | unchecked | A | 0.247 | 1.13× | 1.5% | 19 |
| 7 | Python (numba) | default | A | 0.253 | 1.15× | 1.1% | 166 |
| 8 | Java (javac) | default | A | 0.257 | 1.17× | 2.7% | 49 |
| 9 | Rust (unchecked) | release-native-lto-unchecked | A | 0.265 | 1.21× | 1.3% | 18 |
| 10 | Go (go) | nobounds | A | 0.277 | 1.27× | 1.5% | 18 |
| 11 | C# (dotnet) | tier1 | A | 0.292 | 1.34× | 2.0% | 30 |
| 12 | Rust (safe) | release | A | 0.296 | 1.35× | 0.8% | 18 |
| 13 | Fortran (gfortran) | o2 | A | 0.301 | 1.38× | 1.9% | 18 |
| 14 | OCaml (f64) | default | B | 0.337 | 1.54× | 3.0% | 18 |
| 15 | TypeScript | default | A | 0.653 | 2.98× | 7.6% ⚠ | 79 |
| 16 | OCaml (strict-f32) | cstub-unsafe | A | 0.930 | 4.25× | 3.0% | 18 |
| 17 | Lean (lake) | default | A | 1.468 | 6.71× | 4.7% | 18 |
| 18 | Perl (plain) | default | B | 38.184 | 174.51× | 8.2% ⚠ | 22 |
| 19 | Python (pure) | default | B | 38.242 | 174.78× | 4.5% | 18 |
| 20 | Python (pure-strict) | default | A | 86.755 | 396.50× | 1.2% | 18 |
| 21 | Perl (strict-f32) | default | A | 124.627 | 569.59× | 2.2% | 22 |
<!-- /sb:table -->

**Every tier-A run in this mode: `0x89CFFAAC`.**

Measured after 50 warm-up ticks. That matters for three rows and for nothing
else: Java, C# and numba are the only targets not at full speed on tick 1, and
without it their *median* over a hundred cold ticks lands mid-ramp. §6 is where
the cold measurement lives, on purpose.

### `--update deferred`

Here numpy and the idiomatic Haskell version can compete as well.

<!-- sb:table s-deferred -->
| # | Language | Profile | Tier | ms/tick | rel. | spread | RSS MiB |
|---:|---|---:|:-:|---:|---:|---:|---:|
| 1 | C (clang) | o3-native | A | 0.216 | 1.00× | 2.4% | 18 |
| 2 | C++ (clang++) | o3-native | A | 0.223 | 1.03× | 7.8% ⚠ | 18 |
| 3 | C++ (g++) | o3 | A | 0.228 | 1.05× | 0.9% | 18 |
| 4 | C (gcc) | o3 | A | 0.229 | 1.06× | 0.9% | 18 |
| 5 | Swift (swift) | unchecked | A | 0.251 | 1.16× | 3.9% | 19 |
| 6 | Haskell | o2-llvm | A | 0.253 | 1.17× | 3.2% | 18 |
| 7 | Python (numba) | default | A | 0.254 | 1.18× | 6.2% ⚠ | 167 |
| 8 | Java (javac) | c2 | A | 0.255 | 1.18× | 2.2% | 49 |
| 9 | Rust (unchecked) | release-native-unchecked | A | 0.263 | 1.22× | 2.8% | 18 |
| 10 | Go (go) | nobounds | A | 0.291 | 1.34× | 1.7% | 18 |
| 11 | Rust (safe) | release | A | 0.301 | 1.39× | 1.5% | 18 |
| 12 | Fortran (gfortran) | o3 | A | 0.308 | 1.42× | 1.2% | 18 |
| 13 | C# (dotnet) | aot-native | A | 0.318 | 1.47× | 2.1% | 18 |
| 14 | OCaml (f64) | default | B | 0.383 | 1.77× | 2.4% | 18 |
| 15 | Haskell (vector) | o2-llvm-vector | A | 0.506 | 2.34× | 5.1% ⚠ | 23 |
| 16 | TypeScript | default | A | 0.729 | 3.37× | 11.3% ⚠ | 81 |
| 17 | OCaml (strict-f32) | cstub-unsafe | A | 0.983 | 4.55× | 2.4% | 18 |
| 18 | Python (numpy) | default | A | 1.269 | 5.87× | 6.4% ⚠ | 45 |
| 19 | Lean (lake) | o3-native | A | 2.298 | 10.63× | 2.0% | 18 |
| 20 | Python (pure) | default | B | 41.520 | 192.03× | 3.7% | 18 |
| 21 | Perl (plain) | default | B | 45.062 | 208.41× | 6.3% ⚠ | 29 |
| 22 | Python (pure-strict) | default | A | 91.148 | 421.57× | 1.9% | 18 |
| 23 | Perl (strict-f32) | default | A | 132.410 | 612.40× | 2.5% | 24 |
<!-- /sb:table -->

**Every tier-A run in this mode: `0x1DFDF34B`.**

Worth noting:

- **Nine languages sit inside a 27 % band between 1.16× and 1.47×**, and that
  band contains a lazy functional language compiled through LLVM, a systems
  language with refcounting, a Python decorator, two managed runtimes with
  garbage collectors, Rust twice, Fortran and Go. The ordering inside it is not
  dependable; the fact that they are all there is.
- **numba, at 1.18×, is a Python file.** It is
  [slimebench_pure.py](../impl/python/slimebench_pure.py) with `@njit` on the
  kernels — the same loops, the same order, the same variable names — and it
  is 359× faster than that file at the same conformance tier. See the
  subsection below; that ratio is the cleanest measurement of an interpreter
  in this document, because nothing else about the program changed.
- **Haskell is in sixth place, ahead of Java, Rust and Go** — and in `serial`
  it is fifth, ahead of Swift as well. §4 has the reason: one change
  (`Data.Array.Unboxed.(!)` → `unsafeAt`) was worth 1.5×.
- **Java at 1.18× is the fastest garbage-collected runtime here**, and it needs
  no `strictfp`: JEP 306 made floating point strict in Java 17, and the JLS has
  never allowed a JIT to fuse a multiply-add. Its cost is elsewhere — §6 has
  the warm-up curve, which is 26× from the first tick to the best one.
- **Fortran, at 1.42×, is slower than four garbage-collected or JIT-compiled
  languages.** It is also the only port in the project that needed no argument
  for exactness: native single precision since 1957 and an arithmetic model
  that says what it does. That combination is the finding, not the rank.
- **OCaml is 4.6×, and it is not the language that is slow.** Its `float array`
  is unboxed and the same program with f64 intermediates runs at 1.77× — the
  4.6× is what conformance tier A costs when the language has no float32 type.
  Without the C stub described below it is 9.2×, which is where this section
  used to quote it from.
- **OCaml now beats Lean, and it did not before.** Lean is at 10.6× in
  `deferred` and 6.7× in `serial`; OCaml is at 4.6× and 4.3×. That ordering is
  the reverse of the one an earlier version of this document reported, and
  nothing about Lean changed — the C stub below took OCaml's rounding from two
  runtime calls to one. Lean boxes every array element and OCaml does not, so
  the memory models still predict the old ordering; one call's worth of
  arithmetic outweighs them.
- **Perl and pure Python are within 0.2 %** of each other at tier B in `serial`
  (38.18 vs 38.24 ms/tick), and 8 % apart in `deferred`. Interpreter dispatch
  dominates so completely that the language difference disappears; which is
  ahead changes between modes and between series.
### What Lean pays, and where

Lean is in the tables above at 10.6× in `deferred` and 6.7× in `serial`, and
three things about how it gets there are worth keeping.

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

For comparison, the other ten languages reach 4.4× to 9.4× on the same
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

Two things follow, and the second one has since been acted on.

Exactness in OCaml is expensive for a reason that is a missing intrinsic
rather than a property of the language. And **it is only two calls where the
hardware needs two instructions, so one call is cheaper than two.** A C stub
declared `[@@unboxed] [@@noalloc]` does the whole conversion in a single call:

| | ns/op on a dependency chain | ms/tick at 256² | vs C |
|---|---:|---:|---:|
| no rounding (tier B, f64) | 2.25 | 0.383 | 1.8× |
| `Int32` round-trip | 7.03 | 1.978 | 9.2× |
| **one C stub** | **5.04** | **0.983** | **4.6×** |

The ns/op column is a standalone microbenchmark and does not move with the
series; the other two are `deferred` rows from it.

**2.01× for one line**, bit-identical, full conformance set — and it moves
OCaml past Lean, which the earlier version of this section had ahead of it.
The microbenchmark is in [`impl/ocaml/f32_stub.c`](../impl/ocaml/f32_stub.c)
and it has to put the rounding *on* the dependency chain: measured beside it,
the round-trip looks almost free, because what costs is latency the chain
cannot hide.

The `cstub` profile rewrites one line of `sim.ml` at build time rather than
keeping two sources or branching at run time. A `float -> float` argument
without flambda is an indirect call, and it would be charged to both halves of
the comparison.

What remains true is the shape: Lean boxes every array element and has a
native `Float32`; OCaml has an unboxed array and no `Float32` at all. The two
ML-family ports pay opposite tolls. What changed is the size of OCaml's, once
it stopped paying it twice per rounding.

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

| Target | tier | grid hash | ms/tick | spread | vs numba |
|---|:-:|---|---:|---:|---:|
| python pure | B | `0x44625B3D` | 9.6213 | — | 153× |
| python pure `--strict-f32` | A | `0xB1D75130` | 21.6582 | — | **345×** |
| **numba** | **A** | `0xB1D75130` | **0.0627** | 0.7% | 1.00× |
| numba `--fastmath` | C | `0xF9B2609A` | 0.0638 | 0.6% | 1.02× |
| c gcc `-O2` | A | `0xB1D75130` | 0.0637 | 10.1% ⚠ | 1.02× |

**Against the honest comparison — tier A against tier A — CPython costs 345×.**
Not 153×: the tier-B row is a different computation, one that happens to be
cheaper because it is wrong. And what is left after the interpreter is removed
is nothing measurable: numba runs the identical source at **0.98× of gcc
`-O2`**, which is to say the two cannot be separated here.

> The bottom three rows are the least solid numbers in this section, and which
> one carries the warning has moved. At 128² a tick is 63 microseconds, and in
> this series it is the *C* row whose repetitions spread 10.1 % while numba's
> spread 0.7 % — last series it was the other way round. Neither ordering
> survives repetition, which is the finding: at this size the measurement is
> mostly scheduling noise. The gap between numba and gcc is real in the class S
> table at 256², where both rows are steady (1.18× against C's best, spreads
> under 3 %); read the 0.98× as "the same order", not as a ranking. The 345× is
> unaffected: it is a ratio between numbers three orders of magnitude apart.

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
| c gcc `-O3 -march=native` | 0.2497 |
| **numba** (scalar loops) | **0.2542** |
| numpy (vectorised) | 1.2794 |

**The scalar loops through a JIT are 5.0× faster than the vectorised numpy
version** — and they can do `serial`, which numpy structurally cannot (§9).
The numpy target exists because in 2015 it was the only answer; it is kept
because it is a fair measurement of that answer, not because it is the good one.

What numba charges instead is up front: compiling the seven kernels takes
about 0.67 s. That is not in any number above, because
[`_precompile()`](../impl/python/slimebench_numba.py) compiles them against a
4×4 grid before the clock starts. Leaving it to `--warmup` would work too, and
would silently turn `ms_per_tick_p99` into a compiler benchmark whenever
someone omitted the flag — the failure shape §15 is a list of.

### `--fastmath`: the grid hash catches it, the agent hash does not

`--fastmath` compiles the *identical source text* with LLVM's fast-math flags.
It is therefore the cheapest available demonstration of what conformance tier C
is for: one program, one flag, two tiers.

It is also not faster. In this series it is 1.8 % *slower* — 0.0638 against
0.0627 ms/tick — and in the class S table above it wins by 1 % in both modes.
Across five measurements it has no consistent sign,
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

<!-- sb:table compilers -->
| Language | Compiler | Profile | Tier | ms | rel. | spread | Binary KiB |
|---|---|---:|:-:|---:|---:|---:|---:|
| C | gcc | o3 | A | 1 236 | 1.00× | 6.6% ⚠ | 66 |
| C++ | g++ | o3 | A | 1 269 | 1.03× | 3.2% | 78 |
| C++ | g++ | ofast-native | C | 1 287 | 1.04× | 1.9% | 78 |
| C | clang | o3-native | A | 1 295 | 1.05× | 3.5% | 66 |
| C++ | g++ | o3-native | A | 1 296 | 1.05× | 5.1% ⚠ | 78 |
| C | clang | o3-native-lto | A | 1 314 | 1.06× | 5.8% ⚠ | 66 |
| C++ | clang++ | o3-native | A | 1 319 | 1.07× | 2.8% | 67 |
| C++ | clang++ | o3-native-lto | A | 1 355 | 1.10× | 2.1% | 67 |
| C | gcc | o3-native | A | 1 367 | 1.11× | 4.3% | 74 |
| C | gcc | o2 | A | 1 372 | 1.11× | 1.6% | 58 |
| C++ | g++ | o3-native-lto | A | 1 374 | 1.11× | 3.9% | 70 |
| C | gcc | ofast-native | C | 1 377 | 1.11× | 11.0% ⚠ | 74 |
| C++ | g++ | o2 | A | 1 404 | 1.14× | 3.8% | 66 |
| Java | javac | default | A | 1 479 | 1.20× | 10.4% ⚠ | — |
| C | gcc | o3-native-lto | A | 1 501 | 1.21× | 3.0% | 66 |
| Haskell | ghc | o2-llvm | A | 1 516 | 1.23× | 3.8% | 2 881 |
| Go | go | nobounds | A | 1 516 | 1.23× | 3.6% | 1 564 |
| Java | javac | c2 | A | 1 519 | 1.23× | 10.4% ⚠ | — |
| C++ | clang++ | o2 | A | 1 524 | 1.23× | 1.4% | 63 |
| C | clang | o3 | A | 1 541 | 1.25× | 2.1% | 62 |
| C++ | clang++ | o3 | A | 1 543 | 1.25× | 3.0% | 63 |
| C | clang | o2 | A | 1 551 | 1.25× | 11.3% ⚠ | 62 |
| Go | go | default | A | 1 626 | 1.32× | 9.6% ⚠ | 1 612 |
| Swift | swift | release | A | 1 634 | 1.32× | 2.2% | 108 |
| Rust | cargo | release-native-unchecked | A | 1 636 | 1.32× | 5.1% ⚠ | 481 |
| C# | dotnet | tier1 | A | 1 650 | 1.33× | 11.1% ⚠ | — |
| Fortran | gfortran | ofast-native | C | 1 658 | 1.34× | 9.7% ⚠ | 78 |
| Fortran | gfortran | o2 | A | 1 674 | 1.35× | 11.8% ⚠ | 74 |
| Rust | cargo | release-native-lto-unchecked | A | 1 680 | 1.36× | 11.6% ⚠ | 448 |
| Swift | swift | unchecked | A | 1 692 | 1.37× | 3.8% | 100 |
| Fortran | gfortran | o3 | A | 1 717 | 1.39× | 9.8% ⚠ | 78 |
| C# | dotnet | r2r | A | 1 723 | 1.39× | 3.7% | — |
| C# | dotnet | aot | A | 1 732 | 1.40× | 2.7% | — |
| Fortran | gfortran | o3-native | A | 1 734 | 1.40× | 2.6% | 78 |
| Rust | cargo | release-unchecked | A | 1 745 | 1.41× | 13.5% ⚠ | 476 |
| C# | dotnet | aot-native | A | 1 750 | 1.42× | 4.3% | — |
| Rust | cargo | release | A | 1 758 | 1.42× | 10.3% ⚠ | 478 |
| C# | dotnet | jit | A | 1 779 | 1.44× | 4.0% | — |
| Rust | cargo | release-native | A | 1 813 | 1.47× | 2.7% | 484 |
| C | clang | ofast-native | C | 1 859 | 1.50× | 3.4% | 66 |
| C++ | clang++ | ofast-native | C | 1 879 | 1.52× | 1.9% | 67 |
| Haskell | ghc | o2 | A | 1 991 | 1.61× | 2.6% | 2 853 |
| Haskell | ghc | o1 | A | 3 612 | 2.92× | 2.1% | 2 797 |
| C | clang | o0 | A | 4 000 | 3.24× | 5.3% ⚠ | 67 |
| C++ | clang++ | o0 | A | 4 514 | 3.65× | 3.5% | 159 |
| C | gcc | o0 | A | 5 061 | 4.09× | 5.3% ⚠ | 138 |
| C++ | g++ | o0 | A | 5 370 | 4.34× | 2.0% | 170 |
| OCaml | ocamlopt | default | A | 10 470 | 8.47× | 4.9% | 1 182 |
| OCaml | ocamlopt | unsafe | A | 10 569 | 8.55× | 4.1% | 1 178 |
| Java | javac | int | A | 27 709 | 22.42× | 2.6% | — |
<!-- /sb:table -->

**Every tier-A run agrees.** The four fast-math builds diverge, and they
diverge *differently per compiler* — which is exactly why fast-math is a
conformance tier of its own.

### `-Ofast` costs clang half its speed and gcc nothing

<!-- sb:table ofast -->
|  | `-O3 -march=native` | `-Ofast -march=native` | Δ |
|---|---:|---:|---:|
| C, clang | 1 295 ms | 1 859 ms | **+44 %** |
| C++, clang++ | 1 319 ms | 1 879 ms | **+42 %** |
| C, gcc | 1 367 ms | 1 377 ms | +1 % |
| C++, g++ | 1 296 ms | 1 287 ms | −1 % |
<!-- /sb:table -->

On clang the effect is large, reproducible and points the wrong way: freedom to
reassociate lets it reorder the nine-point stencil into something worse. The
diffusion pass alone rises from 289 to 850 ms, and the whole of the loss is
there — the agent pass does not move.

**On gcc it is not an effect at all.** Three series have measured +3 %, −2 %
and +1 % here. Something that changes sign between measurements is not an
effect. What remains: you pay for determinism and get nothing measurable on
gcc, and a large loss on clang.

### clang wins — but only with `-march=native`

`-O2`: gcc 1372 ms, clang 1551 ms. `-O3 -march=native`: gcc 1367 ms, clang
1295 ms. Compare only `-O2` and you conclude "gcc is 13 % faster"; add
`-march=native` and you conclude "clang is 6 % faster". Same source. The
margins move between series; the reversal has now survived four.

### LTO is noise

clang 1295 → 1314 ms with LTO, gcc 1367 → 1501, g++ 1296 → 1374, clang++
1319 → 1355. So in this series LTO costs between 1 and 10 % everywhere; in an
earlier one it gained 3 % on clang and cost 1 % on gcc. On Rust it is likewise
in the noise at 1636 → 1680. The only dependable statement is that LTO does
nothing measurable to this program — it is one translation unit's worth of
work spread over four files.

### Bounds checks: Rust 11 %, Go 7 %, Swift nothing at all

<!-- sb:table bounds -->
| Language | with checks | without | cost |
|---|---:|---:|---:|
| Rust | 1 813 ms (`release-native`) | 1 636 ms (`-unchecked`) | **11 %** |
| Go | 1 626 ms (default) | 1 516 ms (`-gcflags=all=-B`) | 7 % |
| Swift | 1 634 ms (`release`) | 1 692 ms (`-Ounchecked`) | −3 % |
<!-- /sb:table -->

The breakdown this series gives for Rust is the same shape an earlier one
found: the diffusion pass goes 417 → 285 ms without the checks, a third of it,
while the agent pass moves by 3 %. The checks get in the way of vectorising
the stencil; in the agent pass the CPU is waiting on cache misses anyway.
"Bounds checking costs nothing" and its opposite are both wrong — it depends on
the access pattern, and this benchmark happens to have both kinds in one
program.

**Swift's `-Ounchecked` is worth nothing here, and this series it is worth
less than nothing** — 1 692 ms against 1 634 with the checks left in, a 3 %
loss. Two earlier series put it at a 6 % gain, so the honest reading is that
the flag does not move this program and the sign is noise. That is a different
statement from Rust's, where the same comparison has been a double-digit gain
every time.

Go and Swift paying less than Rust is not down to better checks. Their
diffusion loops are not vectorised as far as LLVM takes Rust's in the first
place, so there is less to lose.

### GHC: the LLVM backend is worth it

`-O1` 3612 ms, `-O2` 1991 ms, `-O2 -fllvm` **1516 ms**. The LLVM backend buys
**24 %** over the native code generator, for 1 % more binary size. All three
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
constants. Replaced by `unsafeAt`: **1.48×** on total runtime — and the index
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

> **Class P is the one section that does not follow the statistics rule.**
> Every row here is a single measurement: the sweep is twelve languages × six
> thread counts × up to three reduction strategies, and repeating each point
> would make it by far the longest phase in the run. So these rows carry no
> spread column, and they should not be read to two significant figures.
>
> How much that matters is measurable, because this table was recorded twice
> forty minutes apart on an otherwise idle machine: C's single-thread baseline
> came out 4 227 ms and 5 351 ms, a 21 % swing, and its speedup moved from
> 7.4× to 8.2×. Comparisons *within* one sweep are on firmer ground — every
> language ran in the same session, in the same thermal state — but a 0.5×
> difference in the speedup column is not a finding, and the ordering of
> languages within half a turn of each other is not either.

### `binned` — bit-identical to the serial run

<!-- sb:table p-binned -->
| Language | T=1 | T=2 | T=4 | T=8 | T=16 | T=32 | Speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| Go | 4 983 | 2 184 | 1 534 | 819 | 578 | 532 | 9.4× |
| TypeScript | 10 909 | 3 972 | 2 233 | 1 519 | 1 168 | 1 317 | 9.3× |
| Swift | 5 580 | 2 344 | 1 528 | 908 | 685 | 895 | 8.1× |
| C++ | 4 264 | 2 148 | 1 194 | 831 | 655 | 564 | 7.6× |
| Haskell | 4 912 | 1 926 | 1 140 | 750 | 664 | 732 | 7.4× |
| C | 4 250 | 2 166 | 1 149 | 800 | 632 | 586 | 7.3× |
| Rust | 5 557 | 2 624 | 1 693 | 942 | 878 | 1 044 | 6.3× |
| C# | 6 513 | 2 612 | 1 801 | 1 092 | 1 212 | 1 880 | 6.0× |
| Java | 4 895 | 1 969 | 1 305 | 990 | 1 000 | 1 303 | 4.9× |
| Python | 7 964 | 5 759 | 3 202 | 2 190 | 1 826 | 2 199 | 4.4× |
<!-- /sb:table -->

Two languages are missing from that table because neither implements
`binned`: Fortran reduces with an atomic and Perl by replication across
processes. Both have their own table below, and neither number belongs in a
column headed by a strategy it does not use.

**The two managed runtimes come last, and it is not for the same reason.**

Both peak at or before 16 threads and then regress, and an earlier version of
this section said the barrier was why. C and Go could report their own
work/barrier split; Java and C# could not, so that was a guess — and it was
right about one of them.

They can report it now. [`bench/barriers.sh`](../bench/barriers.sh), `medium`,
`binned`, worker 0, best of three, ms per tick. **Work per thread should halve
every time the thread count doubles:**

<!-- sb:table barrier-work -->
| T | C | Go | Java | C# |
|---|---:|---:|---:|---:|
| 4 | 15.21 | 14.33 | 13.28 | 14.00 |
| 8 | 7.57 | 5.60 | 8.88 | 8.39 |
| 16 | 4.79 | 3.12 | 4.91 | 4.04 |
| 32 | 2.62 | 1.87 | 6.03 | 2.33 |
| **T=4 → T=32** | 5.8× | 7.6× | 2.2× | 6.0× |
<!-- /sb:table -->

And the barrier:

<!-- sb:table barrier-wait -->
| T | C | Go | Java | C# |
|---|---:|---:|---:|---:|
| 4 | 0.71 | 1.07 | 0.68 | 2.15 |
| 8 | 3.10 | 2.26 | 2.39 | 2.85 |
| 16 | 3.06 | 2.06 | 5.27 | 5.67 |
| 32 | 3.84 | 2.50 | 6.18 | 11.82 |
<!-- /sb:table -->

**C# is a barrier problem, and only a barrier problem.** Its compute scales
better than C's — 6.0× against 5.8×, and at 32 threads it does the work in
2.33 ms where C needs 2.62. Its barrier goes from 2.15 ms to 11.82. The
per-phase breakdown says this is not contention over any particular structure:
every crossing costs about 2.4 ms, *including* `prefix`, where one thread
computes an offset table and thirty-one wait for it.

<!-- sb:table barrier-phase-csharp -->
| phase | C# work | C# barrier |
|---|---:|---:|
| agents | 1.539 | 2.297 |
| prefix | 0.001 | 2.497 |
| scatter | 0.124 | 2.261 |
| deposit | 0.211 | 2.354 |
| merge | 0.225 | 2.354 |
<!-- /sb:table -->

A flat per-crossing cost is what `System.Threading.Barrier` charges at 32
participants, and the tick crosses it five times.

**Java is not a barrier problem.** Its barrier at 32 threads is 6.18 ms
against C's 3.84 — worse, but not by enough to explain anything. What does not
happen is the work halving: Java has the *fastest* per-thread work in the
field at four threads, halves once more to 16, then goes back *up* at 32, where
it is doing 2.3× as much per thread as C.

Why is not measured. The candidates are the machine's two core complexes and
whatever thread placement the JVM does across them, or a spin-then-park
barrier whose parking is being counted as work when a thread is descheduled
mid-phase. Distinguishing those needs wakeup counts rather than wall clock,
and §15 says so rather than this section guessing again.

The instrumentation itself costs 1.01–1.03× of the tick it measures in this
series, which the script reports alongside — a breakdown that changed the
thing being broken down would not be worth reading.

Both use their standard library's: Java `java.util.concurrent.CyclicBarrier`,
C# `System.Threading.Barrier`. That is deliberate — §5 is about where the
languages actually differ, and substituting a hand-rolled barrier would replace
the thing being measured with a copy of someone else's answer. The consequence
is that the class P ranking at 32 threads is a ranking of barrier
implementations, which is what the phase breakdown below shows directly.

### `atomic` — Fortran, in three directives

`!$omp parallel do` over the agent pass, `!$omp atomic` on the deposit, and
`!$omp parallel do` over the diffusion stencil. No bin buffers, no prefix sum,
no scatter, no explicit barrier — the reduction is a locked add and OpenMP
closes each parallel region itself.

<!-- sb:table p-atomic -->
| Language | T=1 | T=2 | T=4 | T=8 | T=16 | T=32 | Speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| Fortran | 6 013 | 2 887 | 1 442 | 901 | 736 | 731 | 8.2× |
<!-- /sb:table -->

**And it is tier A for every thread count**, `0xB4AC535B / 0x6A2394F4` from
T=1 to T=32. That is not a property of the atomic; it is a property of the
workload. SPEC-1's deposit adds a *constant*, so a cell's final value is its
starting value plus a count, and no order of arrival can change it. Swap the
constant for anything that depends on the agent and the atomic stops being
bit-exact immediately, while `binned` keeps working — which is why the spec
defines `binned` and not this.

Within that limit it is among the cheapest parallelism in the document:
**8.2× on three directives**, behind only Go, TypeScript and Swift, each of
which needed a hand-written binned reduction with six barriers per tick to get
there. The peak is at T=16 and the regression at T=32 is the same one every
other language shows. Subject to the caveat above — across three sweeps the
same three directives have measured 8.2×, 8.4× and 9.6×, and sat in the same
place each time.

The measured T=1 baseline here is the reason [`bench/full-run.sh`](../bench/full-run.sh)
now passes `--threads` explicitly at every thread count and times the T=1 rows
under `/usr/bin/time`; see §15.

### `private` — reproducible per thread count only

<!-- sb:table p-private -->
| Language | T=1 | T=2 | T=4 | T=8 | T=16 | T=32 | Speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| C# | 6 513 | 2 050 | 1 294 | 1 317 | 2 580 | 5 914 | 5.0× |
| Swift | 5 580 | 1 827 | 1 160 | 1 139 | 2 348 | 5 970 | 4.9× |
| Haskell | 4 912 | 1 736 | 1 151 | 1 099 | 2 597 | 6 480 | 4.5× |
| TypeScript | 10 909 | 6 331 | 3 704 | 2 445 | 3 005 | 6 162 | 4.5× |
| Go | 4 983 | 1 855 | 1 191 | 1 142 | 2 331 | 5 453 | 4.4× |
| Rust | 5 557 | 2 824 | 1 716 | 1 351 | 2 620 | 5 723 | 4.1× |
| Java | 4 895 | 1 965 | 1 267 | 1 289 | 2 657 | 6 284 | 3.9× |
| C++ | 4 264 | 2 459 | 1 492 | 1 221 | 2 566 | 6 028 | 3.5× |
| Python | 7 964 | 4 931 | 2 882 | 2 324 | 2 402 | 3 255 | 3.4× |
| C | 4 250 | 2 490 | 1 536 | 1 269 | 2 627 | 6 100 | 3.3× |
<!-- /sb:table -->

**At 32 threads `private` drops below the single-thread runtime** — in C to
6100 ms against 4250. The reduction reads `T` complete grids: at `medium` with 32
threads that is 512 MiB of memory traffic per tick, purely to add deposits
together. `binned` needs 8 MiB for the same job, independent of thread count.
So the strategy you naively write first is not only the weaker guarantee, it is
also the slower one from eight threads on.

### Go wins class P

At 32 threads Go is the fastest implementation in the field at **532 ms**,
ahead of C++ (564) and C (586) — from a 17 % single-thread deficit against C.
It is also the only language whose `binned` curve still falls at 32 threads;
C, C++, Haskell, Rust and Swift bottom out at 16 or turn back up after it.

The shape of the curve says where to look: at T=4 Go is *well behind* C
(1534 against 1149 ms) and at T=32 it is ahead, so the advantage grows with the
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
repetition. **The barrier is not**: Go's is consistently cheaper, outside the
run-to-run spread of either. That careful three-run measurement put the gap at
17 %; the single-sample sweep above puts it at 35 % (2.50 ms against 3.84).
Take the smaller figure as the one with error bars on it and the sign as the
result.

The difference concentrates in one phase. `prefix` is the step where worker 0
computes the offset table alone and the other 31 wait:

<!-- sb:table barrier-cgo -->
| Phase | C barrier | Go barrier | C / Go |
|---|---:|---:|---:|
| prefix | 0.654 | **0.197** | 3.3× |
| agents | 1.182 | **0.507** | 2.3× |
| scatter | 0.649 | **0.444** | 1.5× |
| deposit | 0.689 | **0.620** | 1.1× |
| merge | 0.758 | **0.752** | 1.0× |
<!-- /sb:table -->

Go is 3.3× cheaper on the most one-sided wait in the tick and level on
`merge`, where all 32 workers arrive at roughly the same moment — the gap
shrinks monotonically as the wait becomes less one-sided. That is the shape one
would expect if parking a waiter in a user-space scheduler is cheap and waking
a thundering herd of them is not. An earlier series had Go actually *losing*
`merge`, which would have been the stronger version of the same story; this one
has it level, so the second half stays a hypothesis.

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
times instead of once, and that is what caps the speedup: only the agent
pass is parallel.

<!-- sb:table p-replicated -->
| Language | T=1 | T=2 | T=4 | T=8 | T=16 | T=32 | Speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| Perl | 4 118 | 2 345 | 1 699 | 1 513 | 1 763 | 2 671 | 2.7× |
<!-- /sb:table -->


### The bottleneck is the barriers

`SLIMEBENCH_PHASE_STATS=1` separates work from barrier wait
(C, `medium`, T=32, thread 0), milliseconds per tick:

<!-- sb:table barrier-phase -->
| Phase | work | barrier | total |
|---|---:|---:|---:|
| agents | 1.945 | 1.182 | 3.127 |
| prefix | **0.001** | 0.654 | 0.655 |
| scatter | 0.065 | 0.649 | 0.714 |
| deposit | 0.268 | 0.689 | 0.957 |
| merge | 0.208 | 0.758 | 0.966 |
| diffuse | 0.214 | — | 0.214 |
<!-- /sb:table -->

**Barriers are 39 % of the runtime at T=16 and 59 % at T=32.** Past sixteen
threads C stops getting faster not because the work stops dividing — it keeps
dividing, 6.61 ms per tick at T=16 against 3.36 at T=32 — but because the
waiting grows faster than the work shrinks. The prefix sum, previously
suspected of being a "serial O(T²) section", does 0.001 ms of measurable
work.

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

<!-- sb:table ramp -->
| ticks | Java tiered | Java C2-only | C# jit | C# tier1 | **C# aot** |
|---|---:|---:|---:|---:|---:|
| 1-5 | 3.349 | 3.751 | 1.004 | 0.895 | 0.421 |
| 6-10 | 0.499 | 1.017 | 0.409 | 0.361 | 0.352 |
| 11-25 | 0.427 | 0.365 | 0.365 | 0.302 | 0.307 |
| 26-50 | 0.408 | 0.254 | 0.340 | 0.284 | 0.296 |
| 51-100 | 0.250 | 0.260 | 0.339 | 0.293 | 0.292 |
| **first tick** | **6.079** | **6.022** | **3.194** | **2.912** | **0.536** |
| best tick | 0.234 | 0.233 | 0.320 | 0.269 | 0.274 |
| **first / best** | **26.0×** | **25.9×** | **10.0×** | **10.8×** | **2.0×** |
<!-- /sb:table -->

**The JVM's first tick costs 26× its best one.** A benchmark of a hundred ticks
that forgot `--warmup` would report a number the JVM never actually runs at —
which is not hypothetical: both the class S and the class V phases of this
project did exactly that until the series this document is built from, and
class V had Java's vector kernel at 179 ms of diffusion against C's 64. With
the warm-up it is 81.6.

Two smaller results in the same table. **Turning tiering off makes the JVM
reach steady state sooner, not later** — C2-only is already at 0.251 by tick 26
where tiered is still at 0.402, and only catches up at 51. The intuition that
skipping C1 means a longer slow phase is the wrong way round here: C1 code is
slower than the interpreter is fast, and having to climb out of it costs more
than compiling once. And **.NET's ramp is well under half the JVM's** — 10.0×
against 26.0× — but it converges to a worse number.

**Native AOT is flat.** 2.0× from first tick to best, and the first tick is
0.536 ms against the JVM's 6.079. There is no ramp because there is no
compiler.

### What the profile information buys: nothing

Steady state, warm-up 50, best of three:

| Configuration | ms/tick | vs tier1 |
|---|---:|---:|
| C# jit (tiered + dynamic PGO) | 0.3430 | 1.16× |
| C# tier1 (no tiering) | 0.2958 | 1.00× |
| C# ReadyToRun | 0.2923 | 0.99× |
| **C# Native AOT** | **0.2951** | **1.00×** |
| Java C2-only | 0.2558 | — |
| C gcc `-O3 -march=native` | 0.2532 | — |

**Native AOT lands within 2.4 % of the optimising JIT with a full run's
profile behind it** — 0.2951 against 0.2958. Same optimiser, one with the data
the running program produced and one with none, and on this workload the data
is worth nothing measurable. The 19 % the default `jit` profile loses is
therefore warm-up and tiering overhead, not code quality; the tiered
configuration is still re-tiering at tick 200.

That parity is for *scalar* code. §8 shows it does not survive contact with the
vector unit, for a reason that is not about compiler quality at all.

### And it does survive branchy code

The obvious objection is that this loop is the best case for ahead-of-time
compilation: straight-line arithmetic with nothing for a profile to learn. It
needed no new workload to test, because half of every tick is already the
other thing. The agent pass makes a data-dependent four-way turn decision per
agent per tick, and every port times it separately from the branch-free
stencil.

How branchy is it? `SB_BRANCH_STATS=1` in the C reference counts the outcomes —
and since all fourteen ports are bit-identical, the answer is a property of
the simulation rather than of one of them:

| outcome | share |
|---|---:|
| straight on | 76.6 % |
| turn left | 11.0 % |
| turn right | 11.1 % |
| dead end (draws from the PRNG) | 1.3 % |

Skewed, but not a branch a predictor gets for free. 512², 262 144 agents, 200
ticks after 100 of warm-up, best of five:

<!-- sb:table branchy -->
| configuration | agent pass, ms | spread | stencil, ms |
|---|---:|---:|---:|
| JIT, tier-1 | **716.62** | 0.9 % | 98.74 |
| Native AOT, default | 729.89 | 3.3 % | 80.94 |
| Native AOT, `IlcInstructionSet=native` | 719.45 | 0.5 % | 81.29 |
<!-- /sb:table -->

**The ahead-of-time build wins the branchy half.** The three differ by 1.9 %
end to end, against run-to-run spreads of 0.5–3.3 % — so unlike most
comparisons in this document the ordering here is resolved, and it puts Native
AOT with the right instruction set ahead of the JIT rather than merely level
with it. Whatever dynamic profile-guided optimisation is doing on this
workload, it is not winning the half of it that has branches.

That is a narrow claim about one branch distribution and it should stay
narrow. This loop does the same thing every tick, takes every branch the same
way, and touches the same two arrays. It is close to the best case for
ahead-of-time compilation and the worst case
for profile-guided anything. The C reference agrees, from a different
direction: §12 records PGO buying nothing on gcc and *losing* 6 % on clang for
the same reason.

### What each configuration costs to ship

<!-- sb:table ship -->
| Configuration | published | start-up |
|---|---:|---:|
| C# jit | 156K | 25.8 ms |
| C# tier1 | 156K | 32.3 ms |
| C# ReadyToRun | 80M | 18.5 ms |
| **C# Native AOT** | **3.8M** | **3.7 ms** |
<!-- /sb:table -->

Start-up is five runs of `--ticks 0`, warm page cache; the first measurement of
ReadyToRun after building it read 217 ms, so treat that column as an ordering
rather than a constant. The ordering is stable: **AOT starts seven to nine
times faster than the JIT configurations** (3.7 ms against 25.8 and 32.3) and
ships a self-contained 3.8 MiB binary, where ReadyToRun needs 80 MiB to be
self-contained and buys nothing for it.

### The two interpreters

The JVM can be told to stop compiling entirely. That makes `-Xint` directly
comparable to CPython running the identical algorithm at the identical
conformance tier — a comparison available nowhere else in this project, because
no other runtime here has an interpreter you can pin it to.

<!-- sb:table interpreters -->
| Runtime | ms/tick | spread | vs C |
|---|---:|---:|---:|
| numba | 0.2446 | 3.8% | 0.98× |
| c gcc -O3 -march=native | 0.2504 | 1.0% | 1.00× |
| java, tiered (default) | 0.2536 | 2.8% | 1.01× |
| java, C2 only | 0.2583 | 5.4% | 1.03× |
| go, -gcflags=-B | 0.2729 | 1.4% | 1.09× |
| **java, -Xint** | **5.5409** | 0.8% | **22×** |
| **python pure --strict-f32** | **85.8407** | — | **343×** |
<!-- /sb:table -->

Same algorithm, same exactness, same grid hash on every row: `0x89CFFAAC`. The
top four rows are inside each other's spread and are not ranked against one
another — numba, C, and the JVM in both configurations are the same number
here.

**CPython's interpreter is 15.5× slower than the JVM's.** "Interpreted" is not
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

`small` (1024², 262 144 agents), 100 ticks. One thread: 3.12 **2027 ms**,
3.14t **1890 ms**.

**`binned`** — milliseconds, with the speedup against the same interpreter at
one thread in brackets:

<!-- sb:table gil-binned -->
|  | 3.12 threads | 3.12 processes | 3.14t threads | 3.14t processes |
|---|---:|---:|---:|---:|
| T=2 | 1 549 (1.31×) | 1 311 (1.55×) | 1 264 (1.50×) | 1 275 (1.48×) |
| T=4 | 3 189 (0.64×) | 654 (3.10×) | 612 (3.09×) | 683 (2.77×) |
| T=8 | 7 128 (0.28×) | 615 (3.29×) | 521 (3.63×) | 626 (3.02×) |
| T=16 | 14 753 (0.14×) | 848 (2.39×) | 656 (2.88×) | 798 (2.37×) |
<!-- /sb:table -->

**`private`**, same units:

<!-- sb:table gil-private -->
|  | 3.12 threads | 3.12 processes | 3.14t threads | 3.14t processes |
|---|---:|---:|---:|---:|
| T=2 | 1 288 (1.57×) | 1 092 (1.86×) | 1 066 (1.77×) | 1 053 (1.80×) |
| T=4 | 2 667 (0.76×) | 477 (4.25×) | 490 (3.86×) | 497 (3.80×) |
| T=8 | 6 275 (0.32×) | 453 (4.47×) | 429 (4.41×) | 464 (4.07×) |
| T=16 | 13 139 (0.15×) | 503 (4.03×) | 488 (3.87×) | 504 (3.75×) |
<!-- /sb:table -->

**All 34 runs produce the same result:** grid `0x65DF83A7`, agents
`0xE02D7B6A` — across two interpreters, two backends, four thread counts and
both reductions.

### The first column is the actual finding

CPython 3.12 with threads does not merely fail to scale, it **degrades
super-linearly**: 14.8 seconds at 16 threads against 2.0 at one, so **7.3×
slower** than the serial run. And cleanly proportional to the thread count —
0.64×, 0.28×, 0.14× is almost exactly a halving per doubling.

That is more than "the GIL serialises" explains: pure serialisation would be
1.0×, not 0.14×. The order of magnitude fits convoying at the barriers. 148 ms
per tick at 16 threads with six barriers is 96 crossings at 1.5 ms each, and
CPython's switch interval is 5 ms — so a waiter that gives up the GIL at a
barrier does not get it straight back. I have not measured that; it is the
arithmetic working out, not the proof.

### Without the GIL, threads beat processes, and most where there are more barriers

Both columns are 3.14t, so the only variable is threads against processes. In
`binned`, threads win at every thread count: by 20 % at T=8 (521 against
626 ms) and by 22 % at T=16 (656 against 798). In `private` the margin is
smaller but the same sign — 8 % at T=8 (429 against 464) and 3 % at T=16
(462 against 531).

The size of the margin tracks the number of phases: `binned` has five,
`private` has two. Every phase boundary is a barrier, and a barrier between
processes is an OS object where one between threads is a futex in the same
address space. Where more synchronisation happens, the shared address space
pays off more — which is why the reduction with two and a half times the
barriers shows two to three times the advantage.

An earlier series had `private` level rather than ahead, and this heading said
threads won "only for `binned`". They win in both; the difference is how much.

### And the honest reading

**The fastest value in the whole table belongs to CPython 3.14t** — 429 ms,
`private`, eight threads, with 3.12's eight processes 6 % behind it at 453.
Between two numbers that close the ordering is not the point; what matters is
that free-threading reaches the same place. So free-threading does not make this workload
faster. It makes the workaround unnecessary: no `shared_memory` block, no
hand-computed byte offsets, no `fork` requirement, no copying the arrays back
at the end. Roughly 120 of the 350 lines in
[`slimebench_mp.py`](../impl/python/slimebench_mp.py) exist only because
threads were not an option.

The single-thread comparison (1890 against 2027 ms) looks like an argument that
free-threading costs nothing — **it is not one**. The two interpreters carry
numpy 2.5.2 and 1.26.4, and the difference between two numpy versions is
exactly the order of magnitude in question. That pair is confounded and is
there only to give the speedups a baseline.

---

## 8. SIMD and hand-written assembly (class V)

### Managed runtimes reach the vector unit

Class V was three languages using intrinsics named for one instruction set.
Java and C# reach it a different way: a portable vector type, no instruction
set in the source, the width resolved at run time. 1024², 300 ticks after 100
of warm-up. The diffusion column is the one to read — the agent pass is
identical in all of them and dilutes the difference.

<!-- sb:table simd -->
| Target | Vector | diffuse ms | spread | vs best |
|---|---:|---:|---:|---:|
| C++, `-O3 -march=native` | AVX-512 intrinsics | 67.0 | 8.0% ⚠ | 1.00× |
| C, `-O3 -march=native` | AVX-512 intrinsics | 70.2 | 15.7% ⚠ | 1.05× |
| Rust, unchecked | AVX-512 intrinsics | 73.4 | 14.2% ⚠ | 1.10× |
| C++, `-O3 -mavx2` | AVX2 intrinsics | 75.3 | 14.3% ⚠ | 1.12× |
| C#, Native AOT + `IlcInstructionSet=native` | `Vector512<float>` | 77.4 | 10.2% ⚠ | 1.16× |
| Rust, safe | AVX-512 intrinsics | 77.5 | 24.6% ⚠ | 1.16× |
| C, `-O3 -mavx2` | AVX2 intrinsics | 78.2 | 6.3% ⚠ | 1.17× |
| Java, tiered | Vector API, 512-bit | 81.6 | 11.2% ⚠ | 1.22× |
| C#, JIT | `Vector512<float>` | 81.8 | 8.5% ⚠ | 1.22× |
| Java, C2 only | Vector API, 512-bit | 82.2 | 7.1% ⚠ | 1.23× |
| C#, `--simd-portable` | `Vector<float>`, 128-bit | 126.8 | 4.3% | 1.89× |
| C#, Native AOT, default | `Vector512` unavailable, 128-bit | 127.0 | 3.8% | 1.90× |
<!-- /sb:table -->

**All sixteen runs, across those twelve configurations, produce the same grid
hash `0xEEA4EAB3`** — five languages, three ways of reaching the vector unit,
four widths. SPEC-1 §8.1 is why: the
stencil does no cross-lane work, so each lane performs exactly the scalar
computation for its own cell in the same order.

**A portable vector type gets within 16–25 % of hand-written intrinsics.** C#
naming `Vector512<float>` lands at 1.16× of the best AVX-512 C++, and Java's
Vector API — which names no width at all, only `SPECIES_PREFERRED` — at 1.22×.
For source that contains no instruction set, that is a small price. Note the
ordering inside the intrinsics group is not dependable: AVX-512 C beats AVX2 C
in this series and the reverse in the last one, and both carry spreads of
6–16 % over a memory-bound kernel. Only the gap down to the 128-bit rows is
larger than the noise.

**.NET's portable `Vector<T>` will not use AVX-512.** On this machine
`Vector512.IsHardwareAccelerated` and `Avx512F.IsSupported` are both true and
`Vector<float>.Count` is 8 — 256 bits. `DOTNET_PreferredVectorBitWidth=512`
does not change it. Naming `Vector512<float>` explicitly is worth 1.6× on the
stencil. Java's `SPECIES_PREFERRED` has no such reservation and takes the full
width without being asked.

### Ahead-of-time compilation loses the vector unit, and it is one flag

The §6 finding was that Native AOT matches the JIT. On vector code, by
default, it does not — and the reason is not the compiler quality:

| C# configuration | widest vector available | diffuse ms |
|---|---|---:|
| JIT | `Vector512` | 93.8 |
| Native AOT, default | **128-bit only** | 133.4 |
| Native AOT, `IlcInstructionSet=native` | `Vector512` | **93.0** |

**Native AOT compiles for the x64 baseline.** The JIT knows which CPU it is
running on; the AOT compiler is told at publish time, and by default it is told
"any x64", which means SSE2. `Vector512.IsHardwareAccelerated` is then *false*
in a binary running on a machine that has AVX-512.

`-p:IlcInstructionSet=native` fixes it: 127.0 ms of diffusion becomes 77.4,
which is the JIT's number and a shade under it. It helps the scalar path too —
that build is the C# row in §2's `deferred` table, at 1.47×, ahead of the JIT
profiles — because the baseline was costing the ordinary code as well. The trade is a binary that no
longer runs anywhere, which is exactly the trade a JIT does not have to make.

So §6's answer needs a qualifier: ahead-of-time compilation matches the JIT
*once someone tells it what it is compiling for*, and the default does not.
The default is also the one a build pipeline produces without being asked.



Explicit intrinsics for the diffusion pass, `--simd`, `small`/300. The agent
pass stays scalar: several agents per vector routinely deposit into the same
cell, which would need conflict resolution — and that really would be tier C.

<!-- sb:table simd-kernels -->
| Language | Compiler | ISA | total ms | diffusion ms | scalar diffusion ms ¹ | factor |
|---|---|---|---:|---:|---:|---:|
| C++ | g++ | AVX2 | **973** | 75.3 | 293.1 | 3.89× |
| C++ | g++ | AVX-512 | 996 | **67.0** | 293.1 | 4.38× |
| C | gcc | AVX2 | 1 000 | 79.0 | 296.2 | 3.75× |
| C++ | clang++ | AVX-512 | 1 013 | 70.1 | 301.1 | 4.30× |
| C | clang | AVX-512 | 1 015 | 70.3 | 288.6 | 4.11× |
| C | gcc | AVX-512 | 1 091 | 70.2 | 296.2 | 4.22× |
| C++ | clang++ | AVX2 | 1 161 | 76.9 | 301.1 | 3.91× |
| C | clang | AVX2 | 1 163 | 78.2 | 288.6 | 3.69× |
| Rust | cargo | AVX-512 (unchecked) | 1 313 | 73.4 | 284.5 | 3.88× |
| Rust | cargo | AVX-512 (safe) | 1 389 | 77.5 | 416.8 | 5.38× |
<!-- /sb:table -->

¹ The scalar comparison figure is always the `-O3 -march=native` build of the
same language and compiler, including in the AVX2 rows (`-march=x86-64-v3`).

### It is tier A

The kernel does **no cross-lane reduction**: each lane computes one output cell
with exactly the operation sequence the scalar loop uses. Bit-identical under
gcc and clang, in both update modes, and with `--threads 16 --deposit-reduce
binned`.

Two conditions: no FMA (`4.0f*c + acc` as a single rounded operation would be a
different number) and a real `_mm*_div_ps`.

### The stencil gets 4.1×, the program 1.3×

Diffusion drops from 296 to 70 ms, but it is only a fifth of the runtime —
the agent pass stays scalar and dominates. Amdahl, in one line.

**Doubling the vector width buys little.** AVX2 against AVX-512, same source
and same compiler: 79.0 → 70.2 ms on gcc (11 %) and 78.2 → 70.3 on clang
(10 %). Ten per cent for twice the width, and this series it is at least
consistent between the compilers, which it has not always been. The 3×3
stencil reads 36 bytes to write 4 — it is
bandwidth-bound, the execution units are waiting on memory, and double the
width only helps at the load ports.

**Rust's "safe" wins the biggest factor here, and that is an artefact.** 5.4×
sounds impressive next to unchecked Rust's 3.9×, but it is only large because
the *scalar* comparison value is bad: with bounds checks the scalar stencil
costs 417 ms instead of 285. The SIMD kernel goes through raw pointers either
way and lands at 73–78 ms in both. Report factors against your own baseline
and you sometimes measure the baseline.

**Read alongside the `-Ofast` finding from §3** the spread becomes absurd. Same
diffusion pass, same compiler (clang), same preset:

| Strategy | ms |
|---|---:|
| `-Ofast`, left to clang | 850.0 |
| `-O3 -march=native`, left to clang | 288.6 |
| intrinsics | 70.3 |

**A factor of 12 between the best and the worst way to vectorise the same
loop** — and the worst is the one that gives the compiler the most freedom.

### The agent pass, which is the other seven eighths

Everything above vectorises the diffusion stencil. The stencil is 12 % of a
tick at `medium` and 23 % at `small`; the agent pass is the rest, and until
this series no port vectorised it. [`impl/c/sb_simd.h`](../impl/c/sb_simd.h)
said why — three sensor reads are a gather with data-dependent addresses, and
gathers on Zen are "barely faster than scalar loads" — and was honest that
this had never been measured. It is measured now, and it was wrong.

Two changes, and they attack the same bottleneck from opposite ends.
`--simd-agents` cuts instructions: sixteen agents per iteration, the four-way
turn decision as masks, and one eight-byte gather element per direction
instead of two four-byte ones, because the trig table is stored interleaved
and pre-scaled. `--agent-tile N` cuts distance: every N ticks the agent arrays
are counting-sorted into 8×8 tiles of the grid, so the sixteen lanes of a
sensor gather land in a few cache lines rather than sixteen unrelated ones.

<!-- sb:table agent-pass -->
| preset | grid | scalar | + tiles | + simd | both | best |
|---|---:|---:|---:|---:|---:|---:|
| tiny | 1 MiB | 79.1 | 70.5 | 32.3 | **27.3** | 2.90× |
| small | 4 MiB | 370.3 | 372.3 | 171.1 | **143.9** | 2.57× |
| medium | 16 MiB | 3492.8 | 1980.4 | 1322.3 | **730.1** | 4.78× |
| large | 64 MiB | 23478.3 | 9009.5 | 9132.6 | **3077.3** | 7.63× |
<!-- /sb:table -->

**Locality is worth about as much as the vector unit, and they compose.** At
`large` the ordering alone still edges out vectorising alone on the phase —
9010 ms against 9133 — though on the whole program vectorising is now ahead
(11353 against 13075), which is a reversal from the previous series and inside
the margin either way. What is not marginal is that the two together
are 7.6×, against the 1.3× the diffusion stencil returns on the whole
program.

**The factor grows with the grid**, which is the signature of a memory-bound
kernel and the opposite of the gather pessimism: sixteen gathers in flight
expose more memory-level parallelism than a scalar loop's serialised dependent
loads, and that outweighs the worse locality at 64 MiB.

Now the same runs, whole program:

<!-- sb:table agent-total -->
| preset | grid | scalar | + tiles | + simd | both | best |
|---|---:|---:|---:|---:|---:|---:|
| tiny | 1 MiB | 104.1 | 106.3 | **57.4** | 62.7 | 1.81× |
| small | 4 MiB | 480.6 | 564.2 | **280.3** | 335.5 | 1.71× |
| medium | 16 MiB | 3970.4 | 2893.6 | 1818.8 | **1649.3** | 2.41× |
| large | 64 MiB | 25606.6 | 13075.0 | 11352.8 | **7032.0** | 3.64× |
<!-- /sb:table -->

**On a grid that fits in cache the ordering is a net loss**, and at `small`
it barely pays for itself even inside the phase it is meant to speed up:
370.3 ms scalar against 372.3 ordered, which is nothing — and slightly the
wrong way. Vectorising alone is
the best whole-program configuration at both `tiny` and `small`; adding the
sort makes it worse, 65.4 → 70.4 and 358.3 → 408.2.

The crossover sits between 4 and 16 MiB, which is roughly where the grid stops
being something the cache can hold. That is why it is a flag with an argument
rather than a default, and why both tables are here — either one alone
recommends the wrong thing at half the sizes.

#### The same idea in four languages

The ordering is not a C trick. It is a counting sort and an index array, and
each port writes it the way that language writes such things: C memcpys
through staging buffers, C++ swaps `std::vector`s, Rust swaps `Vec`s, Go swaps
slices the runtime owns.

<!-- sb:table agent-langs -->
| Language | agents | agents, ordered | phase | total | total, ordered | program |
|---|---:|---:|---:|---:|---:|---:|
| C | 3492.8 | 1980.4 | **1.76×** | 3970.4 | 2893.6 | 1.37× |
| C++ | 3717.3 | 2370.5 | **1.57×** | 4226.0 | 2885.6 | 1.46× |
| Rust | 5352.7 | 2328.1 | **2.30×** | 5836.5 | 3383.8 | 1.72× |
| Go | 4274.8 | 1545.4 | **2.77×** | 5103.3 | 2804.6 | 1.82× |
| Java | 4260.3 | 1726.8 | **2.47×** | 4841.2 | 2900.3 | 1.67× |
| C# | 5682.4 | 1924.6 | **2.95×** | 6518.0 | 3335.0 | 1.95× |
| Swift | 6141.2 | 2271.8 | **2.70×** | 6656.1 | 3379.7 | 1.97× |
| Haskell | 4473.6 | 1664.5 | **2.69×** | 4976.3 | 2646.8 | 1.88× |
<!-- /sb:table -->

**Go gains the most and ends up fastest**, which neither its class S rank nor
its class P win would have predicted — the three are different questions, and
this is the third. The permutation allocates nothing after start-up (the
staging buffers are made once), but it moves 26 bytes per agent per re-sort,
and a garbage-collected runtime turns out not to mind.

Every port had the same place to go wrong, and the conformance gate is what
says none of them did: the agent hash has to walk agents in **agent** order
through the inverse permutation. Hash the slots instead and the checksum
starts depending on a performance flag, which is the one thing it must not do.

#### Why this is still tier A

The permutation moves agents around in memory, which sounds like exactly the
thing a bit-exact benchmark cannot do. It is sound because SPEC-1 fixes the
order deposits are **applied** in, not the order agents are **stepped** in,
and three details carry that:

- each agent's PRNG state moves with the agent, so no stream is disturbed;
- the pass writes each target cell to `agent_idx[original index]`, and the
  deposit loop walks that array from zero — the same order, and therefore the
  same floats, as the unordered loop;
- `sb_hash_agents` walks agents in agent order through the inverse
  permutation. A checksum that changed when a performance flag changed would
  defeat the point of having one.

Neither kernel may fuse a multiply into an add, and neither does any
cross-lane arithmetic. The one subtlety is the PRNG: only the dead-end branch
draws, 1.3 % of agents, and a lane that drew speculatively would advance a
stream that must not advance — so the PRNG is not vectorised at all. Those
lanes are handled scalar, in ascending lane order, over the bits of the mask.

Both targets run the full conformance set under gcc and clang.

#### And where the assembly went

The stencil has a hand-written AVX-512 kernel that beats the intrinsics by
11 %, so the obvious next step was the same for the agent pass. Two strategies
a compiler will not choose were tried and measured: the interleaved,
pre-scaled trig table, worth 12 % — and it is expressible in intrinsics, so it
lives there — and software pipelining across blocks to hide gather latency,
worth **−2 %**.

That second number is why there is no `sb_agents_avx512.S`. The kernel is
memory-bound, and hand-written assembly buys instruction selection and
scheduling, which is not what is scarce here. The 11 % the stencil gained came
from issuing *fewer loads*; the equivalent here was the table, and it is
taken. Writing a transliteration to report 0 % is the thing
[`impl/asm/sb_diffuse_avx512.S`](../impl/asm/sb_diffuse_avx512.S) argues
against in its own header.

### And what is left after that: hand-written assembly

The intrinsics kernel is already tier A and already 2.2× over the scalar loop
at `medium`.
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

<!-- sb:table asm-kernels -->
| Kernel | clang (ms) | gcc (ms) | clang rel. | gcc rel. |
|---|---:|---:|---:|---:|
| scalar loop | 468.2 | 493.5 | 1.00× | 1.00× |
| intrinsics | 209.6 | 213.9 | 2.23× | 2.31× |
| hand-written assembly | 182.5 | 186.6 | 2.57× | 2.64× |
| **lead over intrinsics** | **15 %** | **15 %** | — | — |
<!-- /sb:table -->

All three kernels, both compilers, one grid hash: `0x0391F3BD`.

Read that lead as a range, not a figure. Across six series it has sat between
5 % and 21 %, median about 13 %; a control measurement with nine repetitions
instead of three gave 9 % (gcc) and 13 % (clang), and this series gives 15 % on
both compilers — the first one where the two agree. What stays stable across
all of them: the assembly figure itself varies half as much as the intrinsics
one (161–187 against 183–213 ms). It is faster, and it is steadier.

Two side effects that are not in the table:

**The torus wrap becomes free.** The row is a power of two long, so the byte
offset of the next vector is `(xo + 64) & (rowbytes - 1)` — a single `AND`.
That makes the first and last vector of a row ordinary iterations. The
intrinsics kernel cannot express this and peels a scalar head and tail off
every row.

**The two compilers land 2 % apart** (182.5 against 186.6 ms), where they are
5 % apart on the scalar loop and 2 % apart on the intrinsics. That is how it
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

Four hosts: CUDA, Vulkan compute, a GLSL 4.3 compute shader driven from C,
and the same shader driven from Python. All `deferred` only, 100 ticks. Vulkan
appears three times because it is asked for a device kind rather than an
index, and this machine has all three — the discrete RTX 5080, the Radeon
integrated in the CPU, and lavapipe on the CPU itself. That is one shader
across three vendors.

<!-- sb:table gpu -->
| Host | tiny | small | medium | large | huge |
|---|---:|---:|---:|---:|---:|
| cuda | 9 | 16 | 47 | 203 | 1 137 |
| cuda MCUPS | 2 970 | 6 527 | 8 877 | 8 252 | 5 901 |
| vulkan-discrete | 49 | 50 | 60 | 226 | 1 172 |
| vulkan-discrete MCUPS | 530 | 2 117 | 6 941 | 7 438 | 5 728 |
| vulkan-integrated | 133 | 416 | 1 647 | 6 547 | 26 134 |
| vulkan-integrated MCUPS | 197 | 252 | 255 | 256 | 257 |
| vulkan-cpu | 216 | 348 | 865 | 3 682 | 13 476 |
| vulkan-cpu MCUPS | 121 | 301 | 485 | 456 | 498 |
| gl43 C | 246 | 695 | 2 565 | 9 928 | 42 662 |
| gl43 C MCUPS | 106 | 151 | 163 | 169 | 157 |
| gl43 Python | 238 | 699 | 2 560 | 9 901 | 42 814 |
| gl43 Python MCUPS | 110 | 150 | 164 | 169 | 157 |
<!-- /sb:table -->

MCUPS is million cell updates per second — grid cells, not agents, so the
figure is comparable across presets.

### One SPIR-V module, three devices, and what agrees with what

The Vulkan host is asked for a *kind* of device rather than an index, so the
same build runs on everything the machine has: the discrete RTX 5080, the
Radeon integrated in the 9950X3D, and lavapipe on the CPU. One SPIR-V module,
compiled once from the same GLSL body the GL host uses. The checksums then
sort the five GPU hosts into three groups, and the grouping is the result:

| group | hosts | agrees with the C reference |
|---|---|:-:|
| CUDA and lavapipe | `cuda`, `vulkan-cpu` | **yes, all five presets** |
| the two real GPUs | `vulkan-discrete`, `vulkan-integrated` | no, from `small` up |
| the GL path | `gl43 C`, `gl43 Python` | no, from `small` up |

Three things follow.

**Vulkan on a software device is tier A.** `vulkan-cpu` produces
`0xB4AC535B / 0x6A2394F4` at `medium` — the same pair as every tier-A CPU
implementation in §2 and as CUDA — at all five presets, grid and agent hash
both. So nothing in the port, the SPIR-V or the push-constant plumbing is
approximating anything; what deviates is the arithmetic of the hardware
drivers.

**Two vendors deviate identically.** `vulkan-discrete` on NVIDIA and
`vulkan-integrated` on AMD are byte-identical to each other at every preset,
and both differ from the reference. Two independently written drivers landing
on the same wrong answer is not a coincidence: it is the same permitted
rounding in the same place, which SPEC-1 §8.2 predicts and which `precise`
cannot forbid — GLSL's `precise` blocks reordering and fusion but does not
require a correctly rounded division. CUDA gets that from `--prec-div=true`
and lavapipe from computing in software; the two GPU drivers do not have to.

**The GL numbers really were measuring the translation layer.** `vulkan-cpu`
runs `medium` in 865 ms on the CPU. The GL path runs it in 2 565 ms *on the
RTX 5080*. A software rasteriser beating a discrete GPU threefold is not a
statement about OpenGL; it is the cost of GL → DXIL → D3D12 under WSL2, and
the Vulkan row on the same GPU — 60 ms, 42× faster than the GL one — is what
that hardware was capable of all along.

**One flag was worth the whole exactness result.** `glslc -O` reassociates
past `precise`, and does it on every device including the software one, so the
grid hash was wrong everywhere before the shaders were compiled with `-O0`.
It costs nothing measurable — 35.5 ms against 36.0 at `small` — which is the
expected shape for a kernel that is waiting on memory, and it is the
difference between a conformance result and a plausible one.

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

CUDA's throughput rises to 8877 MCUPS at `medium` and falls after that — at
`huge` (8192², 67 M cells) it is back below the `small` figure. The speedup
against one C thread is **eighty-fold** at `medium`: 47 ms against 3970. For
`large` and `huge` the serial C comparison value is missing from this series —
the thread sweep only runs at `medium`, because a single C thread at `huge`
needs a good ten minutes per data point.

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

<!-- sb:table render -->
| Language | Binding | SDL2 llvmpipe | SDL2 RTX 5080 | raylib llvmpipe | raylib RTX 5080 |
|---|---:|---:|---:|---:|---:|
| C | direct | 2.979 | 3.879 | 2.147 | 1.934 |
| C++ | direct | 2.988 | 3.845 | 1.998 | 1.932 |
| Haskell | `sdl2` / `foreign import` | 2.710 | 3.719 | 2.017 | 1.900 |
| Rust | `sdl2` / `raylib` crate | 3.019 | 3.941 | 2.062 | 1.987 |
| Python | pygame / cffi | 5.004 | 5.371 | 4.646 | 4.605 |
| Perl | FFI::Platypus | 119.565 | 118.251 | 78.746 | 78.683 |
<!-- /sb:table -->

The six SDL2 and raylib frontends in C, C++ and Rust now carry a HUD; under
`--json` it is off, and its drawing time is subtracted from the frame in any
case (end of this section).

**raylib wins everywhere, and more clearly on the real GPU:** 1.4× on software,
**2.0×** on the RTX 5080, in every compiled language. The cause is the pixel
format, not the library — raylib takes the 8-bit greyscale buffer directly
(`UNCOMPRESSED_GRAYSCALE`), while SDL2 needs ARGB8888 and therefore an
expansion loop over a million pixels per frame.

**The four compiled languages land within 5 % of each other on raylib**
(1.900–1.987 ms) and within 8 % on software. Once the backend and the pixel
format are fixed, the language barely matters in this class — which is the most
interesting finding in the table, because it contradicts the class S picture.

**SDL2 is slower on the real GPU than on the software rasteriser**, in all four
compiled languages (3.0 → 3.9 ms), while raylib stays equally fast on both.
Both paths are CPU-bound at 1024²; on D3D12 SDL2 additionally pays for the
`SDL_LockTexture` path through the translation layer. A GPU-limited measurement
would need a much larger grid.

**Python is 2× behind, and the backend difference nearly vanishes.** The frame
is dominated by the numpy conversion, not the upload.

**Perl is 30–40× behind but shows the backend difference most clearly** (118
against 79 ms). Here I had expected the opposite: if the conversion dominates
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

<!-- sb:table gc -->
| runtime | collections | GC time | allocated over the whole run |
|---|---:|---:|---:|
| **Java** | **0** | 0 ms | — |
| Go | 1 | 0.76 ms | 5.2 MiB, 305 mallocs |
| C# | 1 gen0 / 1 gen1 / 1 gen2 | — | 4.7 MiB |
| Haskell | — | 0.000 s of 0.253 | 7.4 MiB |
| OCaml | 7 minor, 2 major | — | 12.0 MiB of minor words |
<!-- /sb:table -->

**The JVM never collects.** Go allocates 305 times in two hundred ticks, which
is startup and nothing else. The reason is structural: the simulation
allocates its grids and agent arrays once and writes into them for the rest of
the run, which is what SPEC-1 asks for and what every port does.

So the ranking in §2 is a ranking of these runtimes with their collectors
switched off in all but name. Allocation rate, pause distribution and the
throughput cost of a write barrier are among the largest differences between a
managed runtime and C, and **this benchmark exercises none of them.** That is a
limitation of the workload, not a property of the languages, and it should be
read into every row where a collected language appears.

It also explains a result that would otherwise be surprising: Java at 1.18× and
C# at 1.47× in §2 are managed runtimes performing like compiled ones, on the
one workload where the managed part is free.



<!-- sb:table footprint -->
| Language | Binary KiB (stripped) | RSS MiB |
|---|---:|---:|
| TypeScript | — | 79 |
| Python (numba) | — | 166 |
| Python (numba-fastmath) | — | 166 |
| Python (pure) | — | 18 |
| Python (pure-strict) | — | 18 |
| Perl (plain) | — | 22 |
| Perl (strict-f32) | — | 22 |
| C# (dotnet) | — | 41 |
| Java (javac) | — | 63 |
| C (gcc) | 58 | 19 |
| C (clang) | 62 | 19 |
| C++ (clang++) | 63 | 19 |
| C++ (g++) | 66 | 19 |
| Fortran (gfortran) | 74 | 19 |
| Swift (swift) | 100 | 32 |
| Rust (unchecked) | 448 | 19 |
| Rust (safe) | 478 | 19 |
| OCaml (strict-f32) | 1 178 | 18 |
| OCaml (f64) | 1 182 | 18 |
| Go (go) | 1 564 | 19 |
| Haskell | 2 797 | 29 |
| Lean (lake) | 2 851 | 18 |
<!-- /sb:table -->

The spread across the compiled languages is **a factor of 56**, from 50 KiB in
C to 2779 in Haskell — and all of it is runtime system, not generated code.
Swift at 96 KiB is notable: it sits closer to C++ than to Rust, because its
runtime library is linked dynamically rather than absorbed. Go pays 1.5 MiB for
a goroutine scheduler and a garbage collector — and is the language that wins
class P (§5). Fat LTO recovers 7 % of the binary size on Rust.

RSS is identical across almost all compiled languages, because the grid
dominates it (2 × 4 MiB buffers plus agent data). The only outliers are Swift
at 32 MiB and the runtimes, Node at 79 MiB and numba at 166.

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

## 13. The machine, and whether it is telling the truth

Every section above varies the language or the compiler and holds the machine
fixed. This one does the opposite, and it exists because of a property none of
the others use directly.

SPEC-1 makes the result **machine-independent**. The same configuration
produces the same checksum on any conforming implementation, on any CPU, on
any GPU — that is the whole design, and §2 is fourteen languages demonstrating
it. Turn it around and it says something else: a chain of checksums recorded
once, on a machine believed to be healthy, is a reference for **every**
machine, forever. A machine that disagrees with it is wrong.

```bash
bench/machine.sh --record   # once, somewhere you trust
bench/machine.sh            # everywhere else
```

### What it measures

| | |
|---|---|
| one core | the serial kernel, with nothing hidden behind parallelism |
| all cores | the same work across every hardware thread |
| memory bound | a grid four times the last level cache, where the answer is the memory system rather than the core |
| GPU | the identical computation in VRAM, once per API and per device |
| correctness | every result checked against the chain, serially and under full load |

The figures are MCUPS — million cell updates per second — because that
survives a change of grid size and is comparable between machines, which a
millisecond total is not.

### Why the last row is not a benchmark

memtest86 writes a pattern and checks that it comes back. It knows what it
wrote, so it can find a bit that flipped in storage; it cannot tell you
whether the arithmetic between the write and the read was right, because it
never does any. This does: every float that enters the grid has been through a
multiply, an add, a division by twelve and a gather, and all of it lands in
the checksum.

What the workload happens to exercise, without having been designed to:

- 16 to 256 MiB of grid, read nine times and written once per cell per tick —
  streaming bandwidth in both directions;
- three scattered reads per agent per tick over that whole footprint, which is
  the access pattern that finds an unstable memory controller where a
  sequential sweep does not;
- `--threads 32`, which puts every core on it at once;
- `--agent-tile`, which adds a full permutation of 26 bytes per agent every
  other tick — a different kind of traffic again;
- class G, which runs the identical computation in VRAM.

### Localising a fault

A grid hash alone says "wrong" and nothing else, so the chain carries
sixty-four block hashes beside it. A mismatch names the tick, the block, the
cell and row range, and the byte offset within the allocation:

```
MISMATCH at tick 1
  grid   expected 0xDEADBEEF, got 0x83F13018
  block  7  cells 114688..131071  rows 112..127  grid+458752..524284 bytes
```

The tick matters as much as the address. A divergence at tick 3 is
reproducible and probably logic; one at tick 900 is heat or drift.

### What it cannot do

It cannot separate RAM from cache from the floating-point unit — it says the
result is wrong, not which part was. It cannot see a fault in memory the
simulation never touches. And a deterministic fault present on the recording
machine would be baked into the chain, which is why
[`spec/testvectors/machine.chain`](../spec/testvectors/machine.chain) is
recorded on a machine that passes the conformance gate against fourteen
independent implementations first. [`impl/c/sb_verify.h`](../impl/c/sb_verify.h)
states all of this next to the code.

---

## 14. Proved, not measured

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

## 15. Where I was wrong

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
| `prefix` is a serial O(T²) bottleneck | 0.001 ms of work. An artefact of my own instrumentation. |
| Fortran's OpenMP port peaks at 1.5×, and two threads are slower than one | Both figures were the same artefact. The port called `omp_set_num_threads` only above one thread, so `--threads 1` — the denominator of every speedup in that table — ran the parallel region 32 threads wide. It reported `"threads": 1` and the matching grid hash throughout, because SPEC-1's deposit adds a constant and the result does not depend on the thread count. The corrected sweep is an ordinary curve peaking at 8.4×. |
| A run that prints `failures: 0` had no failures | Those counters came from individual phases and never covered the phases `full-run.sh` drives itself. Sixteen class R targets failed in one series — four languages that were simply never built — and the run ended with a row count and a directory listing. There is now one tally over the whole run, covering failures, empty result files, and T=1 rows that used more than one core's worth of CPU; it exits non-zero. |
| The agent pass cannot usefully be vectorised: its sensor reads are a gather with data-dependent addresses, and gathers on Zen are barely faster than scalar loads | Wrong, and by a lot. It is 2.4 to 2.8x with AVX-512, and the factor *grows* with the grid rather than shrinking -- sixteen gathers in flight expose more memory-level parallelism than a scalar loop's serialised dependent loads. sb_simd.h said this for eight months and was at least honest that it had never been measured. |
| Hand-written assembly is worth about a tenth wherever the intrinsics run | It was worth 11 % on the diffusion stencil because it issued fewer loads. On the agent pass the equivalent trick -- an interleaved, pre-scaled trig table -- is worth 12 % and is expressible in intrinsics, and the strategy left for assembly, software-pipelining across blocks, measured -2 %. The kernel is memory-bound; instruction selection is not what is scarce. |
| Class V measures what vectorisation is worth | It measures what it is worth on the diffusion stencil, which is 11 % of a tick at `medium`. Every class V number in five languages, plus the hand-written assembly, addresses that ninth. The other four fifths went unmeasured until this series. |
| The charts come from the same series as the tables | They did, until the series directory was replaced. `bench/charts.py` had the series name frozen into a constant and `load` returned an empty list for a missing file, so running it with no argument regenerated every chart from nothing and reported success. The argument is required now and a missing or empty input is an error. |
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
| Java and C# stop scaling because of their barriers | Only C#. Its compute scales *better* than C's (7.0× against 5.8× from four threads to thirty-two) and its barrier costs 12.7 ms against C's 4.5. Java's barrier is 6.3 ms — worse than C, not enough to matter — and what actually fails is its work, which stops halving after eight threads and rises again at thirty-two (§5). |
| OCaml's tier-A surcharge is the boxed `Int32` the rounding allocates | The allocation count is *identical* between the two builds — the non-flambda unboxing rules do handle it. The cost is 22 PLT calls per cell into `caml_int32_bits_of_float_unboxed` and its inverse, which the assembly shows and I did not until I looked (§2). |
| Native AOT matching the JIT is a straight-line-code result | It holds on the branchy half too. The agent pass makes a data-dependent four-way decision that goes 76.6 / 11.0 / 11.1 / 1.3, and AOT and the JIT are within 2.8 % of each other there against spreads of 0.7–2.5 % (§6). Where it does *not* hold is vector code, and that is a target-ISA problem rather than a compiler one (§8). |
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

## 16. Open questions

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
  4.4–9.4× elsewhere (§2). What remains genuinely open is whether an FFI escape to
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

- **Why Java's work stops scaling.** §5 now measures it: Java has the fastest
  per-thread work in the field at four threads, gains almost nothing from
  eight to sixteen, and at thirty-two is doing 2.3× as much per thread as C.
  Its barrier is not the explanation. Two candidates remain — thread placement
  across the machine's two core complexes, and a spin-then-park barrier whose
  descheduling is being charged to the work phase — and separating them needs
  wakeup counts rather than wall clock, which is the same tooling gap `perf`
  leaves below.

- **What C#'s barrier is doing for 2.5 ms.** Every crossing costs about that
  at 32 participants, including the one where a single thread computes an
  offset table. A flat per-crossing cost is a property of
  `System.Threading.Barrier` rather than of this workload, and replacing it
  with the hand-rolled sense-reversing barrier the C reference carries would
  say how much of C#'s class P result is the library. That is a fair
  experiment; it is also the one §5 declines to do by default, because a port
  that borrows another language's barrier stops measuring its own.

- **OCaml 5.4 has a `Float32` module.** The C stub took tier A from 9.2× to
  4.6× by making the rounding one call instead of two. A native f32 type would
  make it zero calls, and the difference between 4.6× and whatever that gives
  is the last part of OCaml's number that is about the missing type rather
  than about the language.

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
