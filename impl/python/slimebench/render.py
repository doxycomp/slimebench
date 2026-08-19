"""Shared render-timing helper for the windowed Python frontends (SPEC-1 11.1).

A rendering backend benchmark measures the upload path grid -> texture ->
screen. If the simulation keeps running during the measurement it dominates
the frame and the backends come out indistinguishable, so `--freeze-sim` stops
it and every frame re-uploads the same grid.

Same contract and the same JSON as `impl/c/sb_render.h`.
"""

from __future__ import annotations

import json


class RenderStats:
    def __init__(self) -> None:
        self.ms: list[float] = []
        self.since_title = 0

    def add(self, ns: int) -> None:
        self.ms.append(ns / 1e6)
        self.since_title += 1

    def recent_mean(self, k: int) -> float:
        if not self.ms:
            return 0.0
        take = self.ms[-min(k, len(self.ms)):]
        return sum(take) / len(take)

    def json(self, cfg, backend: str) -> str | None:
        if not self.ms:
            return None
        srt = sorted(self.ms)
        n = len(srt)
        median = srt[n // 2]
        p99 = srt[min(n - 1, int(n * 0.99))]
        mpix = cfg.width * cfg.height / 1e6
        return json.dumps({
            "schema": 1, "impl": "python", "backend": backend, "class": "R",
            "preset": cfg.preset, "width": cfg.width, "height": cfg.height,
            "frames": n,
            "ms_render_mean": round(sum(self.ms) / n, 6),
            "ms_render_median": round(median, 6),
            "ms_render_p99": round(p99, 6),
            "fps_equiv": round(1000.0 / median, 2) if median > 0 else 0.0,
            "mpixels_per_s": round(mpix * 1000.0 / median, 1) if median > 0 else 0.0,
        })
