#!/usr/bin/env python3
"""slimebench -- pure-Python implementation of SPEC-1 (conformance tier B).

No numpy, no tricks: the point of this target is to establish the honest
interpreted baseline. Expect roughly two to three orders of magnitude slower
than C, and use --preset tiny with few ticks.

Why tier B by default: the grid is an `array('f')`, so every *store* rounds to
f32 as the spec requires, but Python's arithmetic between the loads is f64.

`--strict-f32` rounds every intermediate through a struct.pack round-trip and
is genuinely conformance tier A -- verified bit-identical to the C reference.
Measured cost of that exactness: 21.9 vs 9.4 ms/tick at 128x128 with 4096
agents, i.e. 2.3x. Cheaper than expected, which is itself the interesting
result: in a language this slow, nine extra C-level calls per cell disappear
into the interpreter overhead that was already there.
"""

from __future__ import annotations

import struct
import sys
import time
from array import array

sys.path.insert(0, __file__.rsplit("/", 1)[0])

from slimebench import common
from slimebench.dirtable import COS, NDIR, SIN, COS_BITS, SIN_BITS

FNV_OFFSET = 0x811C9DC5
FNV_PRIME = 0x01000193
MASK32 = 0xFFFFFFFF

_pack_f = struct.Struct("<f").pack
_unpack_f = struct.Struct("<f").unpack


def f32(x: float) -> float:
    """Round a Python float to the nearest f32. Only used with --strict-f32."""
    return _unpack_f(_pack_f(x))[0]


# ---- PRNG (SPEC-1 section 3.1) ------------------------------------------


def splitmix32(state: int) -> tuple[int, int]:
    state = (state + 0x9E3779B9) & MASK32
    z = state
    z = ((z ^ (z >> 16)) * 0x21F0AAAD) & MASK32
    z = ((z ^ (z >> 15)) * 0x735A2D97) & MASK32
    return state, z ^ (z >> 15)


def xoshiro128pp(s: list[int], o: int) -> int:
    s0, s1, s2, s3 = s[o], s[o + 1], s[o + 2], s[o + 3]
    t0 = (s0 + s3) & MASK32
    result = ((((t0 << 7) | (t0 >> 25)) & MASK32) + s0) & MASK32
    t = (s1 << 9) & MASK32
    s2 ^= s0
    s3 ^= s1
    s1 ^= s2
    s0 ^= s3
    s2 ^= t
    s3 = ((s3 << 11) | (s3 >> 21)) & MASK32
    s[o], s[o + 1], s[o + 2], s[o + 3] = s0, s1, s2, s3
    return result


def rnd01(u: int) -> float:
    return (u >> 8) / 16777216.0


def _as_u32(a: array) -> array:
    """Reinterpret an array('f') as u32 words.

    memoryview.cast() refuses format-to-format casts, so round-trip through
    bytes. Only used by the checksums, never in the hot loop.
    """
    out = array("I")
    out.frombytes(a.tobytes())
    return out


class Sim:
    def __init__(self, cfg: common.Config, strict: bool = False):
        common.check_pow2(cfg)
        common.normalize_f32(cfg)
        self.cfg = cfg
        self.strict = strict
        self.log2w = cfg.width.bit_length() - 1
        self.xmask = cfg.width - 1
        self.ymask = cfg.height - 1

        cells = cfg.width * cfg.height
        self.grid = array("f", bytes(cells * 4))
        self.scratch = array("f", bytes(cells * 4))
        self.dep = array("f", bytes(cells * 4)) if cfg.update == "deferred" else None

        self.ax = array("f", bytes(cfg.agents * 4))
        self.ay = array("f", bytes(cfg.agents * 4))
        self.adir = array("H", bytes(cfg.agents * 2))
        self.arng = array("I", bytes(cfg.agents * 16))

        self.ns_agents = 0
        self.ns_diffuse = 0
        self._init_state()

    def _init_state(self) -> None:
        cfg = self.cfg
        sm = cfg.seed ^ 0x5BF03635
        grid = self.grid
        for i in range(len(grid)):
            sm, u = splitmix32(sm)
            grid[i] = rnd01(u) * 100.0

        fw = float(cfg.width)
        fh = float(cfg.height)
        rng = self.arng
        for i in range(cfg.agents):
            sm_a = (cfg.seed + 0x9E3779B9 * (i + 1)) & MASK32
            o = i * 4
            for k in range(4):
                sm_a, u = splitmix32(sm_a)
                rng[o + k] = u
            if rng[o] | rng[o + 1] | rng[o + 2] | rng[o + 3] == 0:
                rng[o] = 1
            self.ax[i] = rnd01(xoshiro128pp(rng, o)) * fw
            self.ay[i] = rnd01(xoshiro128pp(rng, o)) * fh
            self.adir[i] = xoshiro128pp(rng, o) % NDIR

    def tick(self) -> None:
        t0 = time.perf_counter_ns()
        self._agent_pass()
        t1 = time.perf_counter_ns()

        if self.dep is not None:
            grid, dep = self.grid, self.dep
            for i in range(len(grid)):
                grid[i] = grid[i] + dep[i]
                dep[i] = 0.0

        self._diffuse_pass()
        t2 = time.perf_counter_ns()
        self.ns_agents += t1 - t0
        self.ns_diffuse += t2 - t1

    def _agent_pass(self) -> None:
        cfg = self.cfg
        grid = self.grid
        target = self.dep if self.dep is not None else self.grid
        ax, ay, adir, rng = self.ax, self.ay, self.adir, self.arng
        xmask, ymask, log2w = self.xmask, self.ymask, self.log2w
        fw, fh = float(cfg.width), float(cfg.height)
        sdist, step, deposit = cfg.sensor_dist, cfg.step, cfg.deposit
        ss, rs = cfg.sensor_steps, cfg.rot_steps
        cos_t, sin_t = COS, SIN
        r = f32 if self.strict else (lambda v: v)

        for i in range(cfg.agents):
            d = adir[i]
            x = ax[i]
            y = ay[i]

            dl = (d - ss + NDIR) % NDIR
            dr = (d + ss) % NDIR

            sx = r(x + r(cos_t[dl] * sdist))
            if sx < 0.0: sx = r(sx + fw)
            if sx >= fw: sx = r(sx - fw)
            sy = r(y + r(sin_t[dl] * sdist))
            if sy < 0.0: sy = r(sy + fh)
            if sy >= fh: sy = r(sy - fh)
            fl = grid[((int(sy) & ymask) << log2w) | (int(sx) & xmask)]

            sx = r(x + r(cos_t[d] * sdist))
            if sx < 0.0: sx = r(sx + fw)
            if sx >= fw: sx = r(sx - fw)
            sy = r(y + r(sin_t[d] * sdist))
            if sy < 0.0: sy = r(sy + fh)
            if sy >= fh: sy = r(sy - fh)
            fc = grid[((int(sy) & ymask) << log2w) | (int(sx) & xmask)]

            sx = r(x + r(cos_t[dr] * sdist))
            if sx < 0.0: sx = r(sx + fw)
            if sx >= fw: sx = r(sx - fw)
            sy = r(y + r(sin_t[dr] * sdist))
            if sy < 0.0: sy = r(sy + fh)
            if sy >= fh: sy = r(sy - fh)
            fr = grid[((int(sy) & ymask) << log2w) | (int(sx) & xmask)]

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

            x = r(x + r(cos_t[d] * step))
            if x < 0.0: x = r(x + fw)
            if x >= fw: x = r(x - fw)
            y = r(y + r(sin_t[d] * step))
            if y < 0.0: y = r(y + fh)
            if y >= fh: y = r(y - fh)

            idx = ((int(y) & ymask) << log2w) | (int(x) & xmask)
            target[idx] = r(target[idx] + deposit)

            adir[i] = d
            ax[i] = x
            ay[i] = y

    def _diffuse_pass(self) -> None:
        cfg = self.cfg
        w, h = cfg.width, cfg.height
        log2w, xmask, ymask = self.log2w, self.xmask, self.ymask
        decay = cfg.decay
        src, dst = self.grid, self.scratch
        r = f32 if self.strict else (lambda v: v)

        for y in range(h):
            rowm = ((y - 1) & ymask) << log2w
            row0 = y << log2w
            rowp = ((y + 1) & ymask) << log2w
            for x in range(w):
                xm = (x - 1) & xmask
                xp = (x + 1) & xmask
                acc = src[rowm | xm]
                acc = r(acc + src[rowm | x])
                acc = r(acc + src[rowm | xp])
                acc = r(acc + src[row0 | xm])
                acc = r(acc + r(4.0 * src[row0 | x]))
                acc = r(acc + src[row0 | xp])
                acc = r(acc + src[rowp | xm])
                acc = r(acc + src[rowp | x])
                acc = r(acc + src[rowp | xp])
                dst[row0 | x] = r(r(acc / 12.0) * decay)

        self.grid, self.scratch = dst, src

    # ---- checksums (SPEC-1 section 6) -----------------------------------

    def hash_grid(self) -> int:
        h = FNV_OFFSET
        for w in _as_u32(self.grid):
            h = ((h ^ w) * FNV_PRIME) & MASK32
        return h

    def hash_agents(self) -> int:
        h = FNV_OFFSET
        bx = _as_u32(self.ax)
        by = _as_u32(self.ay)
        adir = self.adir
        for i in range(self.cfg.agents):
            h = ((h ^ bx[i]) * FNV_PRIME) & MASK32
            h = ((h ^ by[i]) * FNV_PRIME) & MASK32
            h = ((h ^ adir[i]) * FNV_PRIME) & MASK32
        return h


def dirtable_hash() -> int:
    h = FNV_OFFSET
    for w in list(COS_BITS) + list(SIN_BITS):
        h = ((h ^ w) * FNV_PRIME) & MASK32
    return h


def main() -> int:
    strict = "--strict-f32" in sys.argv
    argv = [a for a in sys.argv[1:] if a != "--strict-f32"]
    o = common.parse_args(argv)
    cfg = o.cfg

    sim = Sim(cfg, strict=strict)
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

    variant = "pure-strict" if strict else "pure"
    if o.want_json:
        print(common.result_json(
            cfg, impl="python", backend="pure", cls="S", variant=variant,
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
