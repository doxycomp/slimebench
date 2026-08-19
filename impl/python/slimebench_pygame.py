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

    scale = np.float32(255.0 / o.display_max)
    # One RGBA staging array, reused every frame; allocating it per frame
    # would measure the allocator.
    rgb = np.empty((cfg.width, cfg.height, 3), dtype=np.uint8)

    stats = RenderStats()
    for _ in range(frames):
        for ev in pygame.event.get():
            if ev.type == pygame.QUIT or (
                    ev.type == pygame.KEYDOWN and ev.key == pygame.K_ESCAPE):
                frames = 0
                break
        if frames == 0:
            break
        if not o.freeze_sim:
            sim.tick()

        r0 = time.perf_counter_ns()
        gray = np.clip(sim.grid * scale, 0, 255).astype(np.uint8)
        # pygame's surfarray is column-major (x, y), the grid is row-major.
        g2 = gray.reshape(cfg.height, cfg.width).T
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
