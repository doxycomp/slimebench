# slimebench — Normative Simulation Spec

**Version:** `SPEC-1`
**Status:** normative. Every implementation in `impl/` MUST conform to this document.

This document defines the Physarum model precisely enough that **independent
implementations in different languages produce bit-identical results**. Where a
formulation would be ambiguous, the ambiguity is resolved here deliberately —
including in places where a different resolution would have been "more
natural".

The keywords MUST / SHOULD / MAY are used per RFC 2119.

---

## 0. Why so pedantic?

Physarum is a **chaotic** system: agents follow gradients they create
themselves. A 1 ULP deviation in a single agent's sensor evaluation at tick 3
causes that agent to eventually turn differently, therefore deposit somewhere
else, therefore influence neighbouring agents — after ~50–200 ticks two runs are
macroscopically different.

The consequence: **"looks similar" is not a correctness criterion.** Without
bit-exact verification you cannot, across nine ports, distinguish "different
language, same simulation" from "different language, subtly broken port" — and
then your benchmark is comparing apples to oranges.

Hence: an exactly specified operation order, an exactly specified PRNG, and
trigonometry from a table instead of from `libm` (see §4).

---

## 1. Numeric model

### 1.1 Data type

The pheromone grid and all agent coordinates are **IEEE-754 binary32 (`f32`)**.

**Rationale** (the alternative, `f64`, was rejected):

| Criterion | f32 | f64 |
|---|---|---|
| Grid memory bandwidth | 1× | 2× — and the diffusion pass is bandwidth-limited |
| GPU (consumer NVIDIA) | full rate | 1/32 rate → the GPU tier would be pointless |
| SIMD lanes per register | 8 (AVX2) / 16 (AVX-512) | 4 / 8 — half the vector width |
| Browser | `Float32Array` native | `Float64Array`, but canvas wants f32 precision anyway |

Since GPU compute and SIMD are explicitly in scope, f32 is the only consistent
choice. The price: Perl and pure Python cannot express f32 arithmetic natively
(both compute internally in doubles) and therefore fall into conformance tier B
(§7).

### 1.2 Arithmetic rules

1. Every individual operation MUST be carried out in `f32` and its result
   rounded to `f32` (rounding mode: round-to-nearest-even).
2. **No FMA contraction.** `a*b + c` MUST be executed as two rounded
   operations. In C/C++: `#pragma STDC FP_CONTRACT OFF` or
   `-ffp-contract=off`.
3. **No reassociation.** The parenthesisation given in §5 is binding.
4. **No reciprocal substitution.** `x / 12.0f` MUST be a division, not
   `x * (1.0f/12.0f)` — the two results differ.
5. No extended intermediate precision. In C, `FLT_EVAL_METHOD == 0` MUST hold
   (true on x86-64 with SSE; x87 is excluded).

> **A note on `-ffast-math` / `-Ofast`:** these flags violate rules 2–4
> deliberately. Builds using them are **not** tier A conformant and are sorted
> into a class of their own by the harness (§7.3). That is not a defect but
> precisely one of the measurements this project is about: *what does
> determinism cost?*

### 1.3 What does NOT apply

- No clamping, no saturation. Pheromone values may grow freely.
  (The steady state is `deposit / (1 - decay)` ≈ 167 per permanently visited
  cell; overflow to `inf` is practically impossible in f32.)
- No `NaN` handling. A correct implementation produces none.

---

## 2. Grid

- Width `W` and height `H` MUST be powers of two.
  That turns every wrap into a bit mask and is a prerequisite for the SIMD and
  GPU variants.
- Memory layout: **row-major**, dense, index `idx = (y << log2(W)) | x`.
- Boundary handling: **toroidal** (wrap on both axes).

### 2.1 Index wrapping (integer)

```
wrap_x(i) = i & (W - 1)
wrap_y(j) = j & (H - 1)
```

### 2.2 Coordinate wrapping (floating point)

Positions are kept in `[0, W)` and `[0, H)` respectively:

```
wrapf(v, m):
    if v <  0.0f:  v = v + m
    if v >= m:     v = v - m
    return v
```

A single correction step is enough, because no per-tick offset exceeds
`sensor_distance` (9.0) in magnitude and `m >= 512`.

> **Pitfall:** `wrapf` can return exactly `m` through rounding (for example
> `-1e-7 + 1024.0f == 1024.0f`). The cast to integer MUST therefore **always**
> be masked as well (§2.1). Never rely on `wrapf` alone.

---

## 3. Pseudo-random numbers

### 3.1 Generators

**SplitMix32** — for seeding and grid initialisation only:

```
splitmix32(state):            # state: u32, by reference
    state = state + 0x9E3779B9        # mod 2^32
    z = state
    z = (z XOR (z >> 16)) * 0x21F0AAAD
    z = (z XOR (z >> 15)) * 0x735A2D97
    return z XOR (z >> 15)
```

**xoshiro128++** — per agent, for decisions in the hot loop:

```
rotl(x, k) = (x << k) | (x >> (32 - k))

xoshiro128pp(s):              # s: u32[4], by reference
    result = rotl(s[0] + s[3], 7) + s[0]
    t = s[1] << 9
    s[2] = s[2] XOR s[0]
    s[3] = s[3] XOR s[1]
    s[1] = s[1] XOR s[2]
    s[0] = s[0] XOR s[3]
    s[2] = s[2] XOR t
    s[3] = rotl(s[3], 11)
    return result
```

All operations are **unsigned 32-bit arithmetic with wraparound**.

> **Why 32-bit and not PCG64?** A 64-bit PRNG would need `BigInt` in JavaScript
> (orders of magnitude slower) and emulation over two 32-bit words in
> WGSL/GLSL. xoshiro128++ is a direct one-liner in *every* target language and
> more than good enough in quality.

### 3.2 Uniform in [0, 1)

```
rnd01(u):    # u: u32
    return f32(u >> 8) / 16777216.0f
```

`u >> 8 < 2^24` is exactly representable in `f32`, and the division by `2^24` is
exact. The result is therefore bit-identical in every language.

### 3.3 Initialisation

**Grid** (its own stream, independent of the agent count):

```
sm = seed XOR 0x5BF03635
for i in 0 .. W*H-1:
    grid[i] = rnd01(splitmix32(sm)) * 100.0f
```

**Agents** (one independent stream per agent — which makes initialisation
parallelisable and order-independent):

```
for i in 0 .. N-1:
    sm = seed + 0x9E3779B9 * (i + 1)          # mod 2^32
    s[0] = splitmix32(sm)
    s[1] = splitmix32(sm)
    s[2] = splitmix32(sm)
    s[3] = splitmix32(sm)
    if s[0]|s[1]|s[2]|s[3] == 0: s[0] = 1     # xoshiro must not be all zero

    ax[i]  = rnd01(xoshiro128pp(s)) * f32(W)
    ay[i]  = rnd01(xoshiro128pp(s)) * f32(H)
    adir[i] = xoshiro128pp(s) % NDIR
```

The modulo bias in `% NDIR` is known and accepted — it is deterministic and
therefore irrelevant to comparability.

---

## 4. Directions and trigonometry

### 4.1 The problem

`sin()` and `cos()` are **not** bit-identical between implementations. glibc,
musl, Apple's libm, V8's fdlibm port, Rust's `f64::sin` and the GPU intrinsics
partly return different final bits for the same argument. In a chaotic system
that is enough to make any cross-language verification impossible.

### 4.2 The solution: quantised directions

An agent's heading is **not an `f32` angle but an integer index**:

```
NDIR = 1440            # resolution: 0.25° per step
adir ∈ [0, NDIR)
```

`sin`/`cos` come from a generated table with `NDIR` entries:

```
COS[d] = f32(cos(2*PI * d / NDIR))
SIN[d] = f32(sin(2*PI * d / NDIR))
```

The table is generated **once** by `spec/tools/gen_dirtable.py` and emitted as
**u32 bit patterns** into source for every language (`spec/data/` and
`impl/*/dirtable.*`). By construction it is therefore byte-identical across all
languages — no runtime `sin()` involved.

The generator is part of the repo and reproducible; the harness checks the
table checksum at the start of every implementation.

### 4.3 Derived constants

| Quantity | Radians | NDIR steps |
|---|---|---|
| Sensor angle | 0.2·π = 36° | **144** |
| Rotation angle | 0.2·π = 36° | **144** |

`NDIR = 1440` is chosen so that 36° corresponds to exactly 144 steps — no
rounding in the parameterisation.

**Side effect:** the table lookup is also faster than `sinf`/`cosf` (an 11.5 KB
table, fits in L1d). The quantisation is therefore not a pure cost.

If you want continuous angles, `--trig=libm` is available — that is explicitly
**tier B** and not cross-language verifiable.

---

## 5. Simulation step

### 5.1 Parameters (defaults)

| Name | CLI | Default | Type |
|---|---|---|---|
| Sensor distance | `--sensor-dist` | `9.0` | f32 |
| Sensor angle | `--sensor-steps` | `144` | int (NDIR steps) |
| Rotation angle | `--rot-steps` | `144` | int (NDIR steps) |
| Step length | `--step` | `1.0` | f32 |
| Deposit | `--deposit` | `10.0` | f32 |
| Decay | `--decay` | `0.94` | f32 |
| Diffusion kernel | fixed | `[[1,1,1],[1,4,1],[1,1,1]] / 12` | — |

### 5.2 Order within a tick

```
1. agent pass          (§5.3)
2. diffusion/decay pass (§5.4)
```

This order follows the reference (programmingchaos): a tick's deposits are
diffused and damped **within the same tick**.

### 5.3 Agent pass

Agents are processed in **index order 0 → N−1**.

```
sense(x, y, d):
    sx = wrapf(x + COS[d] * sensor_dist, W)
    sy = wrapf(y + SIN[d] * sensor_dist, H)
    return grid[ ((int(sy) & (H-1)) << log2W) | (int(sx) & (W-1)) ]

for i in 0 .. N-1:
    d = adir[i];  x = ax[i];  y = ay[i]

    dl = (d - sensor_steps + NDIR) mod NDIR
    dr = (d + sensor_steps)        mod NDIR

    FL = sense(x, y, dl)
    FC = sense(x, y, d)
    FR = sense(x, y, dr)

    if   FC >= FL and FC >= FR:  pass                       # straight on
    elif FC <  FL and FC <  FR:                             # dead end: random
        if xoshiro128pp(rng[i]) & 1: d = (d + rot_steps)        mod NDIR
        else:                        d = (d - rot_steps + NDIR) mod NDIR
    elif FL >  FR:               d = (d - rot_steps + NDIR) mod NDIR
    else:                        d = (d + rot_steps)        mod NDIR

    x = wrapf(x + COS[d] * step, W)
    y = wrapf(y + SIN[d] * step, H)

    idx = ((int(y) & (H-1)) << log2W) | (int(x) & (W-1))
    DEPOSIT_TARGET[idx] = DEPOSIT_TARGET[idx] + deposit      # see §5.5

    adir[i] = d;  ax[i] = x;  ay[i] = y
```

Note: the order is **rotate first, then move in the new direction**. The PRNG is
consumed **only** in the dead-end branch — which makes each agent's PRNG state
depend on the course of the simulation. That is intentional and part of the
checksum.

### 5.4 Diffusion and decay pass

Reads from `src`, writes to `dst` (separate buffers, swapped afterwards). The
summation order is **binding**:

```
for y in 0 .. H-1:
    ym = (y - 1) & (H-1);  yp = (y + 1) & (H-1)
    for x in 0 .. W-1:
        xm = (x - 1) & (W-1);  xp = (x + 1) & (W-1)

        acc =   src[ym][xm]
        acc = acc + src[ym][x ]
        acc = acc + src[ym][xp]
        acc = acc + src[y ][xm]
        acc = acc + 4.0f * src[y][x]
        acc = acc + src[y ][xp]
        acc = acc + src[yp][xm]
        acc = acc + src[yp][x ]
        acc = acc + src[yp][xp]

        dst[y][x] = (acc / 12.0f) * decay
```

`4.0f * v` is exact (a power of two) and MUST **not** be replaced by
`v + v + v + v` — the result would be identical, but rule §1.2.3 forbids
rewrites on principle, so that reviews stay mechanically checkable.

The division by `12.0f` and the subsequent multiplication by `decay` are **two**
rounded operations, in exactly that order.

### 5.5 Update modes

There are two modes. They are **different simulations** and each has its own
reference checksums. Every implementation MUST support both.

| Mode | `DEPOSIT_TARGET` | Property |
|---|---|---|
| `serial` (default) | `grid` itself, in place | Later agents see earlier deposits from the same tick. Matches the reference. **Inherently sequential.** |
| `deferred` | a separate buffer `dep`, zeroed each tick | All agents see the same grid snapshot. Before the diffusion pass, `grid[i] = grid[i] + dep[i]`. **Order-independent → parallelisable.** |

> **This is the most important design decision in the project.** The `serial`
> mode is the faithful implementation of the source material, but it cannot be
> deterministically parallelised even in principle — one agent's deposit
> changes what the next agent measures. Spread the agent loop over 32 threads
> and you get a different result every run.
>
> `deferred` resolves that (and is arguably more physically plausible:
> simultaneous rather than sequential update), at the cost of one extra pass
> over the grid.
>
> **Comparison rule: `serial` only against `serial`, `deferred` only against
> `deferred`.** Benchmark classes P/V/G (§8) use `deferred` exclusively.

### 5.6 Determinism under parallelisation

Atomic `f32` additions are **not** permitted — their result depends on
execution order. Beyond that, per pass:

**Diffusion pass:** unconditionally order-independent. Every output cell is
computed from `src` alone, and there is no dependency between output cells.
Parallelising over rows is therefore **guaranteed bit-identical** to the serial
run, for any thread count.

**Agent pass:** sensing, rotation and movement are independent per agent (in
`deferred` mode the grid is read-only while they happen) and are therefore
likewise guaranteed bit-identical. The only critical part is the
**accumulation of deposits**.

For a cell hit by agents `i₁ < i₂ < … < i_k`, §5.3 prescribes the sum
`((0 + d) + d) + …` in index order. Floating-point addition is not associative,
so a different grouping is in general a different result.

> **An important limitation that an earlier version of this spec was missing:**
> thread-local deposit buffers with a subsequent reduction in fixed thread
> order are **not automatically** bit-identical to the serial run. They produce
> `(d_thread0) + (d_thread1) + …`, a different parenthesisation from the serial
> chain. What is guaranteed is only determinism **for a given thread count**,
> not independence from it.

The spec therefore defines two reduction strategies, reported separately:

| Strategy | `--deposit-reduce` | Guarantee | Memory |
|---|---|---|---|
| Thread-local buffers | `private` | reproducible **per thread count** | `T × W × H × 4 bytes` |
| Spatial binning | `binned` | **bit-identical to T = 1**, for any thread count | `N × 4 bytes` |

`binned` reaches the stronger guarantee like this: the agent pass writes only
each agent's target cell into an array. The agents are then grouped by row
block with a **stable counting sort**; each thread owns one row block and
applies its deposits in ascending agent index order. Per cell that reproduces
exactly the serial chain.

The price is load imbalance: Physarum agents cluster on the filaments by
construction, so the row blocks are unevenly occupied.

> **A note on the default parameters.** With `deposit = 10.0` and realistic hit
> counts per cell, every partial sum `k · 10` stays below 2²⁴ and is therefore
> exactly representable in `f32` — the addition is then *accidentally*
> order-independent under `private` too. No implementation may rely on that:
> with `--deposit 0.1` it no longer holds. The harness checks bit-identity
> against `T = 1` rather than assuming it.

---

## 6. Checksums

### 6.1 SB-FNV32 (word-wise)

Not standard FNV — a word-wise variant, so that it is fast in every language:

```
sbfnv32(words):
    h = 0x811C9DC5
    for w in words:
        h = h XOR w
        h = (h * 0x01000193) mod 2^32
    return h
```

### 6.2 Grid hash

The grid is interpreted as a sequence of `W*H` `u32` words (the little-endian
bit patterns of the `f32` values, in index order) and passed through
`sbfnv32`.

### 6.3 Agent hash

Over the sequence `[bits(ax[0]), bits(ay[0]), u32(adir[0]), bits(ax[1]), ...]`.

Two separate hashes, because they localise different bugs: grid hash diverges,
agent hash matches → bug in the diffusion pass. Both diverge → bug in the agent
pass (or an earlier cause).

### 6.4 Intermediate states

With `--hash-every N` an implementation MUST print a hash line after every Nth
tick. That allows the **first** diverging tick to be binary-searched — by far
the most useful tool there is when porting.

---

## 7. Conformance tiers

### 7.1 Tier A — bit-exact

Grid and agent hash match the reference vectors (`spec/testvectors/`)
**exactly**.

Expected for: **C, C++, Rust, Haskell, Go, Swift, TypeScript**
(`Float32Array` + `Math.fround`) and **Python with NumPy** (`float32`).

### 7.2 Tier B — numerically equivalent

Bit-exactness is achievable but uneconomic.

Worth understanding: doubles **can** reproduce f32 arithmetic exactly. Double
rounding is harmless when the intermediate format has at least `2p+2` bits, and
`53 ≥ 2·24+2`. `round_f32(f64_op(a,b))` is therefore identical to the f32
operation for `+ − × ÷`. That is exactly what the TypeScript implementation
relies on with its `Math.fround` around every operation — and that
implementation is demonstrably tier A.

Perl and pure Python simply have no cheap `fround`: rounding goes through
`pack`/`unpack` or `struct`, so one function call per operation — and the
diffusion kernel alone needs nine of them per cell.

Hence: **the default is tier B**, and the flag `--strict-f32` switches to
tier A. Both implementations are demonstrably bit-identical to the C reference
with `--strict-f32`.

The gap between the two runs is itself a measurement — *what does bit-exactness
cost in this language?* Measured at 128×128 / 4096 agents:

| Language | tier B | tier A (`--strict-f32`) | surcharge |
|---|---:|---:|---:|
| Python (pure) | 9.44 ms/tick | 21.88 ms/tick | **2.3×** |
| Perl | 9.40 ms/tick | 31.15 ms/tick | **3.3×** |

That is considerably cheaper than expected, and that is itself the interesting
finding: in a language that already pays an interpreter dispatch per operation,
nine extra C-level calls per cell largely disappear into the overhead that was
there already. The original estimate in this spec was two orders of magnitude —
it was simply wrong.

> **Difference between the two tier B implementations:** Python stores the grid
> in an `array('f')`, so it rounds to f32 on *every store* and diverges only in
> the intermediate results. A Perl array stores full NVs, so it does not round
> at all. Perl's tier B therefore drifts more than Python's.

Tier B is verified through tolerance metrics after N ticks. The tolerances are
**separated by metric**, because a single number for both kinds would be wrong:

| Metric | Tolerance | Why |
|---|---|---|
| Total mass `Σ grid` | rel. **1e-6** | conserved quantity |
| Mean | rel. **1e-6** | conserved quantity |
| Standard deviation | rel. **2e-2** | structure-sensitive |
| Fraction of cells > 1.0 | abs. **2e-2** | structure-sensitive |

Justification, measured with the tier B Python implementation against the C
reference (128×128, 4096 agents):

| Ticks | `sum`/`mean` | `stddev` | `frac>1` |
|---|---|---|---|
| 1 | 1.7e-10 | 1.8e-09 | 0 |
| 100 | 5.1e-09 | 2.6e-04 | 0 |
| 1000 | 8.6e-09 | 6.7e-04 | 7.3e-04 |

Total mass and mean are essentially conserved: how much pheromone is in the
grid follows from the deposit rate and the decay, and depends hardly at all on
*where* the agents went. They stay at 1e-9 — which is why the tolerance here
may be **tighter** than originally specified. A wrong decay value, a wrong
deposit amount or a wrongly normalised convolution breaks 1e-6 immediately.

Standard deviation and the fraction of bright cells, by contrast, measure
*where* the filaments are. Under chaos that necessarily diverges. Held at 1e-4,
the check would only ever report the chaos and never a bug.

Default for: **Perl** and **pure Python**.

### 7.3 Tier C — fast-math / approximate

Builds with `-ffast-math`, `-Ofast`, `-funsafe-math-optimizations`, GPU
backends with a fast-math default, or SIMD variants with a reordered reduction.
Verified like tier B. Reported **separately** and never placed in the same
table row as tier A.

---

## 8. Benchmark classes

Each class is reported separately. Comparing across class boundaries is
meaningless.

| Class | Meaning | Update mode | Threads |
|---|---|---|---|
| **S** | Scalar, one thread. **The language axis.** | `serial` | 1 |
| **P** | Multi-threaded, scalar | `deferred` | N |
| **V** | SIMD (explicit or auto-vectorised), and hand-written assembly | both | 1 |
| **PV** | SIMD + multi-threaded | `deferred` | N |
| **G** | GPU compute | `deferred` | — |
| **R** | Rendering backend (§11.1) | — | 1 |

Class **S** is the actual answer to "how fast is language X". Everything else
measures how accessible the language's ecosystem makes parallelism — also
interesting, but a different question.

### 8.1 Class V is not automatically tier C

An earlier version of this spec claimed that SIMD necessarily lands in
conformance tier C because the reduction gets reordered. For the diffusion
kernel that is **not** true.

The kernel has no cross-lane reduction at all: each lane computes one output
cell and performs exactly the same operation sequence, in the same order, as
the scalar loop. Lane *i* produces bit for bit what the scalar version produces
for cell *i*.

Therefore: **an element-wise vectorisation of the diffusion pass is tier A**,
provided two conditions hold:

1. **No FMA.** `4.0f * c + acc` as a single rounded operation is a different
   number. Multiplication and addition stay separate intrinsics.
2. **A real division.** `_mm*_div_ps` by 12, not a multiplication by the
   reciprocal (§1.2.4).

Vectorising the **agent pass** would be a different matter: there, several
agents per vector would have to deposit into the same cell, which requires
conflict resolution and therefore an ordering decision. That would be tier C —
and is not implemented.

The same reasoning covers hand-written assembly: `impl/asm/sb_diffuse_avx512.S`
performs the nine additions per lane in the prescribed order, keeps the
multiply by 4 as a separate `VMULPS` and divides with a real `VDIVPS`, and is
therefore tier A as well.

### 8.2 Class G is likewise not automatically tier C

The same assumption stood for GPU compute in this spec and has likewise been
refuted: the CUDA implementation is **bit-identical** to the C reference.

Three things have to come together:

1. **No FMA contraction.** `nvcc -fmad=false`. Without it the compiler fuses
   `4.0f * c + acc` and the diffusion pass diverges.
2. **Correctly rounded division.** `--prec-div=true` (the nvcc default). A
   reciprocal approximation violates §1.2.4.
3. **Integer deposit atomics.** `atomicAdd` on `float` is *not* deterministic —
   the order in which threads arrive decides the rounding.
   Instead an `atomicAdd` on `uint` counts the hits per cell (integer addition
   is exact and order-independent), and the multiplication by `deposit`
   happens once afterwards.

   That reproduces the serial chain exactly as long as `k · deposit` stays
   exactly representable — the same limitation as the CPU strategy `private`
   in §5.6, and the harness checks it rather than assuming it.

> **But it depends on the driver, not only on the language.** The same GLSL
> compute kernel with the same `precise` qualifiers is bit-exact on Mesa's
> `llvmpipe` and up to 2 ULP off on Mesa's D3D12 backend. In GLSL `precise`
> forbids reordering and fusion but does **not** force correctly rounded
> division — unlike CUDA's `--prec-div=true`. Class G therefore has to be
> graded per backend, not as a whole.
>
> `precise` belongs in more places than one first thinks: on the diffusion
> accumulator alone it was not enough, because `x + cos*step` in the agent pass
> gets fused too and displaces the agent by one ULP.

---

## 9. Presets

| Preset | W × H | Agents | Density | Ticks | Purpose |
|---|---|---|---|---|---|
| `tiny` | 512 × 512 | 65 536 | 25 % | 1 000 | CI, smoke test, conformance |
| `small` | 1024 × 1024 | 262 144 | 25 % | 1 000 | quick comparison, bearable even for Perl |
| `medium` | 2048 × 2048 | 1 048 576 | 25 % | 1 000 | **the headline figure** |
| `large` | 4096 × 4096 | 4 194 304 | 25 % | 500 | bandwidth stress |
| `huge` | 8192 × 8192 | 16 777 216 | 25 % | 100 | push class G |
| `browser` | 1024 × 1024 | 262 144 | 25 % | ∞ | interactive |

`huge` is meant for class G and cannot sensibly be run to completion on a CPU:
1.25 GB of buffers and 16.8 million agents. It exists because `medium` does not
saturate an RTX 5080 — there `small` and `medium` cost practically the same,
which makes the measured speedup a lower bound rather than an answer.

Agent density is 25 % of the cells. (The source material uses 0.6 agents per
*cell* at 8 px cell size — transferred to pixel resolution that would be
absurdly many.)

Reference seed: **`12345`**.

---

## 10. CLI contract

Every implementation MUST accept these arguments. Unknown arguments MUST be
rejected with exit code 2 and an error message on stderr (silently ignored
flags have ruined more benchmarks than any compiler bug).

```
--preset NAME          tiny|small|medium|large|huge|browser
--width N --height N   powers of two
--agents N
--ticks N
--seed N               default 12345
--update MODE          serial|deferred        (default serial)
--threads N            default 1
--sensor-dist F  --sensor-steps N  --rot-steps N
--step F  --deposit F  --decay F
--deposit-reduce MODE  private|binned  (only with --threads > 1, §5.6)
--simd / --no-simd     vectorised diffusion pass (class V, §8.1)
--headless             no window (the default for benchmark binaries)
--render               open a window
--freeze-sim           halt the simulation (render benchmark only, §11.1)
--json                 result as JSON on stdout (last line)
--hash-every N         intermediate hashes on stderr
--dump-grid PATH       write the raw f32 grid at the end (debugging)
--warmup N             N ticks before timing starts (default 0)
```

Implementations MAY accept further flags for features the spec does not
mandate — `--asm`, `--mp-backend`, `--hud` and `--strict-f32` are examples —
provided the flags above keep their meaning.

### 10.1 Result JSON

With `--json`, the **last line** of stdout MUST have exactly this schema:

```json
{
  "schema": 1,
  "impl": "c",
  "backend": "headless",
  "class": "S",
  "preset": "medium",
  "width": 2048, "height": 2048, "agents": 1048576,
  "ticks": 1000, "seed": 12345, "update": "serial", "threads": 1,
  "grid_hash": "0x1a2b3c4d",
  "agent_hash": "0x5e6f7a8b",
  "dirtable_hash": "0x9c0d1e2f",
  "ms_total": 12345.678,
  "ms_agents": 8000.0,
  "ms_diffuse": 4345.678,
  "ms_per_tick_mean": 12.345678,
  "ms_per_tick_median": 12.3,
  "ms_per_tick_p99": 13.1,
  "maups": 84.9,
  "mcups": 339.5
}
```

- `maups` = million agent updates per second = `agents * ticks / ms_total / 1000`
- `mcups` = million cell updates per second = `width * height * ticks / ms_total / 1000`
- Times MUST be measured with a monotonic clock.
- Initialisation and hash computation do **not** count towards `ms_total`.

RSS, binary size and build time are measured from the outside by the harness —
not by the implementation itself.

---

## 11. Rendering (normative, so that all backends look the same)

```
u8 = clamp( int( grid[idx] * 255.0f / display_max ), 0, 255 )     # display_max = 100.0
pixel = RGBA(u8, u8, u8, 255)
```

Optional colour palettes are allowed but MUST sit behind a flag and are never
part of a benchmark. Rendering is **never** executed under `--headless`.

### 11.1 Render benchmark (class R)

A rendering backend comparison measures the upload path
grid → texture → screen. If the simulation keeps running during it, the
simulation dominates the frame and the backends become indistinguishable.

Hence **`--freeze-sim`**: it halts the simulation, and every frame re-uploads
the same grid. `--ticks N` then means *N frames*.

The measurement runs from `sb_render_gray` up to and including
Present/EndDrawing. Event handling lies outside the measurement window.

An on-screen overlay (HUD), where an implementation has one, MUST be either
switched off or timed separately and subtracted — it is not part of the upload
path. Under `--json` it defaults to off.

Backends MAY choose the pixel format their API accepts most cheaply — forcing a
common format would normalise away exactly the difference the class is about.
The chosen format belongs in the documentation.

Result JSON with `--json`, last line on stdout:

```json
{
  "schema": 1,
  "impl": "c", "backend": "raylib", "class": "R",
  "preset": "small", "width": 1024, "height": 1024,
  "frames": 300,
  "ms_render_mean": 2.107395,
  "ms_render_median": 2.046034,
  "ms_render_p99": 2.591799,
  "fps_equiv": 488.75,
  "mpixels_per_s": 512.5
}
```

Class R results are **never** placed against class S results.

---

## 12. Reference vectors

`spec/testvectors/SPEC-1.json` holds the grid hash, the agent hash and the
tier B metrics for three sizes × both update modes × several tick counts,
produced by the C reference implementation (`impl/c`, gcc,
`-O2 -ffp-contract=off`).

| Size | Dimensions | Ticks | Purpose |
|---|---|---|---|
| `micro` | 128×128, 4 096 agents | 1, 10, 100 | runnable in seconds even for Perl and pure Python |
| `tiny` | 512×512, 65 536 agents | 1, 10, 100, 1000 | the standard case |
| `small` | 1024×1024, 262 144 agents | 1, 10, 100 | different cache and wrapping behaviour |

Slow implementations declare `conformance_set = "micro"` in
`bench/targets.toml` and check only the smallest size. They check the same
vectors as everyone else — just fewer of them.

Produced and verified with:

```bash
python3 bench/run.py conformance --write   # regenerate (from the reference only)
python3 bench/run.py conformance           # check every target
```

If a new port diverges, **the port is wrong until proven otherwise**, not the
reference. If the reference turns out to be wrong, the spec version is raised
to `SPEC-2` and *all* vectors are regenerated — individual vectors are never
"adjusted".
