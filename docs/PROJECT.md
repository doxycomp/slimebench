# slimebench — Physarum benchmarking suite

The same simulation, ten languages, two rendering backends, many compilers —
and a verification mechanism that proves it really is the same simulation
running.

## 1. What this is about

Physarum polycephalum (slime mould) can be reproduced with a startlingly simple
agent model (Jeff Jones, 2010). Each agent knows only a position, a heading and
three sensors. Out of that local rule come global transport networks — without
the word "network" appearing anywhere in the code.

Per tick:

1. **Chemotaxis** — the agent reads three points ahead of it (left, straight, right).
2. **Rotation** — it turns toward the strongest signal.
3. **Movement** — one step forward.
4. **Deposit** — it leaves pheromone behind.
5. **Diffusion** — a 3×3 blur over the whole grid.
6. **Decay** — everything is multiplied by 0.94.

For a language and compiler comparison this is close to an ideal workload:

- **Two complementary access patterns.** The agent pass is pure random-access
  gather/scatter (cache-hostile, latency-bound); the diffusion pass is a dense
  stencil stream (bandwidth-bound, vectorisable). Languages and compilers
  behave completely differently in the two phases — which is why the suite
  measures them **separately**.
- **No I/O, no allocation in the hot loop, no libraries.** What you measure is
  code generation and memory behaviour, not the ecosystem.
- **Chaotic.** Tiny numerical deviations grow visibly — which makes
  verification hard and therefore turns it into the genuinely interesting part
  of the project (see §3).
- **Scales smoothly** from 512² to 8192² and from 65k to 16M agents.

## 2. Architecture

```
spec/                normative specification + generated direction table
  SPEC.md            <- the single source of truth
  tools/             codegen for the trig table (every language)
  testvectors/       reference checksums and tier B metrics
impl/
  c/                 reference implementation: core + headless + SDL2 + raylib
  cpp/               idiomatic C++20, the same three frontends
  rust/              safe and unchecked variants behind a cargo feature
  haskell/           IOUArray in IO, strict throughout, plus an idiomatic port
  go/                goroutines and a hand-built barrier
  swift/             Foundation.Thread, three safety models
  lean/              Lean 4, tail recursion over Array Float32 (class S)
  ts/                core + Node headless + browser entry point
  web/               HTML5 canvas frontend (generated bundle)
  python/            pure (tier B / --strict-f32) and numpy (deferred only)
  perl/              tier B / --strict-f32
  asm/               hand-written AVX-512 diffusion kernel (class V)
  cuda/, glcompute/, pygl/   GPU hosts (class G)
  shim/              by-value raylib wrappers shared by Haskell and Perl
bench/
  run.py             build and measurement harness, conformance check, report
  targets.toml       registry: language × backend × compiler × profile
  full-run.sh        one complete measurement series over the whole matrix
  preflight.sh       what this machine can actually measure
  tables.py          the RESULTS.md tables, from a result directory
  charts.py          the RESULTS.md charts, from the same directory
  gridstat.py        inspect a grid dump, PNG preview
scripts/
  setup-wsl.sh       install toolchains (in phases)
  stage-wsl.sh       mirror the repo onto the Linux filesystem and measure
results/             JSONL measurement series
docs/RESULTS.md      the evaluated results
```

Every implementation is **strictly split in two**: a simulation core with no
input or output at all, and interchangeable frontends on top (headless / SDL2 /
raylib / canvas). That is the only way to separate compute time from render
time — and the only way the SDL2-versus-raylib comparison is fair, because both
are handed exactly the same byte buffer.

## 3. The actual trick: verification

The problem such comparison projects normally founder on:

> After 200 ticks two implementations look different. Was that a porting bug,
> or just different rounding in the last bit?

In a chaotic system both causes are optically **indistinguishable** after a few
hundred ticks. Without an answer to that, you may end up comparing a correct
implementation against a broken one.

slimebench solves it with four building blocks:

| Building block | Effect |
|---|---|
| **Prescribed operation order** (SPEC §5.4) | Floating-point addition is not associative. The summation order in the diffusion kernel is fixed normatively. |
| **Generated trig table** (SPEC §4) | `sin`/`cos` are **not** bit-identical between glibc, V8, Rust and GPU drivers. So headings are quantised to integers (NDIR=1440) and the table is generated into every language as u32 bit patterns. Side effect: faster than `sinf`. |
| **Portable 32-bit PRNG** (SPEC §3) | xoshiro128++ and SplitMix32, pure 32-bit integer arithmetic — directly expressible in JS, Perl, GLSL and WGSL, where 64-bit is expensive or unavailable. |
| **Checksums** (SPEC §6) | Separate hashes for grid and agents. If only the grid diverges the bug is in the diffusion pass; if both diverge it is in the agent pass. `--hash-every N` binary-searches the first diverging tick. |

**Result:** eight of ten languages — C, C++, Rust, Haskell, Go, Swift, Lean,
TypeScript and Python/numpy — are bit-exact against the C reference, on the
grid *and* the agent checksum, across three grid sizes × both update modes ×
tick counts up to 1000. Python (pure) and Perl reach the same with
`--strict-f32`; without the flag they run in tier B.

That makes the question above answerable: if a port diverges, it is a bug, not
a rounding artefact.

And where bit-exactness is impossible in principle (fast-math, GPU, SIMD with a
reordered reduction), the spec says so in advance and reports those runs in a
conformance tier of their own, instead of quietly placing them alongside.

## 4. What gets measured

Per run, reported by the implementation itself:

- total time, **split into agent pass and diffusion pass**
- ms/tick as median and p99 (not just the mean — outliers are informative)
- MAUPS (million agent updates/s) and MCUPS (million cell updates/s)
- grid and agent checksum

Measured from the outside by the harness, so nobody can flatter themselves:

- peak RSS (via `os.wait4`, no `time(1)` needed)
- binary size, raw and `strip`ped
- build time

## 5. Benchmark classes

Comparing across class boundaries is meaningless, and the report prevents it:

| Class | What it measures |
|---|---|
| **S** | Scalar, one thread. **The language axis** — this is where "how fast is language X" lives. |
| **P** | Multi-threaded. Measures how accessible the ecosystem makes parallelism. |
| **V** | SIMD, and hand-written assembly. Realistic only for C, C++ and Rust. |
| **G** | GPU compute. Measures **not** the language but the shader compiler and driver. |
| **R** | Rendering. Measures the upload path, and mostly the pixel format. |

## 6. Environment

The canonical measurement host is **WSL2 / Ubuntu 24.04** — gcc, clang, rustc,
GHC, SDL2 and raylib are all first-class there.

One warning is built into the harness: if the repo sits under `/mnt/c`, every
file access goes through the 9p bridge, and build times and process startup
measure the bridge instead of the code. `scripts/stage-wsl.sh` mirrors the repo
onto the Linux filesystem first.

Reference machine: AMD Ryzen 9 9950X3D (16C/32T), NVIDIA RTX 5080.
