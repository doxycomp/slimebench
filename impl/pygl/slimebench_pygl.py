#!/usr/bin/env python3
"""slimebench -- benchmark class G from a second language (SPEC-1 section 8.2).

This exists to test one claim the results have been making without evidence:
that class G measures the GPU and not the host language. The C host allocates
buffers, sets uniforms and issues three dispatches per tick; everything that
costs time happens on the device. If that is true, a Python host running the
*same shaders* on the *same driver* should land on the same numbers.

"The same shaders" is not asserted here, it is checked. `impl/glcompute` used
to embed its GLSL as C string literals; those now live in
`impl/glcompute/shaders/*.comp`, the C header is generated from them, and both
hosts report an FNV-32 of the source they actually compiled. If the two
`shader_hash` values differ, the comparison is void and the harness can see it.

## What is deliberately not shared

Everything above the shaders. This host does its own SPEC-1 3.3 initialisation
in numpy, builds its own buffers, and writes its own uniform-setting code --
about 200 lines against the C host's 480. If the two agree on the checksum,
that is also a second independent implementation of the initialisation, which
the CUDA target does not give (it shares nothing with the GL one either, but
it is a different kernel language, so a disagreement there is ambiguous).

## Why pygame for the context

A compute-only program still needs a GL 4.3 context. pygame is already a
dependency for the class R target and creates one in three lines; PyOpenGL
supplies the calls. Neither touches the tick.
"""

from __future__ import annotations

import ctypes
import os
import pathlib
import sys
import time

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
SHADERS = HERE.parent / "glcompute" / "shaders"
sys.path.insert(0, str(HERE.parent / "python"))

os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")

from slimebench import common  # noqa: E402
from slimebench.dirtable import COS_BITS, NDIR, SIN_BITS  # noqa: E402

FNV_OFFSET = 0x811C9DC5
FNV_PRIME = 0x01000193


def fnv32_bytes(data: bytes) -> int:
    h = FNV_OFFSET
    for b in data:
        h = ((h ^ b) * FNV_PRIME) & 0xFFFFFFFF
    return h


def fnv32_words(words: np.ndarray) -> int:
    h = FNV_OFFSET
    for w in words.tolist():
        h = ((h ^ w) * FNV_PRIME) & 0xFFFFFFFF
    return h


def load_shaders() -> tuple[dict[str, str], int]:
    """The three passes, and the hash the C host must agree with."""
    commonsrc = (SHADERS / "common.glsl").read_text(encoding="utf-8")
    parts = {n: (SHADERS / f"{n}.comp").read_text(encoding="utf-8")
             for n in ("agents", "merge", "diffuse")}
    blob = b"".join((commonsrc + parts[n]).encode("utf-8")
                    for n in ("agents", "merge", "diffuse"))
    return {n: commonsrc + parts[n] for n in parts}, fnv32_bytes(blob)


def split_groups(groups: int, maxx: int, maxy: int) -> tuple[int, int]:
    """2D work-group grid. A 1D dispatch tops out at GL_MAX_COMPUTE_WORK_GROUP_
    COUNT, which the spec puts at 65 535 -- exceeded by the diffusion pass from
    `medium` upwards, and silently, because the driver does not report it."""
    if groups == 0:
        return 1, 1
    if groups <= maxx:
        return groups, 1
    gy = (groups + maxx - 1) // maxx
    if gy > maxy:
        raise RuntimeError(
            f"preset needs {groups} work groups, driver allows {maxx} x {maxy}")
    return maxx, gy


def main() -> int:
    o = common.parse_args()
    cfg = o.cfg
    if cfg.update != "deferred":
        sys.stderr.write(
            "error: class G implements --update deferred only.\n"
            "       SPEC-1 'serial' makes an agent's deposit visible to the next\n"
            "       agent in the same tick, which no parallel dispatch expresses;\n"
            "       see SPEC-1 section 5.5.\n")
        return 3

    import pygame
    from OpenGL import GL

    pygame.init()
    # 4.3 core, explicitly: pygame's default is a compatibility context that
    # can come back as GL 2.1 on llvmpipe, and then glDispatchCompute simply
    # does not resolve.
    pygame.display.gl_set_attribute(pygame.GL_CONTEXT_MAJOR_VERSION, 4)
    pygame.display.gl_set_attribute(pygame.GL_CONTEXT_MINOR_VERSION, 3)
    pygame.display.gl_set_attribute(pygame.GL_CONTEXT_PROFILE_MASK,
                                    pygame.GL_CONTEXT_PROFILE_CORE)
    pygame.display.set_mode((64, 64), pygame.OPENGL | pygame.DOUBLEBUF | pygame.HIDDEN)
    renderer = GL.glGetString(GL.GL_RENDERER).decode()
    version = GL.glGetString(GL.GL_VERSION).decode()

    # PyOpenGL's convenience namespace does not resolve the 4.3 compute entry
    # points even in a 4.5 core context -- `OpenGL.GL.glDispatchCompute` is a
    # null function while the raw version module's is live. Import them from
    # there rather than pretending the context is at fault.
    from OpenGL.raw.GL.VERSION.GL_4_3 import (
        GL_COMPUTE_SHADER, GL_MAX_COMPUTE_WORK_GROUP_COUNT,
        GL_SHADER_STORAGE_BUFFER, glDispatchCompute,
    )
    from OpenGL.raw.GL.VERSION.GL_4_2 import GL_ALL_BARRIER_BITS, glMemoryBarrier

    if not bool(glDispatchCompute):
        sys.stderr.write(
            f"error: no compute shaders in this context ({version})\n")
        return 1

    srcs, shader_hash = load_shaders()

    def compile_pass(name: str) -> int:
        sh = GL.glCreateShader(GL_COMPUTE_SHADER)
        GL.glShaderSource(sh, srcs[name])
        GL.glCompileShader(sh)
        if not GL.glGetShaderiv(sh, GL.GL_COMPILE_STATUS):
            sys.stderr.write(f"error: {name} shader:\n"
                             f"{GL.glGetShaderInfoLog(sh).decode()}\n")
            sys.exit(1)
        pr = GL.glCreateProgram()
        GL.glAttachShader(pr, sh)
        GL.glLinkProgram(pr)
        if not GL.glGetProgramiv(pr, GL.GL_LINK_STATUS):
            sys.stderr.write(f"error: {name} link:\n"
                             f"{GL.glGetProgramInfoLog(pr).decode()}\n")
            sys.exit(1)
        GL.glDeleteShader(sh)
        return pr

    programs = {n: compile_pass(n) for n in ("agents", "merge", "diffuse")}

    # ---- host-side state (SPEC-1 3.3) -----------------------------------
    cells = cfg.width * cfg.height
    n_agents = cfg.agents

    grid = np.empty(cells, dtype=np.float32)
    sm = cfg.seed ^ 0x5BF03635
    mask = 0xFFFFFFFF
    tmp = np.empty(cells, dtype=np.uint32)
    for i in range(cells):
        sm = (sm + 0x9E3779B9) & mask
        z = sm
        z = ((z ^ (z >> 16)) * 0x21F0AAAD) & mask
        z = ((z ^ (z >> 15)) * 0x735A2D97) & mask
        tmp[i] = z ^ (z >> 15)
    grid[:] = (tmp >> np.uint32(8)).astype(np.float32) / np.float32(16777216.0)
    grid *= np.float32(100.0)

    idx = np.arange(1, n_agents + 1, dtype=np.uint32)
    state = (np.uint32(cfg.seed) + np.uint32(0x9E3779B9) * idx).astype(np.uint32)
    arng = np.empty((n_agents, 4), dtype=np.uint32)
    for k in range(4):
        state += np.uint32(0x9E3779B9)
        z = state.copy()
        z ^= z >> np.uint32(16); z *= np.uint32(0x21F0AAAD)
        z ^= z >> np.uint32(15); z *= np.uint32(0x735A2D97)
        arng[:, k] = z ^ (z >> np.uint32(15))
    allzero = (arng[:, 0] | arng[:, 1] | arng[:, 2] | arng[:, 3]) == 0
    arng[allzero, 0] = 1

    def xoshiro(s):
        res = (np.left_shift(s[:, 0] + s[:, 3], 7) |
               np.right_shift(s[:, 0] + s[:, 3], 25)).astype(np.uint32) + s[:, 0]
        t = np.left_shift(s[:, 1], 9).astype(np.uint32)
        s[:, 2] ^= s[:, 0]; s[:, 3] ^= s[:, 1]
        s[:, 1] ^= s[:, 2]; s[:, 0] ^= s[:, 3]
        s[:, 2] ^= t
        s[:, 3] = (np.left_shift(s[:, 3], 11) | np.right_shift(s[:, 3], 21)).astype(np.uint32)
        return res.astype(np.uint32)

    inv = np.float32(1.0) / np.float32(16777216.0)
    ax = ((xoshiro(arng) >> np.uint32(8)).astype(np.float32) * inv) * np.float32(cfg.width)
    ay = ((xoshiro(arng) >> np.uint32(8)).astype(np.float32) * inv) * np.float32(cfg.height)
    adir = (xoshiro(arng) % np.uint32(NDIR)).astype(np.uint32)

    cos_t = np.frombuffer(np.array(COS_BITS, dtype=np.uint32).tobytes(), dtype=np.float32)
    sin_t = np.frombuffer(np.array(SIN_BITS, dtype=np.uint32).tobytes(), dtype=np.float32)

    # ---- buffers ---------------------------------------------------------
    arrays = [grid, np.zeros(cells, np.float32), np.zeros(cells, np.uint32),
              ax, ay, adir, arng.reshape(-1), cos_t, sin_t]
    bufs = GL.glGenBuffers(len(arrays))
    for i, a in enumerate(arrays):
        GL.glBindBuffer(GL_SHADER_STORAGE_BUFFER, bufs[i])
        GL.glBufferData(GL_SHADER_STORAGE_BUFFER, a.nbytes, a, GL.GL_DYNAMIC_COPY)
        GL.glBindBufferBase(GL_SHADER_STORAGE_BUFFER, i, bufs[i])

    log2w = cfg.width.bit_length() - 1
    uniforms = {
        "uWidth": ("u", cfg.width), "uHeight": ("u", cfg.height),
        "uLog2w": ("u", log2w), "uXmask": ("u", cfg.width - 1),
        "uYmask": ("u", cfg.height - 1), "uAgents": ("u", n_agents),
        "uCells": ("u", cells),
        "uSs": ("i", cfg.sensor_steps), "uRs": ("i", cfg.rot_steps),
        "uNdir": ("i", NDIR),
        "uSensorDist": ("f", cfg.sensor_dist), "uStep": ("f", cfg.step),
        "uDeposit": ("f", cfg.deposit), "uDecay": ("f", cfg.decay),
    }
    for pr in programs.values():
        GL.glUseProgram(pr)
        for name, (kind, val) in uniforms.items():
            loc = GL.glGetUniformLocation(pr, name)
            if loc < 0:
                continue
            if kind == "u":
                GL.glUniform1ui(loc, int(val))
            elif kind == "i":
                GL.glUniform1i(loc, int(val))
            else:
                GL.glUniform1f(loc, float(val))

    maxx = GL.glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 0)[0]
    maxy = GL.glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 1)[0]
    ag_gx, ag_gy = split_groups((n_agents + 63) // 64, maxx, maxy)
    cl_gx, cl_gy = split_groups((cells + 63) // 64, maxx, maxy)

    live = 0

    def tick():
        nonlocal live
        other = 1 - live
        GL.glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, bufs[live])
        GL.glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, bufs[other])
        GL.glUseProgram(programs["agents"])
        glDispatchCompute(ag_gx, ag_gy, 1)
        glMemoryBarrier(GL_ALL_BARRIER_BITS)
        GL.glUseProgram(programs["merge"])
        glDispatchCompute(cl_gx, cl_gy, 1)
        glMemoryBarrier(GL_ALL_BARRIER_BITS)
        GL.glUseProgram(programs["diffuse"])
        glDispatchCompute(cl_gx, cl_gy, 1)
        glMemoryBarrier(GL_ALL_BARRIER_BITS)
        live = other

    for _ in range(cfg.warmup):
        tick()
    GL.glFinish()

    tick_ms: list[float] = []
    t0 = time.perf_counter_ns()
    for _ in range(cfg.ticks):
        a = time.perf_counter_ns()
        tick()
        GL.glFinish()
        tick_ms.append((time.perf_counter_ns() - a) / 1e6)
    ms_total = (time.perf_counter_ns() - t0) / 1e6

    # ---- read back and hash ---------------------------------------------
    def read(i, dtype, count):
        GL.glBindBuffer(GL_SHADER_STORAGE_BUFFER, bufs[i])
        raw = GL.glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
                                    count * np.dtype(dtype).itemsize)
        return np.frombuffer(bytes(raw), dtype=dtype, count=count)

    out_grid = read(live, np.uint32, cells)
    out_ax = read(3, np.uint32, n_agents)
    out_ay = read(4, np.uint32, n_agents)
    out_ad = read(5, np.uint32, n_agents)

    grid_hash = fnv32_words(out_grid)
    inter = np.empty(n_agents * 3, dtype=np.uint32)
    inter[0::3] = out_ax
    inter[1::3] = out_ay
    inter[2::3] = out_ad
    agent_hash = fnv32_words(inter)
    dirtable_hash = fnv32_words(np.array(list(COS_BITS) + list(SIN_BITS), dtype=np.uint32))

    pygame.quit()

    n = len(tick_ms)
    srt = sorted(tick_ms)
    median = srt[n // 2] if n else 0.0
    p99 = srt[min(n - 1, int(n * 0.99))] if n else 0.0
    mean = sum(tick_ms) / n if n else 0.0

    if o.want_json:
        import json
        print(json.dumps({
            "schema": 1, "impl": "pygl", "backend": "gl43", "class": "G",
            "preset": cfg.preset, "variant": renderer,
            "width": cfg.width, "height": cfg.height, "agents": n_agents,
            "ticks": n, "seed": cfg.seed, "update": "deferred", "threads": 1,
            "grid_hash": f"0x{grid_hash:08X}",
            "agent_hash": f"0x{agent_hash:08X}",
            "dirtable_hash": f"0x{dirtable_hash:08X}",
            "shader_hash": f"0x{shader_hash:08X}",
            "ms_total": round(ms_total, 4), "ms_agents": 0.0, "ms_diffuse": 0.0,
            "ms_per_tick_mean": round(mean, 6),
            "ms_per_tick_median": round(median, 6),
            "ms_per_tick_p99": round(p99, 6),
            "maups": round(n_agents * n / ms_total / 1000, 4) if ms_total else 0.0,
            "mcups": round(cells * n / ms_total / 1000, 4) if ms_total else 0.0,
        }))
    else:
        print(f"{cfg.preset} {cfg.width}x{cfg.height} agents={n_agents} "
              f"ticks={cfg.ticks} update=deferred")
        print(f"  renderer    {renderer}")
        print(f"  grid_hash   0x{grid_hash:08X}")
        print(f"  agent_hash  0x{agent_hash:08X}")
        print(f"  shader_hash 0x{shader_hash:08X}")
        print(f"  total       {ms_total:.2f} ms  "
              f"({ms_total / max(1, cfg.ticks):.4f} ms/tick)")
    return 0


_ = ctypes  # PyOpenGL wants it loaded before the first GL call on some setups

if __name__ == "__main__":
    sys.exit(main())
