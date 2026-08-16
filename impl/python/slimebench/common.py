"""Shared CLI parsing and result reporting for the Python targets (SPEC-1 §10)."""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, field

SPEC_VERSION = "SPEC-1"

PRESETS = {
    "tiny": (512, 512, 65_536, 1000),
    "small": (1024, 1024, 262_144, 1000),
    "medium": (2048, 2048, 1_048_576, 1000),
    "large": (4096, 4096, 4_194_304, 500),
    "browser": (1024, 1024, 262_144, 0),
}


@dataclass
class Config:
    width: int = 1024
    height: int = 1024
    agents: int = 262_144
    ticks: int = 1000
    warmup: int = 0
    seed: int = 12345
    threads: int = 1
    update: str = "serial"
    sensor_dist: float = 9.0
    step: float = 1.0
    deposit: float = 10.0
    decay: float = 0.94
    sensor_steps: int = 144
    rot_steps: int = 144
    hash_every: int = 0
    preset: str = "custom"


@dataclass
class Opts:
    cfg: Config = field(default_factory=Config)
    want_render: bool = False
    want_json: bool = False
    freeze_sim: bool = False
    dump_grid: str | None = None
    display_max: float = 100.0


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        # SPEC-1 section 10: unknown/invalid arguments exit 2, never ignored.
        sys.stderr.write(f"error: {message}\n")
        self.print_usage(sys.stderr)
        sys.exit(2)


def parse_args(argv: list[str] | None = None) -> Opts:
    p = _Parser(prog="slimebench-python", description=f"slimebench {SPEC_VERSION}")
    p.add_argument("--preset", choices=sorted(PRESETS))
    p.add_argument("--width", type=int)
    p.add_argument("--height", type=int)
    p.add_argument("--agents", type=int)
    p.add_argument("--ticks", type=int)
    p.add_argument("--warmup", type=int)
    p.add_argument("--seed", type=int)
    p.add_argument("--threads", type=int)
    p.add_argument("--update", choices=["serial", "deferred"])
    p.add_argument("--sensor-dist", type=float)
    p.add_argument("--sensor-steps", type=int)
    p.add_argument("--rot-steps", type=int)
    p.add_argument("--step", type=float)
    p.add_argument("--deposit", type=float)
    p.add_argument("--decay", type=float)
    p.add_argument("--hash-every", type=int)
    p.add_argument("--dump-grid")
    p.add_argument("--display-max", type=float, default=100.0)
    p.add_argument("--headless", action="store_true")
    p.add_argument("--render", action="store_true")
    p.add_argument("--freeze-sim", action="store_true")
    p.add_argument("--json", action="store_true")

    a = p.parse_args(argv)
    o = Opts()
    c = o.cfg

    if a.preset:
        c.width, c.height, c.agents, c.ticks = PRESETS[a.preset]
        c.preset = a.preset
    for name in ("width", "height", "agents"):
        if getattr(a, name) is not None:
            setattr(c, name, getattr(a, name))
            c.preset = "custom"
    for name in ("ticks", "warmup", "seed", "threads", "update", "sensor_dist",
                 "sensor_steps", "rot_steps", "step", "deposit", "decay", "hash_every"):
        v = getattr(a, name)
        if v is not None:
            setattr(c, name, v)

    o.want_render = a.render
    o.want_json = a.json
    o.freeze_sim = a.freeze_sim
    o.dump_grid = a.dump_grid
    o.display_max = a.display_max
    return o


def normalize_f32(c: Config) -> Config:
    """Round every f32 parameter to f32.

    A Python float literal is f64: `0.94` and C's `0.94f` are different
    numbers, and multiplying the whole grid by the wrong one every tick drifts
    the implementations apart. 9.0, 1.0 and 10.0 are exact in f32, so `decay`
    is the one that actually bites -- the same trap the TypeScript port hit.
    """
    import struct
    r = lambda v: struct.unpack("<f", struct.pack("<f", v))[0]  # noqa: E731
    c.sensor_dist = r(c.sensor_dist)
    c.step = r(c.step)
    c.deposit = r(c.deposit)
    c.decay = r(c.decay)
    return c


def check_pow2(c: Config) -> None:
    for name in ("width", "height"):
        v = getattr(c, name)
        if v <= 0 or (v & (v - 1)) != 0:
            sys.exit(f"error: {name} must be a power of two")


def result_json(cfg: Config, *, impl: str, backend: str, cls: str, variant: str,
                grid_hash: int, agent_hash: int, dirtable_hash: int,
                ms_total: float, ms_agents: float, ms_diffuse: float,
                tick_ms: list[float]) -> str:
    n = len(tick_ms)
    srt = sorted(tick_ms)
    median = srt[n // 2] if n else 0.0
    p99 = srt[min(n - 1, int(n * 0.99))] if n else 0.0
    mean = math.fsum(tick_ms) / n if n else 0.0
    cells = cfg.width * cfg.height

    return json.dumps({
        "schema": 1,
        "impl": impl, "backend": backend, "class": cls, "preset": cfg.preset,
        "variant": variant,
        "width": cfg.width, "height": cfg.height, "agents": cfg.agents,
        "ticks": n, "seed": cfg.seed, "update": cfg.update, "threads": cfg.threads,
        "grid_hash": f"0x{grid_hash:08X}",
        "agent_hash": f"0x{agent_hash:08X}",
        "dirtable_hash": f"0x{dirtable_hash:08X}",
        "ms_total": round(ms_total, 4),
        "ms_agents": round(ms_agents, 4),
        "ms_diffuse": round(ms_diffuse, 4),
        "ms_per_tick_mean": round(mean, 6),
        "ms_per_tick_median": round(median, 6),
        "ms_per_tick_p99": round(p99, 6),
        "maups": round(cfg.agents * n / ms_total / 1000.0, 4) if ms_total > 0 else 0.0,
        "mcups": round(cells * n / ms_total / 1000.0, 4) if ms_total > 0 else 0.0,
    })


def print_human(cfg: Config, variant: str, grid_hash: int, agent_hash: int,
                ms_total: float, ms_agents: float, ms_diffuse: float, ticks: int) -> None:
    print(f"{cfg.preset} {cfg.width}x{cfg.height} agents={cfg.agents} "
          f"ticks={ticks} update={cfg.update} variant={variant}")
    print(f"  grid_hash  0x{grid_hash:08X}")
    print(f"  agent_hash 0x{agent_hash:08X}")
    print(f"  total      {ms_total:.2f} ms  ({ms_total / max(1, ticks):.4f} ms/tick)")
    print(f"  agents     {ms_agents:.2f} ms")
    print(f"  diffuse    {ms_diffuse:.2f} ms")
