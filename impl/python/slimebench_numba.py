#!/usr/bin/env python3
"""slimebench -- numba implementation of SPEC-1 (conformance tier A).

This is deliberately the *same program* as `slimebench_pure.py`: the same
scalar loops, the same order of operations, the same variable names. The only
difference is that the kernels are decorated with `@njit`, and that the arrays
are numpy arrays of a fixed dtype rather than `array('f')`.

That makes the pair a controlled experiment. Pure Python and numba run
identical source shapes, so the ratio between them is the cost of the
interpreter and nothing else -- not a better algorithm, not vectorisation, not
a different memory layout.

Two things fall out of it, and they are the reason this target exists:

  * Pure Python needs `--strict-f32` to reach tier A, because Python has no
    f32 arithmetic: every intermediate is f64 unless it is forced through a
    struct round-trip, which costs 2.3x. numba has f32 as a real type, so it
    is tier A *by default*, at no cost. Exactness is free here and expensive
    one language-runtime away, in the same language.

  * `--fastmath` compiles the identical source with LLVM's fast-math flags.
    It is faster and it is conformance tier C -- the hash changes. Two tiers
    from one source text, selected by a flag, which is the cheapest available
    demonstration of what SPEC-1 section 8 is for.

Compilation is not free and must not land inside the measurement. Every kernel
is compiled against a 4x4 grid before the clock starts, and the cost of doing
so is reported on stderr as `jit_compile_ms`.
"""

from __future__ import annotations

import sys
import time

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])

from slimebench import common
from slimebench.dirtable import COS, NDIR, SIN, COS_BITS, SIN_BITS

FNV_OFFSET = 0x811C9DC5
FNV_PRIME = 0x01000193
MASK32 = 0xFFFFFFFF


def _build(fastmath: bool):
    """Compile the kernels. Called once, with fastmath off or on.

    The kernels are defined inside the factory so that both variants come from
    one source text -- a tier A build and a tier C build of the same program.
    """
    from numba import njit

    jit = njit(fastmath=fastmath, cache=False)

    # ---- PRNG (SPEC-1 section 3.1) --------------------------------------
    #
    # Integer state is held in int64 and masked, exactly as the pure-Python
    # version does. Every intermediate fits: the widest is
    # 0x735A2D97 * 0xFFFFFFFF = 8.3e18, under int64's 9.2e18. Using uint32
    # locals instead would invite numba's promotion rules into the middle of
    # a bit-exact PRNG, which is not a place to have opinions.

    @jit
    def splitmix32(state):
        state = (state + 0x9E3779B9) & MASK32
        z = state
        z = ((z ^ (z >> 16)) * 0x21F0AAAD) & MASK32
        z = ((z ^ (z >> 15)) * 0x735A2D97) & MASK32
        return state, z ^ (z >> 15)

    @jit
    def xoshiro128pp(s, o):
        s0 = np.int64(s[o])
        s1 = np.int64(s[o + 1])
        s2 = np.int64(s[o + 2])
        s3 = np.int64(s[o + 3])
        t0 = (s0 + s3) & MASK32
        result = ((((t0 << 7) | (t0 >> 25)) & MASK32) + s0) & MASK32
        t = (s1 << 9) & MASK32
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = ((s3 << 11) | (s3 >> 21)) & MASK32
        s[o] = np.uint32(s0)
        s[o + 1] = np.uint32(s1)
        s[o + 2] = np.uint32(s2)
        s[o + 3] = np.uint32(s3)
        return result

    @jit
    def rnd01(u):
        return (u >> 8) / 16777216.0

    # ---- initialisation --------------------------------------------------
    #
    # f64 on purpose. The spec's initial fill is `rnd01(u) * 100.0` evaluated
    # in double and rounded once on the store, which is what C does and what
    # `array('f')` does in the pure version. Computing it in f32 instead would
    # round twice and diverge in the low bit of a few cells.

    @jit
    def k_init_grid(grid, seed):
        sm = seed ^ 0x5BF03635
        for i in range(grid.size):
            sm, u = splitmix32(sm)
            grid[i] = np.float32(rnd01(u) * 100.0)

    @jit
    def k_init_agents(ax, ay, adir, rng, seed, n, fw, fh):
        for i in range(n):
            sm = (seed + 0x9E3779B9 * (i + 1)) & MASK32
            o = i * 4
            for k in range(4):
                sm, u = splitmix32(sm)
                rng[o + k] = np.uint32(u)
            if (rng[o] | rng[o + 1] | rng[o + 2] | rng[o + 3]) == 0:
                rng[o] = 1
            ax[i] = np.float32(rnd01(xoshiro128pp(rng, o)) * fw)
            ay[i] = np.float32(rnd01(xoshiro128pp(rng, o)) * fh)
            adir[i] = np.uint16(xoshiro128pp(rng, o) % NDIR)

    # ---- the hot loops ---------------------------------------------------
    #
    # From here everything is float32 and stays float32. There is no `r()`
    # wrapper as in the pure version, because there is nothing to correct:
    # f32 op f32 is an f32 operation. The one thing that would silently break
    # it is a bare Python float literal -- `4.0` is a double and would promote
    # the whole expression -- so the constants are np.float32 and the four
    # that matter are named.

    F0 = np.float32(0.0)
    F4 = np.float32(4.0)
    F12 = np.float32(12.0)

    @jit
    def k_agents(grid, target, ax, ay, adir, rng, cos_t, sin_t, n,
                 xmask, ymask, log2w, fw, fh, sdist, step, deposit, ss, rs):
        for i in range(n):
            d = np.int64(adir[i])
            x = ax[i]
            y = ay[i]

            dl = (d - ss + NDIR) % NDIR
            dr = (d + ss) % NDIR

            sx = x + cos_t[dl] * sdist
            if sx < F0: sx = sx + fw
            if sx >= fw: sx = sx - fw
            sy = y + sin_t[dl] * sdist
            if sy < F0: sy = sy + fh
            if sy >= fh: sy = sy - fh
            fl = grid[((np.int64(sy) & ymask) << log2w) | (np.int64(sx) & xmask)]

            sx = x + cos_t[d] * sdist
            if sx < F0: sx = sx + fw
            if sx >= fw: sx = sx - fw
            sy = y + sin_t[d] * sdist
            if sy < F0: sy = sy + fh
            if sy >= fh: sy = sy - fh
            fc = grid[((np.int64(sy) & ymask) << log2w) | (np.int64(sx) & xmask)]

            sx = x + cos_t[dr] * sdist
            if sx < F0: sx = sx + fw
            if sx >= fw: sx = sx - fw
            sy = y + sin_t[dr] * sdist
            if sy < F0: sy = sy + fh
            if sy >= fh: sy = sy - fh
            fr = grid[((np.int64(sy) & ymask) << log2w) | (np.int64(sx) & xmask)]

            if fc >= fl and fc >= fr:
                pass
            elif fc < fl and fc < fr:
                if xoshiro128pp(rng, i * 4) & 1:
                    d = (d + rs) % NDIR
                else:
                    d = (d - rs + NDIR) % NDIR
            elif fl > fr:
                d = (d - rs + NDIR) % NDIR
            else:
                d = (d + rs) % NDIR

            x = x + cos_t[d] * step
            if x < F0: x = x + fw
            if x >= fw: x = x - fw
            y = y + sin_t[d] * step
            if y < F0: y = y + fh
            if y >= fh: y = y - fh

            idx = ((np.int64(y) & ymask) << log2w) | (np.int64(x) & xmask)
            target[idx] = target[idx] + deposit

            adir[i] = np.uint16(d)
            ax[i] = x
            ay[i] = y

    @jit
    def k_apply_dep(grid, dep):
        for i in range(grid.size):
            grid[i] = grid[i] + dep[i]
            dep[i] = F0

    @jit
    def k_diffuse(src, dst, w, h, log2w, xmask, ymask, decay):
        for y in range(h):
            rowm = ((y - 1) & ymask) << log2w
            row0 = y << log2w
            rowp = ((y + 1) & ymask) << log2w
            for x in range(w):
                xm = (x - 1) & xmask
                xp = (x + 1) & xmask
                acc = src[rowm | xm]
                acc = acc + src[rowm | x]
                acc = acc + src[rowm | xp]
                acc = acc + src[row0 | xm]
                acc = acc + F4 * src[row0 | x]
                acc = acc + src[row0 | xp]
                acc = acc + src[rowp | xm]
                acc = acc + src[rowp | x]
                acc = acc + src[rowp | xp]
                dst[row0 | x] = acc / F12 * decay

    # ---- checksums (SPEC-1 section 6) ------------------------------------

    @jit
    def k_hash_words(words):
        h = np.int64(FNV_OFFSET)
        for i in range(words.size):
            h = ((h ^ np.int64(words[i])) * FNV_PRIME) & MASK32
        return h

    @jit
    def k_hash_agents(bx, by, adir, n):
        h = np.int64(FNV_OFFSET)
        for i in range(n):
            h = ((h ^ np.int64(bx[i])) * FNV_PRIME) & MASK32
            h = ((h ^ np.int64(by[i])) * FNV_PRIME) & MASK32
            h = ((h ^ np.int64(adir[i])) * FNV_PRIME) & MASK32
        return h

    return (k_init_grid, k_init_agents, k_agents, k_apply_dep, k_diffuse,
            k_hash_words, k_hash_agents)


class Sim:
    def __init__(self, cfg: common.Config, kernels):
        common.check_pow2(cfg)
        common.normalize_f32(cfg)
        self.cfg = cfg
        (self._init_grid, self._init_agents, self._k_agents, self._k_apply_dep,
         self._k_diffuse, self._k_hash_words, self._k_hash_agents) = kernels

        self.log2w = cfg.width.bit_length() - 1
        self.xmask = cfg.width - 1
        self.ymask = cfg.height - 1

        cells = cfg.width * cfg.height
        self.grid = np.zeros(cells, np.float32)
        self.scratch = np.zeros(cells, np.float32)
        self.dep = np.zeros(cells, np.float32) if cfg.update == "deferred" else None

        self.ax = np.zeros(cfg.agents, np.float32)
        self.ay = np.zeros(cfg.agents, np.float32)
        self.adir = np.zeros(cfg.agents, np.uint16)
        self.arng = np.zeros(cfg.agents * 4, np.uint32)

        self.cos = np.array(COS, np.float32)
        self.sin = np.array(SIN, np.float32)

        self.ns_agents = 0
        self.ns_diffuse = 0

        self._init_grid(self.grid, cfg.seed)
        self._init_agents(self.ax, self.ay, self.adir, self.arng, cfg.seed,
                          cfg.agents, float(cfg.width), float(cfg.height))

    def tick(self) -> None:
        cfg = self.cfg
        t0 = time.perf_counter_ns()
        self._k_agents(
            self.grid, self.dep if self.dep is not None else self.grid,
            self.ax, self.ay, self.adir, self.arng, self.cos, self.sin,
            cfg.agents, self.xmask, self.ymask, self.log2w,
            np.float32(cfg.width), np.float32(cfg.height),
            np.float32(cfg.sensor_dist), np.float32(cfg.step),
            np.float32(cfg.deposit), cfg.sensor_steps, cfg.rot_steps)
        t1 = time.perf_counter_ns()

        if self.dep is not None:
            self._k_apply_dep(self.grid, self.dep)

        self._k_diffuse(self.grid, self.scratch, cfg.width, cfg.height,
                        self.log2w, self.xmask, self.ymask,
                        np.float32(cfg.decay))
        self.grid, self.scratch = self.scratch, self.grid
        t2 = time.perf_counter_ns()
        self.ns_agents += t1 - t0
        self.ns_diffuse += t2 - t1

    def hash_grid(self) -> int:
        return int(self._k_hash_words(self.grid.view(np.uint32)))

    def hash_agents(self) -> int:
        return int(self._k_hash_agents(self.ax.view(np.uint32),
                                       self.ay.view(np.uint32),
                                       self.adir, self.cfg.agents))


def dirtable_hash() -> int:
    h = FNV_OFFSET
    for w in list(COS_BITS) + list(SIN_BITS):
        h = ((h ^ w) * FNV_PRIME) & MASK32
    return h


def _precompile(kernels) -> float:
    """Compile every kernel against a 4x4 grid, and return the cost in ms.

    numba compiles on first call, so without this the first tick carries a
    one-off cost of roughly a second and the `ms_per_tick_p99` for a short run
    is a compiler benchmark. Running the real workload once as warmup would
    also work, but only if `--warmup` is set, and a benchmark whose numbers are
    silently wrong when a flag is omitted is the failure mode section 12 of
    docs/RESULTS.md is about.
    """
    t0 = time.perf_counter_ns()
    cfg = common.Config(width=4, height=4, agents=4, ticks=0, update="deferred")
    common.normalize_f32(cfg)
    s = Sim(cfg, kernels)
    s.tick()
    s.hash_grid()
    s.hash_agents()
    return (time.perf_counter_ns() - t0) / 1e6


def main() -> int:
    fastmath = "--fastmath" in sys.argv
    argv = [a for a in sys.argv[1:] if a != "--fastmath"]
    o = common.parse_args(argv)
    cfg = o.cfg

    kernels = _build(fastmath)
    compile_ms = _precompile(kernels)
    sys.stderr.write(f"jit_compile_ms {compile_ms:.1f} fastmath={int(fastmath)}\n")

    sim = Sim(cfg, kernels)
    for _ in range(cfg.warmup):
        sim.tick()
    sim.ns_agents = sim.ns_diffuse = 0

    tick_ms: list[float] = []
    t_start = time.perf_counter_ns()
    for t in range(cfg.ticks):
        a = time.perf_counter_ns()
        sim.tick()
        tick_ms.append((time.perf_counter_ns() - a) / 1e6)
        if cfg.hash_every and (t + 1) % cfg.hash_every == 0:
            sys.stderr.write(f"tick {t+1} grid=0x{sim.hash_grid():08X} "
                             f"agents=0x{sim.hash_agents():08X}\n")
    ms_total = (time.perf_counter_ns() - t_start) / 1e6

    if o.dump_grid:
        with open(o.dump_grid, "wb") as fh:
            fh.write(sim.grid.tobytes())

    variant = "numba-fastmath" if fastmath else "numba"
    if o.want_json:
        print(common.result_json(
            cfg, impl="python", backend="numba", cls="S", variant=variant,
            grid_hash=sim.hash_grid(), agent_hash=sim.hash_agents(),
            dirtable_hash=dirtable_hash(), ms_total=ms_total,
            ms_agents=sim.ns_agents / 1e6, ms_diffuse=sim.ns_diffuse / 1e6,
            tick_ms=tick_ms))
    else:
        common.print_human(cfg, variant, sim.hash_grid(), sim.hash_agents(),
                           ms_total, sim.ns_agents / 1e6, sim.ns_diffuse / 1e6,
                           cfg.ticks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
