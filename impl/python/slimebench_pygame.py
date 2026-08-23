#!/usr/bin/env python3
"""slimebench -- Python + pygame frontend (benchmark class R).

pygame stands in for SDL2 here, because it *is* SDL2: pygame 2 is a wrapper
over SDL2, so this measures the same upload path as `impl/c/main_sdl2.c` with
a Python layer on top. That layer is the interesting part -- the simulation is
frozen, so what is left in the frame is exactly the cost of getting a
1024x1024 greyscale buffer onto the screen through this binding.

The greyscale expansion goes through numpy rather than a Python loop. Writing
it as a loop would measure the interpreter, not the backend, and every other
port in this class expands the buffer with a tight native loop -- so numpy is
the honest equivalent, not a shortcut.
"""

from __future__ import annotations

import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Keep pygame's banner off stdout; the harness parses the JSON from there.
os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")

import pygame  # noqa: E402

from slimebench import common  # noqa: E402
from slimebench import hud as sbhud  # noqa: E402
from slimebench.render import RenderStats  # noqa: E402
import slimebench_numpy as sbn  # noqa: E402


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

    pygame.init()
    screen = pygame.display.set_mode((cfg.width, cfg.height))
    pygame.display.set_caption("slimebench -- Python / pygame")

    # The overlay, off whenever --json is in play: a window that is being
    # measured must not spend its frame time drawing text about itself.
    display_max = float(o.display_max)
    h = sbhud.Hud(label="Python / pygame", show_hud=not o.want_json)
    view = sbhud.HudView(
        width=cfg.width, height=cfg.height, agents=cfg.agents,
        threads=getattr(cfg, "threads", 1) or 1,
        rot_steps=cfg.rot_steps, deposit=cfg.deposit, decay=cfg.decay,
        sensor_dist=cfg.sensor_dist, step=cfg.step,
        deferred=(cfg.update == "deferred"))
    keymap = {
        pygame.K_ESCAPE: "quit", pygame.K_q: "quit",
        pygame.K_SPACE: "pause", pygame.K_n: "step", pygame.K_r: "reset",
        pygame.K_TAB: "hud", pygame.K_h: "help", pygame.K_F1: "help",
        pygame.K_c: "hash", pygame.K_f: "freeze",
        pygame.K_1: "deposit-", pygame.K_2: "deposit+",
        pygame.K_3: "decay-", pygame.K_4: "decay+",
        pygame.K_5: "sensor-", pygame.K_6: "sensor+",
        pygame.K_7: "step-", pygame.K_8: "step+",
        pygame.K_9: "rot-", pygame.K_0: "rot+",
        pygame.K_MINUS: "bright-", pygame.K_EQUALS: "bright+",
    }

    scale = np.float32(255.0 / display_max)
    # One RGBA staging array, reused every frame; allocating it per frame
    # would measure the allocator.
    rgb = np.empty((cfg.width, cfg.height, 3), dtype=np.uint8)

    stats = RenderStats()
    for _ in range(frames):
        for ev in pygame.event.get():
            if ev.type == pygame.QUIT:
                h.want_quit = True
            elif ev.type == pygame.KEYDOWN and ev.key in keymap:
                before = display_max
                display_max = sbhud.act(h, view, keymap[ev.key], display_max)
                if display_max != before:
                    scale = np.float32(255.0 / display_max)
                # The view is the editable copy; the simulation reads cfg, so
                # a changed parameter has to land there to have any effect.
                cfg.deposit, cfg.decay = view.deposit, view.decay
                cfg.sensor_dist, cfg.step = view.sensor_dist, view.step
                cfg.rot_steps = view.rot_steps
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
        gray = np.clip(sim.grid * scale, 0, 255).astype(np.uint8)
        g2d = gray.reshape(cfg.height, cfg.width)
        sbhud.draw(g2d, h, view, display_max)
        # The previous frame's draw cost: this one is not measured yet,
        # and the display is smoothed anyway.
        h.smooth(sim_ns / 1e6, stats.recent_mean(1))
        # pygame's surfarray is column-major (x, y), the grid is row-major.
        g2 = g2d.T
        rgb[:, :, 0] = g2
        rgb[:, :, 1] = g2
        rgb[:, :, 2] = g2
        pygame.surfarray.blit_array(screen, rgb)
        pygame.display.flip()
        stats.add(time.perf_counter_ns() - r0)

        if stats.since_title >= 60:
            ms = stats.recent_mean(60)
            pygame.display.set_caption(
                f"slimebench -- Python / pygame -- {ms:.2f} ms/frame "
                f"({1000.0 / ms if ms > 0 else 0:.0f} fps)")
            stats.since_title = 0

    pygame.quit()

    if o.want_json:
        j = stats.json(cfg, "pygame")
        if j:
            print(j)
    return 0


if __name__ == "__main__":
    sys.exit(main())
