#!/usr/bin/env python3
"""slimebench -- Python + raylib frontend (benchmark class R).

raylib-python-cffi (`pyray`/`raylib`), which is a cffi binding straight onto
the same libraylib the C frontend links. As there, the texture is
`UNCOMPRESSED_GRAYSCALE` and takes the 8-bit buffer directly -- no expansion
loop, which is the whole reason raylib beat SDL2 in the C measurement.

The interesting question this target answers is what the cffi call overhead
costs per frame, since the work behind each call is identical to C's.
"""

from __future__ import annotations

import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from raylib import ffi, rl  # noqa: E402

from slimebench import common  # noqa: E402
from slimebench import hud as sbhud  # noqa: E402
from slimebench.render import RenderStats  # noqa: E402
import slimebench_numpy as sbn  # noqa: E402

LOG_WARNING = 4
PIXELFORMAT_UNCOMPRESSED_GRAYSCALE = 1


def main() -> int:
    o = common.parse_args()
    cfg = o.cfg
    frames = cfg.ticks if cfg.ticks else 100_000

    # Class R measures the upload path, and --freeze-sim means no tick ever
    # runs -- so the update mode is irrelevant here. Default it to `deferred`
    # rather than have the numpy core refuse `serial` for a simulation that
    # will not step.
    if o.freeze_sim:
        cfg.update = "deferred"

    sim = sbn.Sim(cfg)

    rl.SetTraceLogLevel(LOG_WARNING)
    rl.InitWindow(cfg.width, cfg.height, b"slimebench -- Python / raylib")

    cells = cfg.width * cfg.height
    # One C-side buffer, reused: the texture upload reads from this pointer
    # every frame, so it has to outlive the loop body.
    cbuf = ffi.new("unsigned char[]", cells)
    view = np.frombuffer(ffi.buffer(cbuf, cells), dtype=np.uint8)

    img = ffi.new("Image *")
    img.data = cbuf
    img.width = cfg.width
    img.height = cfg.height
    img.mipmaps = 1
    img.format = PIXELFORMAT_UNCOMPRESSED_GRAYSCALE
    tex = rl.LoadTextureFromImage(img[0])

    black = ffi.new("Color *", [0, 0, 0, 255])[0]
    white = ffi.new("Color *", [255, 255, 255, 255])[0]
    display_max = float(o.display_max)
    scale = np.float32(255.0 / display_max)

    h = sbhud.Hud(label="Python / raylib", show_hud=not o.want_json)
    hv = sbhud.HudView(
        width=cfg.width, height=cfg.height, agents=cfg.agents,
        threads=getattr(cfg, "threads", 1) or 1,
        rot_steps=cfg.rot_steps, deposit=cfg.deposit, decay=cfg.decay,
        sensor_dist=cfg.sensor_dist, step=cfg.step,
        deferred=(cfg.update == "deferred"))
    # raylib's key codes are ASCII for the printable keys, which is why this
    # map is shorter than pygame's.
    keymap = {
        256: "quit", ord("Q"): "quit", ord(" "): "pause", ord("N"): "step",
        ord("R"): "reset", 258: "hud", ord("H"): "help", 290: "help",
        ord("C"): "hash", ord("F"): "freeze",
        ord("1"): "deposit-", ord("2"): "deposit+",
        ord("3"): "decay-", ord("4"): "decay+",
        ord("5"): "sensor-", ord("6"): "sensor+",
        ord("7"): "step-", ord("8"): "step+",
        ord("9"): "rot-", ord("0"): "rot+",
        ord("-"): "bright-", ord("="): "bright+",
    }
    # A two-dimensional view of the same C buffer, for the overlay to draw in.
    grid2d = view.reshape(cfg.height, cfg.width)

    stats = RenderStats()
    for _ in range(frames):
        if rl.WindowShouldClose():
            break
        for key, action in keymap.items():
            if not rl.IsKeyPressed(key):
                continue
            before = display_max
            display_max = sbhud.act(h, hv, action, display_max)
            if display_max != before:
                scale = np.float32(255.0 / display_max)
            cfg.deposit, cfg.decay = hv.deposit, hv.decay
            cfg.sensor_dist, cfg.step = hv.sensor_dist, hv.step
            cfg.rot_steps = hv.rot_steps
        if h.want_quit:
            break
        if h.want_reset:
            sim = sbn.Sim(cfg)
            h.tick = 0
            h.want_reset = False
        if h.want_hash:
            print(f"grid {sim.hash_grid()}  agents {sim.hash_agents()}"
                  f"  tick {h.tick}"
                  f"{'  EDITED' if h.edited else ''}", file=sys.stderr)
            h.want_hash = False

        s0 = time.perf_counter_ns()
        if not o.freeze_sim and not h.frozen and (not h.paused or h.step_once):
            sim.tick()
            h.tick += 1
            h.step_once = False
        sim_ns = time.perf_counter_ns() - s0

        r0 = time.perf_counter_ns()
        # Straight into the C buffer the texture reads from -- no Python-side
        # copy of the frame.
        view[:] = np.clip(sim.grid * scale, 0, 255)
        sbhud.draw(grid2d, h, hv, display_max)
        h.smooth(sim_ns / 1e6, stats.recent_mean(1))
        rl.UpdateTexture(tex, cbuf)

        rl.BeginDrawing()
        rl.ClearBackground(black)
        rl.DrawTexture(tex, 0, 0, white)
        rl.EndDrawing()
        stats.add(time.perf_counter_ns() - r0)

        if stats.since_title >= 60:
            ms = stats.recent_mean(60)
            rl.SetWindowTitle(
                f"slimebench -- Python / raylib -- {ms:.2f} ms/frame "
                f"({1000.0 / ms if ms > 0 else 0:.0f} fps)".encode())
            stats.since_title = 0

    rl.UnloadTexture(tex)
    rl.CloseWindow()

    if o.want_json:
        j = stats.json(cfg, "raylib")
        if j:
            print(j)
    return 0


if __name__ == "__main__":
    sys.exit(main())
