# Results

Every number in this document comes from **one** run,
[`results/run-20260822-0311/`](../results/run-20260822-0311/), commit
`41c64f7`, produced by a single invocation of:

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
13. [Proved, not measured](#13-proved-not-measured)
14. [Where I was wrong](#14-where-i-was-wrong)
15. [Open questions](#15-open-questions)

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
| allocation | none after start-up. §11 measures the consequence: the JVM collects **zero** times in 200 ticks, Go allocates 300 times in a whole run. Six of the fourteen languages have a garbage collector and none of them is asked to collect. |
| data structures | flat arrays only. No map, no tree, no string, no object graph, nothing with a pointer in it. |
| abstraction | no dynamic dispatch, no virtual calls, no interfaces, no closures in the hot path. Every port was written to avoid them, because the spec fixes the order of operations. |
| branching | one distribution, measured: 76.6 % / 11.0 % / 11.1 % / 1.3 %. A workload whose branches are unpredictable would ask a different question of every JIT here. |
| I/O and syscalls | none inside the measured region. |
| numeric variety | `f32`, and *bit-exact* `f32`. Most numeric code does not demand that and lets the compiler reassociate; §8's fast-math rows are the only place this document lets it. |
| the machine | one CPU, one OS, one memory configuration. §15 has the list. |

**So the cross-language ranking in §2 is a ranking on flat numeric array
code.** For C, C++, Fortran and Rust that is home ground. For Java, C#, OCaml,
Haskell and Go it is the narrowest slice of what those languages are for — no
allocation, no abstraction, no collector. Java at 1.32× is a real result about
a real program, and it is not a claim that Java is 1.32× C.

**The results that do not depend on the workload this way** are the ones that
hold the program constant and change one thing about how it runs:

- the conformance result — fourteen languages producing identical bits, which
  is a property of the spec and the ports rather than of the kernel;
- the two machine-checked proofs (§13), which quantify over all thread counts
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

| Class | best configuration | `medium`, 100 ticks | vs. 1 CPU core |
|---|---|---:|---:|
| S — one thread | C, gcc `-O3 -march=native` | 4227 ms | 1× |
| P — 32 threads | **Go**, `binned` | 554 ms | **7.6×** |
| G — GPU | CUDA, RTX 5080 | **47 ms** | **90×** |

Two things that are not in that table and are the most interesting results of
this series:

**Go wins class P**, not C and not C++ — 554 ms against 571 and 600, from a
17 % single-thread deficit. §5 measures why: at 32 threads its barrier costs a
third less than C's (2.52 against 3.95 ms per tick), and the gap is
concentrated in the one phase where 31 workers wait for one.

**Hand-written AVX-512 assembly beats the intrinsics by about 11 %**, and not
with better instructions but with a third of the loads; §8.

Class V is not in the table because it is measured at 1024² — there AVX-512
buys **1.32×** (1117 → 845 ms). The diffusion pass alone gets 4.7× faster, but
it is only a quarter of the runtime; §8.

Seven results I would not have predicted:

- **Bit-exactness survives everything.** Every tier-A run in `serial` mode
  produces `0x89CFFAAC`, every one in `deferred` mode `0x1DFDF34B` — across
  fourteen languages, five .NET compilation strategies, three JVM
  configurations, class P in ten languages at every thread count, class V in
  five languages across four vector widths, hand-written assembly, CUDA at
  every preset, and all 34 cells of the CPython matrix. The spec had assumed the opposite for both SIMD and GPU.
- **A language ranking from one class does not carry to the next.** Go sits at
  rank 9 of 20 in class S and wins class P. TypeScript is 3.6× slower than C in
  class S and scales better than anything but Go (9.1×). Haskell is at 1.23× in
  class S and matches C in class R. Java is the fastest garbage-collected
  runtime in class S and the slowest to scale in class P.
- **A Python file is at 1.26×.** `slimebench_numba.py` is the pure-Python port
  with `@njit` on the kernels — same loops, same order, same names — and 345×
  faster than it at the same conformance tier. That ratio is the cleanest
  measurement of an interpreter here, because nothing else about the program
  changed; §2.
- **Ahead-of-time compilation matches the JIT.** C# Native AOT lands within
  3 % of the optimising JIT with a full run's profile behind it, starts seven
  times faster, and has no warm-up ramp at all — 2.0× from first tick to best,
  where the JVM's is 26.3×. §6.
- **The two managed runtimes fail class P differently.** C#'s compute scales
  better than C's and its barrier costs three times as much; Java's barrier is
  nearly fine and its work stops halving after eight threads. An earlier
  version of this document blamed the barrier for both. §5.
- **Ahead-of-time compilation keeps up on branchy code too.** The agent pass
  makes a data-dependent four-way decision that goes 76.6 / 11.0 / 11.1 / 1.3,
  and Native AOT is within 2.8 % of the JIT there — against run-to-run spreads
  of 0.7–2.5 %. §6.
- **A portable vector type costs 20–35 % against hand-written intrinsics.**
  C#'s `Vector512<float>` is at 1.20× of the best AVX-512 C++ and Java's
  Vector API — naming no width at all — at 1.35×. Both beat AVX2 intrinsics
  written in C. §8.
- **No garbage collector here does anything.** The JVM collects zero times in
  200 ticks; Go allocates 299 times in the whole run. Six of the fourteen
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

<!-- sb:table s-serial -->
| # | Language | Profile | Tier | ms/tick | rel. | spread | RSS MiB |
|---:|---|---:|:-:|---:|---:|---:|---:|
| 1 | C (clang) | o3-native-lto | A | 0.196 | 1.00× | 0.5% | 18 |
| 2 | C++ (clang++) | o3-native | A | 0.219 | 1.12× | 0.8% | 18 |
| 3 | C (gcc) | o2 | A | 0.223 | 1.14× | 0.4% | 18 |
| 4 | C++ (g++) | o3 | A | 0.224 | 1.14× | 3.7% | 18 |
| 5 | Haskell | o2-llvm | A | 0.232 | 1.19× | 1.1% | 18 |
| 6 | Swift (swift) | unchecked | A | 0.245 | 1.25× | 3.0% | 19 |
| 7 | Java (javac) | default | A | 0.252 | 1.29× | 0.7% | 49 |
| 8 | Python (numba) | default | A | 0.255 | 1.30× | 55.2% ⚠ | 167 |
| 9 | Rust (unchecked) | release-native-lto-unchecked | A | 0.263 | 1.35× | 1.7% | 18 |
| 10 | Go (go) | nobounds | A | 0.269 | 1.38× | 1.0% | 18 |
| 11 | C# (dotnet) | aot-native | A | 0.286 | 1.46× | 1.5% | 18 |
| 12 | Rust (safe) | release | A | 0.293 | 1.50× | 1.0% | 18 |
| 13 | Fortran (gfortran) | o2 | A | 0.299 | 1.53× | 1.3% | 18 |
| 14 | OCaml (f64) | default | B | 0.330 | 1.69× | 0.4% | 18 |
| 15 | TypeScript | default | A | 0.658 | 3.36× | 5.8% ⚠ | 80 |
| 16 | OCaml (strict-f32) | cstub-unsafe | A | 0.904 | 4.62× | 2.6% | 18 |
| 17 | Lean (lake) | default | A | 1.432 | 7.32× | 1.8% | 18 |
| 18 | Perl (plain) | default | B | 37.138 | 189.79× | 1.0% | 22 |
| 19 | Python (pure) | default | B | 38.845 | 198.52× | 3.1% | 18 |
| 20 | Python (pure-strict) | default | A | 85.198 | 435.41× | 0.3% | 18 |
| 21 | Perl (strict-f32) | default | A | 120.938 | 618.06× | 0.7% | 22 |
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
| 1 | C (clang) | o3-native | A | 0.191 | 1.00× | 0.3% | 18 |
| 2 | C++ (clang++) | o3-native | A | 0.211 | 1.10× | 0.2% | 18 |
| 3 | C++ (g++) | o3 | A | 0.219 | 1.14× | 2.0% | 18 |
| 4 | C (gcc) | o3 | A | 0.221 | 1.15× | 0.7% | 18 |
| 5 | Swift (swift) | unchecked | A | 0.246 | 1.28× | 2.1% | 19 |
| 6 | Haskell | o2-llvm | A | 0.246 | 1.29× | 0.4% | 18 |
| 7 | Python (numba) | default | A | 0.247 | 1.29× | 0.3% | 167 |
| 8 | Java (javac) | c2 | A | 0.252 | 1.32× | 2.7% | 49 |
| 9 | Rust (unchecked) | release-native-lto-unchecked | A | 0.261 | 1.36× | 0.2% | 18 |
| 10 | Go (go) | nobounds | A | 0.284 | 1.48× | 1.8% | 18 |
| 11 | Rust (safe) | release | A | 0.289 | 1.51× | 0.5% | 18 |
| 12 | Fortran (gfortran) | o3 | A | 0.301 | 1.57× | 1.8% | 18 |
| 13 | C# (dotnet) | tier1 | A | 0.309 | 1.61× | 1.7% | 30 |
| 14 | OCaml (f64) | default | B | 0.371 | 1.94× | 0.8% | 18 |
| 15 | Haskell (vector) | o2-llvm-vector | A | 0.479 | 2.50× | 3.6% | 23 |
| 16 | TypeScript | default | A | 0.766 | 4.00× | 2.8% | 81 |
| 17 | OCaml (strict-f32) | cstub-unsafe | A | 0.959 | 5.01× | 2.3% | 18 |
| 18 | Python (numpy) | default | A | 1.097 | 5.73× | 2.9% | 39 |
| 19 | Lean (lake) | o3-native | A | 2.192 | 11.45× | 2.5% | 18 |
| 20 | Python (pure) | default | B | 41.681 | 217.78× | 0.4% | 18 |
| 21 | Perl (plain) | default | B | 42.336 | 221.20× | 0.4% | 30 |
| 22 | Python (pure-strict) | default | A | 88.085 | 460.23× | 1.5% | 18 |
| 23 | Perl (strict-f32) | default | A | 129.254 | 675.33× | 0.9% | 24 |
<!-- /sb:table -->

**Every tier-A run in this mode: `0x1DFDF34B`.**

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

Two things follow, and the second one has since been acted on.

Exactness in OCaml is expensive for a reason that is a missing intrinsic
rather than a property of the language. And **it is only two calls where the
hardware needs two instructions, so one call is cheaper than two.** A C stub
declared `[@@unboxed] [@@noalloc]` does the whole conversion in a single call:

| | ns/op on a dependency chain | ms/tick at 256² | vs C |
|---|---:|---:|---:|
| no rounding (tier B, f64) | 2.25 | 0.345 | 1.8× |
| `Int32` round-trip | 7.03 | 1.855 | 9.5× |
| **one C stub** | **5.04** | **0.927** | **4.7×** |

**1.99× for one line**, bit-identical, full conformance set — and it moves
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
| python pure | B | `0x44625B3D` | 9.8277 | — | 158× |
| python pure `--strict-f32` | A | `0xB1D75130` | 21.2041 | — | **341×** |
| **numba** | **A** | `0xB1D75130` | **0.0622** | 67.6% ⚠ | 1.00× |
| numba `--fastmath` | C | `0xF9B2609A` | 0.0614 | 3.1% | 0.99× |
| c gcc `-O2` | A | `0xB1D75130` | 0.0590 | 0.8% | 0.95× |

**Against the honest comparison — tier A against tier A — CPython costs 341×.**
Not 158×: the tier-B row is a different computation, one that happens to be
cheaper because it is wrong. And what is left after the interpreter is removed
is about 5 %: numba runs the identical source at **1.05× of gcc `-O2`**.

> That last figure is the least solid number in this section. At 128² a tick
> is 60 microseconds, and the numba row's three repetitions spread 67.6 % —
> the compiled kernel is fast enough here that the measurement is mostly
> scheduling noise. The gap between numba and gcc is real in the class S table
> at 256², where both rows are steady (1.26× against C's best, spreads under
> 4 %); the 1.05× here should be read as "the same order", not as a ranking.
> The 341× is unaffected: it is a ratio between numbers three orders of
> magnitude apart.

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

<!-- sb:table compilers -->
| Language | Compiler | Profile | Tier | ms | rel. | spread | Binary KiB |
|---|---|---:|:-:|---:|---:|---:|---:|
| C | clang | o3-native | A | 1 117 | 1.00× | 1.6% | 54 |
| C | clang | o3-native-lto | A | 1 121 | 1.00× | 1.5% | 54 |
| C | clang | o3-native-pgo | A | 1 163 | 1.04× | 2.1% | 50 |
| C++ | g++ | o3 | A | 1 177 | 1.05× | 0.6% | 70 |
| C | gcc | o2 | A | 1 193 | 1.07× | 2.4% | 50 |
| C | gcc | o3 | A | 1 215 | 1.09× | 0.4% | 58 |
| C++ | g++ | o3-native | A | 1 221 | 1.09× | 1.1% | 74 |
| C++ | g++ | ofast-native | C | 1 234 | 1.10× | 0.8% | 74 |
| C++ | clang++ | o3-native | A | 1 236 | 1.11× | 0.4% | 63 |
| C++ | clang++ | o3-native-lto | A | 1 296 | 1.16× | 1.0% | 63 |
| C++ | g++ | o2 | A | 1 310 | 1.17× | 1.5% | 62 |
| C | gcc | o3-native | A | 1 315 | 1.18× | 1.7% | 62 |
| C | gcc | o3-native-lto | A | 1 320 | 1.18× | 0.6% | 54 |
| C | gcc | o3-native-pgo | A | 1 328 | 1.19× | 2.7% | 62 |
| C | gcc | ofast-native | C | 1 336 | 1.20× | 0.7% | 62 |
| Haskell | ghc | o2-llvm | A | 1 341 | 1.20× | 0.6% | 2 860 |
| C | clang | o3 | A | 1 362 | 1.22× | 0.2% | 50 |
| C | clang | o2 | A | 1 362 | 1.22× | 0.5% | 50 |
| Java | javac | default | A | 1 403 | 1.26× | 1.8% | — |
| Java | javac | c2 | A | 1 427 | 1.28× | 0.6% | — |
| C++ | g++ | o3-native-lto | A | 1 436 | 1.29× | 0.9% | 66 |
| C++ | clang++ | o3 | A | 1 459 | 1.31× | 4.2% | 59 |
| Swift | swift | unchecked | A | 1 464 | 1.31× | 1.4% | 96 |
| Go | go | nobounds | A | 1 464 | 1.31× | 4.1% | 1 564 |
| C++ | clang++ | o2 | A | 1 474 | 1.32× | 2.0% | 59 |
| Go | go | default | A | 1 508 | 1.35× | 0.8% | 1 604 |
| Rust | cargo | release-native-unchecked | A | 1 510 | 1.35× | 0.8% | 475 |
| Rust | cargo | release-native-lto-unchecked | A | 1 521 | 1.36× | 0.1% | 442 |
| Swift | swift | release | A | 1 536 | 1.37× | 8.6% ⚠ | 100 |
| C# | dotnet | aot-native | A | 1 561 | 1.40× | 0.9% | — |
| Fortran | gfortran | ofast-native | C | 1 565 | 1.40× | 0.5% | 78 |
| C# | dotnet | tier1 | A | 1 568 | 1.40× | 0.4% | — |
| Fortran | gfortran | o3 | A | 1 572 | 1.41× | 0.9% | 78 |
| Fortran | gfortran | o2 | A | 1 575 | 1.41× | 0.7% | 74 |
| C# | dotnet | jit | A | 1 586 | 1.42× | 0.4% | — |
| C# | dotnet | aot | A | 1 603 | 1.44× | 0.9% | — |
| Rust | cargo | release-unchecked | A | 1 627 | 1.46× | 1.2% | 468 |
| Rust | cargo | release | A | 1 630 | 1.46× | 0.6% | 471 |
| Fortran | gfortran | o3-native | A | 1 639 | 1.47× | 0.3% | 78 |
| C# | dotnet | r2r | A | 1 648 | 1.48× | 0.6% | — |
| Rust | cargo | release-native | A | 1 677 | 1.50× | 1.7% | 476 |
| C | clang | ofast-native | C | 1 694 | 1.52× | 1.0% | 54 |
| Haskell | ghc | o2 | A | 1 700 | 1.52× | 1.0% | 2 832 |
| C++ | clang++ | ofast-native | C | 1 794 | 1.61× | 0.6% | 63 |
| Haskell | ghc | o1 | A | 3 118 | 2.79× | 4.0% | 2 779 |
| C | clang | o0 | A | 3 753 | 3.36× | 0.8% | 54 |
| C | gcc | o0 | A | 4 652 | 4.16× | 0.9% | 114 |
| C++ | clang++ | o0 | A | 4 722 | 4.23× | 2.1% | 155 |
| C++ | g++ | o0 | A | 5 076 | 4.54× | 0.7% | 166 |
| OCaml | ocamlopt | default | A | 9 824 | 8.80× | 0.8% | 1 182 |
| OCaml | ocamlopt | unsafe | A | 9 827 | 8.80× | 1.8% | 1 178 |
| Java | javac | int | A | 26 518 | 23.74× | 0.3% | — |
<!-- /sb:table -->

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
| TypeScript | 11 156 | 3 968 | 2 257 | 1 544 | 1 227 | 1 336 | 9.1× |
| Go | 4 934 | 2 205 | 1 575 | 846 | 563 | 554 | 8.9× |
| Swift | 5 963 | 2 486 | 1 660 | 940 | 761 | 886 | 7.8× |
| Haskell | 5 026 | 2 378 | 1 121 | 727 | 678 | 744 | 7.4× |
| C | 4 227 | 2 178 | 1 160 | 843 | 631 | 571 | 7.4× |
| C++ | 4 149 | 2 188 | 1 246 | 802 | 633 | 600 | 6.9× |
| Rust | 5 553 | 2 741 | 1 720 | 1 045 | 869 | 1 061 | 6.4× |
| C# | 6 371 | 2 591 | 1 659 | 1 217 | 1 196 | 1 886 | 5.3× |
| Java | 5 306 | 2 146 | 1 365 | 1 070 | 1 076 | 1 391 | 5.0× |
| Python | 8 013 | 5 887 | 3 185 | 2 212 | 1 830 | 2 206 | 4.4× |
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

| T | C | Go | Java | C# |
|---:|---:|---:|---:|---:|
| 4 | 17.76 | 16.06 | **15.63** | 17.75 |
| 8 | 9.08 | 6.69 | 10.26 | 8.79 |
| 16 | 5.82 | 3.86 | 8.80 | 4.46 |
| 32 | 3.07 | 2.32 | **7.80** | 2.54 |
| **T=4 → T=32** | 5.8× | 6.9× | **2.0×** | **7.0×** |

And the barrier:

| T | C | Go | Java | C# |
|---:|---:|---:|---:|---:|
| 4 | 1.06 | 1.09 | 1.02 | 2.14 |
| 8 | 3.74 | 2.30 | 2.79 | 3.43 |
| 16 | 3.26 | 2.16 | 3.10 | 5.87 |
| 32 | 4.53 | 2.85 | 6.31 | **12.68** |

**C# is a barrier problem, and only a barrier problem.** Its compute scales
better than C's — 7.0× against 5.8×, and at 32 threads it does the work in
2.54 ms where C needs 3.07. Its barrier goes from 2.14 ms to 12.68. The
per-phase breakdown says this is not contention over any particular structure:
every crossing costs about 2.5 ms, *including* `prefix`, where one thread
computes an offset table and thirty-one wait for it.

| phase | C# work | C# barrier |
|---|---:|---:|
| agents | 1.702 | 2.763 |
| prefix | 0.001 | 2.451 |
| scatter | 0.137 | 2.423 |
| deposit | 0.224 | 2.518 |
| merge | 0.237 | 2.484 |

A flat per-crossing cost is what `System.Threading.Barrier` charges at 32
participants, and the tick crosses it five times.

**Java is not a barrier problem.** Its barrier at 32 threads is 6.31 ms
against C's 4.53 — worse, but not by enough to explain anything. What does not
happen is the work halving: Java has the *fastest* per-thread work in the
field at four threads, gains almost nothing from 8 to 16, and at 32 is doing
2.5× as much per thread as C.

Why is not measured. The candidates are the machine's two core complexes and
whatever thread placement the JVM does across them, or a spin-then-park
barrier whose parking is being counted as work when a thread is descheduled
mid-phase. Distinguishing those needs wakeup counts rather than wall clock,
and §14 says so rather than this section guessing again.

The instrumentation itself costs 0.99–1.04× of the tick it measures in this
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
| Fortran | 6 239 | 2 966 | 1 453 | 922 | 739 | 1 034 | 8.4× |
<!-- /sb:table -->

**And it is tier A for every thread count**, `0xB4AC535B / 0x6A2394F4` from
T=1 to T=32. That is not a property of the atomic; it is a property of the
workload. SPEC-1's deposit adds a *constant*, so a cell's final value is its
starting value plus a count, and no order of arrival can change it. Swap the
constant for anything that depends on the agent and the atomic stops being
bit-exact immediately, while `binned` keeps working — which is why the spec
defines `binned` and not this.

Within that limit it is the cheapest parallelism in the document: **8.4× on
three directives**, behind only TypeScript and Go, both of which needed a
hand-written binned reduction with six barriers per tick to get there. The
peak is at T=16 and the regression at T=32 is the same one every other
language shows. Subject to the caveat above — in the previous sweep the same
three directives measured 9.6× and sat in the same place.

The measured T=1 baseline here is the reason [`bench/full-run.sh`](../bench/full-run.sh)
now passes `--threads` explicitly at every thread count and times the T=1 rows
under `/usr/bin/time`; see §14.

### `private` — reproducible per thread count only

<!-- sb:table p-private -->
| Language | T=1 | T=2 | T=4 | T=8 | T=16 | T=32 | Speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| Swift | 5 963 | 1 854 | 1 185 | 1 152 | 2 360 | 5 807 | 5.2× |
| C# | 6 371 | 2 146 | 1 328 | 1 325 | 2 589 | 5 744 | 4.8× |
| TypeScript | 11 156 | 6 425 | 3 657 | 2 422 | 2 909 | 5 943 | 4.6× |
| Haskell | 5 026 | 1 805 | 1 148 | 1 168 | 2 630 | 6 493 | 4.4× |
| Go | 4 934 | 1 890 | 1 189 | 1 154 | 2 342 | 5 335 | 4.3× |
| Java | 5 306 | 1 982 | 1 304 | 1 334 | 2 646 | 6 291 | 4.1× |
| Rust | 5 553 | 2 910 | 1 811 | 1 372 | 2 606 | 5 697 | 4.0× |
| C | 4 227 | 2 437 | 1 552 | 1 244 | 2 562 | 5 924 | 3.4× |
| Python | 8 013 | 4 991 | 2 876 | 2 359 | 2 373 | 3 272 | 3.4× |
| C++ | 4 149 | 2 449 | 1 516 | 1 222 | 2 543 | 5 894 | 3.4× |
<!-- /sb:table -->

**At 32 threads `private` drops below the serial runtime** — in C to 7105 ms
against 5682. The reduction reads `T` complete grids: at `medium` with 32
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
times instead of once, and that is what caps the speedup: only the agent
pass is parallel.

<!-- sb:table p-replicated -->
| Language | T=1 | T=2 | T=4 | T=8 | T=16 | T=32 | Speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| Perl | 4 198 | 2 422 | 1 739 | 1 530 | 1 780 | 2 696 | 2.7× |
<!-- /sb:table -->


### The bottleneck is the barriers

`SLIMEBENCH_PHASE_STATS=1` separates work from barrier wait
(C, `medium`, T=32, thread 0), milliseconds per tick:

<!-- sb:table barrier-phase -->
| Phase | work | barrier | total |
|---|---:|---:|---:|
| agents | 1.876 | 1.107 | 2.983 |
| prefix | **0.001** | 0.661 | 0.662 |
| scatter | 0.059 | 0.637 | 0.696 |
| deposit | 0.284 | 0.671 | 0.955 |
| merge | 0.209 | 0.771 | 0.980 |
| diffuse | 0.224 | — | 0.224 |
<!-- /sb:table -->

**Barriers are 39 % of the runtime at T=16 and 60 % at T=32.** Past sixteen
threads C stops getting faster not because the work stops dividing — it keeps
dividing, 4.77 ms per tick at T=16 against 2.62 at T=32 — but because the
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
| 1–5 | 3.297 | 3.760 | 0.928 | 0.856 | **0.420** |
| 6–10 | 0.490 | 0.925 | 0.402 | 0.350 | 0.357 |
| 11–25 | 0.428 | 0.347 | 0.364 | 0.298 | **0.309** |
| 26–50 | 0.402 | **0.251** | 0.334 | 0.285 | 0.289 |
| 51–100 | 0.263 | 0.253 | 0.333 | 0.286 | 0.287 |
| 201+ | 0.251 | 0.249 | 0.332 | 0.279 | 0.282 |
| **first tick** | **5.842** | **6.081** | **2.831** | **2.725** | **0.488** |
| best tick | 0.233 | 0.235 | 0.318 | 0.267 | 0.271 |
| **first / best** | **25.1×** | **25.9×** | **8.9×** | **10.2×** | **1.8×** |
<!-- /sb:table -->

**The JVM's first tick costs 25× its best one.** A benchmark of a hundred ticks
that forgot `--warmup` would report a number the JVM never actually runs at —
which is not hypothetical: both the class S and the class V phases of this
project did exactly that until the series this document is built from, and
class V had Java's vector kernel at 179 ms of diffusion against C's 64. With
the warm-up it is 79.5.

Two smaller results in the same table. **Turning tiering off makes the JVM
reach steady state sooner, not later** — C2-only is already at 0.251 by tick 26
where tiered is still at 0.402, and only catches up at 51. The intuition that
skipping C1 means a longer slow phase is the wrong way round here: C1 code is
slower than the interpreter is fast, and having to climb out of it costs more
than compiling once. And **.NET's ramp is a third of the JVM's** — 9.6× against
25.5× — but it converges to a worse number.

**Native AOT is flat.** 2.0× from first tick to best, and the first tick is
0.571 ms against the JVM's 6.346. There is no ramp because there is no
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

**Native AOT lands within 0.3 % of the optimising JIT with a full run's
profile behind it** — 0.2951 against 0.2958. Same optimiser, one with the data
the running program produced and one with none, and on this workload the data
is worth nothing measurable. The 16 % the default `jit` profile loses is
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
| JIT, tier-1 | 705.69 | 0.6 % | 98.36 |
| Native AOT, default | 716.81 | 0.7 % | 79.24 |
| Native AOT, `IlcInstructionSet=native` | **698.05** | 0.6 % | 97.66 |
<!-- /sb:table -->

**The ahead-of-time build wins the branchy half.** The three differ by 2.7 %
end to end, against run-to-run spreads of 0.6–0.7 % — so unlike most
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
| C# jit / tier1 | 156 KiB + runtime | 25.0 / 31.6 ms |
| C# ReadyToRun | 80 MiB | 19.9 ms |
| **C# Native AOT** | **3.8 MiB** | **3.7 ms** |
<!-- /sb:table -->

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

<!-- sb:table interpreters -->
| Runtime | ms/tick | spread | vs C |
|---|---:|---:|---:|
| numba | 0.2446 | 1.8% | 0.98× |
| c gcc `-O3 -march=native` | 0.2495 | 0.4% | 1.00× |
| Java, C2 only | 0.2529 | 1.5% | 1.01× |
| Java, tiered | 0.2546 | 1.8% | 1.02× |
| Go, `-gcflags=-B` | 0.2708 | 0.7% | 1.09× |
| **Java, `-Xint`** | **5.4735** | 0.7% | **21.9×** |
| **Python pure `--strict-f32`** | **84.1937** | — | **337×** |
<!-- /sb:table -->

Same algorithm, same exactness, same grid hash on every row: `0x89CFFAAC`. The
top four rows are inside each other's spread and are not ranked against one
another — numba, C, and the JVM in both configurations are the same number
here.

**CPython's interpreter is 15.4× slower than the JVM's.** "Interpreted" is not
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

`small` (1024², 262 144 agents), 100 ticks. One thread: 3.12 **1991 ms**,
3.14t **1868 ms**.

**`binned`** — milliseconds, with the speedup against the same interpreter at
one thread in brackets:

<!-- sb:table gil-binned -->
|  | 3.12 threads | 3.12 processes | 3.14t threads | 3.14t processes |
|---|---:|---:|---:|---:|
| T=2 | 1 526 (1.30×) | 1 311 (1.52×) | 1 259 (1.48×) | 1 217 (1.54×) |
| T=4 | 3 130 (0.64×) | 658 (3.03×) | 609 (3.07×) | 678 (2.76×) |
| T=8 | 7 073 (0.28×) | 620 (3.21×) | 527 (3.54×) | 645 (2.90×) |
| T=16 | 14 550 (0.14×) | 833 (2.39×) | 671 (2.78×) | 824 (2.27×) |
<!-- /sb:table -->

**`private`**, same units:

<!-- sb:table gil-private -->
|  | 3.12 threads | 3.12 processes | 3.14t threads | 3.14t processes |
|---|---:|---:|---:|---:|
| T=2 | 1 287 (1.55×) | 1 052 (1.89×) | 1 012 (1.85×) | 1 005 (1.86×) |
| T=4 | 2 660 (0.75×) | 485 (4.10×) | 498 (3.75×) | 505 (3.70×) |
| T=8 | 6 225 (0.32×) | 448 (4.45×) | 438 (4.27×) | 465 (4.01×) |
| T=16 | 13 013 (0.15×) | 528 (3.77×) | 462 (4.04×) | 531 (3.52×) |
<!-- /sb:table -->

**All 34 runs produce the same result:** grid `0x65DF83A7`, agents
`0xE02D7B6A` — across two interpreters, two backends, four thread counts and
both reductions.

### The first column is the actual finding

CPython 3.12 with threads does not merely fail to scale, it **degrades
super-linearly**: 14.6 seconds at 16 threads against 2.0 at one, so **7.3×
slower** than the serial run. And cleanly proportional to the thread count —
0.64×, 0.28×, 0.14× is almost exactly a halving per doubling.

That is more than "the GIL serialises" explains: pure serialisation would be
1.0×, not 0.14×. The order of magnitude fits convoying at the barriers. 146 ms
per tick at 16 threads with six barriers is 96 crossings at 1.5 ms each, and
CPython's switch interval is 5 ms — so a waiter that gives up the GIL at a
barrier does not get it straight back. I have not measured that; it is the
arithmetic working out, not the proof.

### Without the GIL, threads beat processes, and most where there are more barriers

Both columns are 3.14t, so the only variable is threads against processes. In
`binned`, threads win at every thread count: by 18 % at T=8 (527 against
645 ms) and by 19 % at T=16 (671 against 824). In `private` the margin is
smaller but the same sign — 6 % at T=8 (438 against 465) and 13 % at T=16
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

**The fastest value in the whole table belongs to CPython 3.14t** — 438 ms,
`private`, eight threads, with 3.12's eight processes 2 % behind it at 448.
Between two numbers that close the ordering is not the point; what matters is
that free-threading reaches the same place. So free-threading does not make this workload
faster. It makes the workaround unnecessary: no `shared_memory` block, no
hand-computed byte offsets, no `fork` requirement, no copying the arrays back
at the end. Roughly 120 of the 350 lines in
[`slimebench_mp.py`](../impl/python/slimebench_mp.py) exist only because
threads were not an option.

The single-thread comparison (1868 against 1991 ms) looks like an argument that
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
| C++, `-O3 -march=native` | AVX-512 intrinsics | 57.3 | — | 1.00× |
| C, `-O3 -march=native` | AVX-512 intrinsics | 59.4 | — | 1.04× |
| Rust, unchecked | AVX-512 intrinsics | 64.1 | — | 1.12× |
| Rust, safe | AVX-512 intrinsics | 65.4 | — | 1.14× |
| C, `-O3 -mavx2` | AVX2 intrinsics | 67.8 | — | 1.18× |
| C#, Native AOT + `IlcInstructionSet=native` | `Vector512<float>` | 68.1 | — | 1.19× |
| C++, `-O3 -mavx2` | AVX2 intrinsics | 69.2 | — | 1.21× |
| C#, JIT | `Vector512<float>` | 69.6 | — | 1.21× |
| Java, C2 only | Vector API, 512-bit | 76.3 | — | 1.33× |
| Java, tiered | Vector API, 512-bit | 78.2 | — | 1.36× |
| C#, `--simd-portable` | `Vector<float>`, 128-bit | 122.4 | — | 2.14× |
| C#, Native AOT, default | `Vector512` unavailable, 128-bit | 122.7 | — | 2.14× |
<!-- /sb:table -->

**All sixteen runs, across those twelve configurations, produce the same grid
hash `0xEEA4EAB3`** — five languages, three ways of reaching the vector unit,
four widths. SPEC-1 §8.1 is why: the
stencil does no cross-lane work, so each lane performs exactly the scalar
computation for its own cell in the same order.

**A portable vector type gets within 20–40 % of hand-written intrinsics.** C#
naming `Vector512<float>` lands at 1.19× of the best AVX-512 C++, and Java's
Vector API — which names no width at all, only `SPECIES_PREFERRED` — at 1.31×.
For source that contains no instruction set, that is a small price. Note the
ordering inside the intrinsics group is not dependable: AVX2 C beats AVX-512 C
in this series and the reverse in the last one, which is what a 7 % spread over
a memory-bound kernel looks like.

**.NET's portable `Vector<T>` will not use AVX-512.** On this machine
`Vector512.IsHardwareAccelerated` and `Avx512F.IsSupported` are both true and
`Vector<float>.Count` is 8 — 256 bits. `DOTNET_PreferredVectorBitWidth=512`
does not change it. Naming `Vector512<float>` explicitly is worth 1.4× on the
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

`-p:IlcInstructionSet=native` fixes it: 133.4 ms of diffusion becomes 93.0,
which is the JIT's number and a shade under it. It helps the scalar path too — that build is the C# row
in §2's `serial` table, at 1.51×, ahead of the JIT profiles — because the
baseline was costing the ordinary code as well. The trade is a binary that no
longer runs anywhere, which is exactly the trade a JIT does not have to make.

So §6's answer needs a qualifier: ahead-of-time compilation matches the JIT
*once someone tells it what it is compiling for*, and the default does not.
The default is also the one a build pipeline produces without being asked.



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

### The stencil gets 4.7×, the program 1.32×

Diffusion drops from 279 to 59 ms, but it is only a quarter of the runtime —
the agent pass stays scalar and dominates. Amdahl, in one line.

**Doubling the vector width buys little.** AVX2 against AVX-512, same source
and same compiler each time: 68.4 → 59.6 ms on gcc (15 %), 67.8 → 59.4 on
clang (14 %), 70.0 → 57.3 on g++ (22 %), 69.2 → 60.7 on clang++ (14 %). The
3×3 stencil reads 36 bytes to write 4 — it is
bandwidth-bound, the execution units are waiting on memory, and double the
width only helps at the load ports.

**Rust's "safe" wins the biggest factor here, and that is an artefact.** 6.1×
sounds impressive next to unchecked Rust's 4.3×, but it is only large because
the *scalar* comparison value is bad: with bounds checks the scalar stencil
costs 398 ms instead of 276. The SIMD kernel goes through raw pointers either
way and lands at 64–65 ms in both. Report factors against your own baseline
and you sometimes measure the baseline.

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

<!-- sb:table gpu -->
| Host | tiny | small | medium | large | huge |
|---|---:|---:|---:|---:|---:|
| cuda | 8 | 16 | 47 | 202 | 1 133 |
| cuda MCUPS | 3 126 | 6 360 | 9 002 | 8 296 | 5 924 |
| gl43 C | 292 | 696 | 2 534 | 9 872 | 42 485 |
| gl43 C MCUPS | 90 | 151 | 166 | 170 | 158 |
| gl43 Python | 241 | 693 | 2 545 | 9 912 | 42 500 |
| gl43 Python MCUPS | 109 | 151 | 165 | 169 | 158 |
<!-- /sb:table -->

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

<!-- sb:table render -->
| Language | Binding | SDL2 llvmpipe | SDL2 RTX 5080 | raylib llvmpipe | raylib RTX 5080 |
|---|---:|---:|---:|---:|---:|
| C | direct | 2.940 | 4.271 | 2.112 | 1.932 |
| C++ | direct | 2.905 | 4.502 | 2.120 | 1.957 |
| Haskell | `sdl2` / `foreign import` | 2.730 | 4.155 | 1.996 | 1.896 |
| Rust | `sdl2` / `raylib` crate | 3.025 | 4.424 | 2.093 | 1.946 |
| Python | pygame / cffi | 5.069 | 4.965 | 4.886 | 4.607 |
| Perl | FFI::Platypus | 116.125 | 117.595 | 77.527 | 77.265 |
<!-- /sb:table -->

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

<!-- sb:table gc -->
| runtime | collections | GC time | allocated over the whole run |
|---|---:|---:|---:|
| **Java** | **0** | 0 ms | — |
| Go | 1 | 0.57 ms | 5.2 MiB, 300 mallocs |
| C# | 1 gen0 / 1 gen1 / 1 gen2 | — | 4.7 MiB |
| Haskell | — | 0.000 s of 0.247 | 7.8 MiB |
| OCaml | 7 minor, 2 major | — | 12.1 MiB of minor words |
<!-- /sb:table -->

**The JVM never collects.** Go allocates 300 times in two hundred ticks, which
is startup and nothing else. The reason is structural: the simulation
allocates its grids and agent arrays once and writes into them for the rest of
the run, which is what SPEC-1 asks for and what every port does.

So the ranking in §2 is a ranking of these runtimes with their collectors
switched off in all but name. Allocation rate, pause distribution and the
throughput cost of a write barrier are among the largest differences between a
managed runtime and C, and **this benchmark exercises none of them.** That is a
limitation of the workload, not a property of the languages, and it should be
read into every row where a collected language appears.

It also explains a result that would otherwise be surprising: Java at 1.29× and
C# at 1.46× in §2 are managed runtimes performing like compiled ones, on the
one workload where the managed part is free.



<!-- sb:table footprint -->
| Language | Binary KiB (stripped) | RSS MiB |
|---|---:|---:|
| TypeScript | — | 80 |
| Python (numba) | — | 167 |
| Python (numba-fastmath) | — | 167 |
| Python (pure) | — | 18 |
| Python (pure-strict) | — | 18 |
| Perl (plain) | — | 22 |
| Perl (strict-f32) | — | 22 |
| C# (dotnet) | — | 41 |
| Java (javac) | — | 63 |
| C (gcc) | 50 | 18 |
| C (clang) | 50 | 18 |
| C++ (clang++) | 59 | 18 |
| C++ (g++) | 62 | 18 |
| Fortran (gfortran) | 74 | 18 |
| Swift (swift) | 96 | 32 |
| Rust (unchecked) | 442 | 18 |
| Rust (safe) | 471 | 18 |
| OCaml (strict-f32) | 1 178 | 18 |
| OCaml (f64) | 1 182 | 18 |
| Go (go) | 1 564 | 18 |
| Haskell | 2 779 | 29 |
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
| `prefix` is a serial O(T²) bottleneck | 0.001 ms of work. An artefact of my own instrumentation. |
| Fortran's OpenMP port peaks at 1.5×, and two threads are slower than one | Both figures were the same artefact. The port called `omp_set_num_threads` only above one thread, so `--threads 1` — the denominator of every speedup in that table — ran the parallel region 32 threads wide. It reported `"threads": 1` and the matching grid hash throughout, because SPEC-1's deposit adds a constant and the result does not depend on the thread count. The corrected sweep is an ordinary curve peaking at 8.4×. |
| A run that prints `failures: 0` had no failures | Those counters came from individual phases and never covered the phases `full-run.sh` drives itself. Sixteen class R targets failed in one series — four languages that were simply never built — and the run ended with a row count and a directory listing. There is now one tally over the whole run, covering failures, empty result files, and T=1 rows that used more than one core's worth of CPU; it exits non-zero. |
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

- **Why Java's work stops scaling.** §5 now measures it: Java has the fastest
  per-thread work in the field at four threads, gains almost nothing from
  eight to sixteen, and at thirty-two is doing 2.5× as much per thread as C.
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

- **OCaml 5.4 has a `Float32` module.** The C stub took tier A from 9.5× to
  4.7× by making the rounding one call instead of two. A native f32 type would
  make it zero calls, and the difference between 4.7× and whatever that gives
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
