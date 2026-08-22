"""The on-screen overlay, drawn into the same greyscale buffer as the C ports.

impl/c/sb_hud.h explains the design; this is that design in Python, with the
same five status lines, the same help text, the same scale rule and the same
`edited` flag. It reads and writes a plain view object rather than a sim, for
the same reason the C header does: nothing here should know what a simulation
is, so pygame and raylib can share it unchanged.

Bit-exactness is not at stake -- the HUD draws over pixels after the tick, and
`--json` turns it off -- but the *font* is checked, because a glyph table that
has drifted between C, Rust and here is a real inconsistency and a silent one.
slimebench.font carries the same FNV-32 the other two check.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .font import GLYPH_H, GLYPH_W, glyph

FG = 255          # SB_HUD_FG
DIM_SHIFT = 4     # the C side divides the panel background by four

HELP = [
    "KEYS",
    "  SPACE    PAUSE / RESUME",
    "  N        SINGLE STEP",
    "  R        RESET SIMULATION",
    "  TAB      HUD ON / OFF",
    "  H  F1    THIS HELP",
    "  C        PRINT HASHES TO STDERR",
    "  F        FREEZE SIM (RENDER ONLY)",
    "  1 / 2    DEPOSIT    DOWN / UP",
    "  3 / 4    DECAY      DOWN / UP",
    "  5 / 6    SENSOR     DOWN / UP",
    "  7 / 8    STEP       DOWN / UP",
    "  9 / 0    ROT STEPS  DOWN / UP",
    "  - / =    BRIGHTNESS DOWN / UP",
    "  Q  ESC   QUIT",
    "",
    "CHANGING A PARAMETER LEAVES THE SPEC-1",
    "CONFIGURATION. THE RUN IS THEN MARKED",
    "EDITED AND ITS HASHES REPRODUCE NOTHING.",
]


@dataclass
class HudView:
    """The scalars the overlay shows, copied out of the config by the caller."""

    width: int
    height: int
    agents: int
    threads: int = 1
    rot_steps: int = 0
    deposit: float = 0.0
    decay: float = 0.0
    sensor_dist: float = 0.0
    step: float = 0.0
    deferred: bool = True


@dataclass
class Hud:
    label: str
    show_hud: bool = True
    show_help: bool = False
    paused: bool = False
    step_once: bool = False
    want_quit: bool = False
    want_reset: bool = False
    want_hash: bool = False
    frozen: bool = False
    edited: bool = False
    tick: int = 0
    sim_ms: float = 0.0
    render_ms: float = 0.0
    _warned: bool = field(default=False, repr=False)

    def smooth(self, sim_ms: float, render_ms: float) -> None:
        """Exponential smoothing, so the numbers can be read while they move."""
        a = 0.1
        self.sim_ms = self.sim_ms * (1 - a) + sim_ms * a
        self.render_ms = self.render_ms * (1 - a) + render_ms * a


def scale_for(width: int) -> int:
    """sb_hud_scale: about ninety characters across, clamped to readable."""
    return max(1, min(4, width // 560))


def _dim(g: np.ndarray, x0: int, y0: int, x1: int, y1: int) -> None:
    h, w = g.shape
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(w, x1), min(h, y1)
    if x1 > x0 and y1 > y0:
        g[y0:y1, x0:x1] //= DIM_SHIFT


def _text(g: np.ndarray, px: int, py: int, sc: int, s: str) -> None:
    h, w = g.shape
    for ch in s:
        if ch != " ":
            rows = glyph(ch)
            for gy in range(GLYPH_H):
                for gx in range(GLYPH_W):
                    if rows[gy * GLYPH_W + gx] != "#":
                        continue
                    x, y = px + gx * sc, py + gy * sc
                    if 0 <= x < w and 0 <= y < h:
                        g[y:min(y + sc, h), x:min(x + sc, w)] = FG
        px += (GLYPH_W + 1) * sc


def draw(g: np.ndarray, hud: Hud, v: HudView, display_max: float) -> None:
    """Draw the overlay into a (height, width) uint8 array, in place."""
    if not hud.show_hud:
        return
    h, w = g.shape
    sc = scale_for(w)
    lh = (GLYPH_H + 3) * sc
    pad = 4 * sc

    total = hud.sim_ms + hud.render_ms
    lines = [
        f"slimebench  {hud.label}  {w}x{h}  {v.agents} agents",
        f"tick {hud.tick}   sim {hud.sim_ms:.2f} ms   "
        f"draw {hud.render_ms:.2f} ms   {1000.0 / total if total > 0 else 0.0:.0f} fps",
        f"deposit {v.deposit:.3f}  decay {v.decay:.3f}  "
        f"sensor {v.sensor_dist:.1f}  step {v.step:.2f}  rot {v.rot_steps}",
        f"update {'deferred' if v.deferred else 'serial'}  "
        f"threads {v.threads}  bright {display_max:.0f}",
        f"{'paused' if hud.paused else 'running'}"
        f"{'   edited -- not reproducible' if hud.edited else ''}   h for help",
    ]

    bw = max(len(s) for s in lines) * (GLYPH_W + 1) * sc + 2 * pad
    bh = len(lines) * lh + 2 * pad
    _dim(g, 0, 0, bw, bh)
    for i, s in enumerate(lines):
        _text(g, pad, pad + i * lh, sc, s)

    if not hud.show_help:
        return
    hy = bh + pad
    hw = max(max(len(s) for s in HELP) * (GLYPH_W + 1) * sc + 2 * pad, bw)
    _dim(g, 0, hy - pad, hw, hy + len(HELP) * lh + pad)
    for i, s in enumerate(HELP):
        _text(g, pad, hy + i * lh, sc, s)


# ---- keyboard -------------------------------------------------------------
#
# Named actions rather than key codes: pygame and raylib disagree about how a
# key is spelled, and sb_hud.h makes the same split for the same reason. A
# frontend maps its own events to these names and calls `act`.

_STEPS = {
    "deposit": ("deposit", 0.01, 0.0, 10.0),
    "decay": ("decay", 0.01, 0.0, 1.0),
    "sensor": ("sensor_dist", 0.5, 0.5, 64.0),
    "step": ("step", 0.05, 0.05, 8.0),
    "rot": ("rot_steps", 1, 1, 360),
}


def act(hud: Hud, v: HudView, action: str, display_max: float) -> float:
    """Apply one named action. Returns the (possibly changed) brightness.

    Anything that moves a simulation parameter sets `edited`, which the status
    line shows and which any JSON emitted afterwards has to carry: the run has
    left the SPEC-1 configuration and its hashes no longer reproduce anything.
    """
    if action == "quit":
        hud.want_quit = True
    elif action == "pause":
        hud.paused = not hud.paused
    elif action == "step":
        hud.step_once = True
        hud.paused = True
    elif action == "reset":
        hud.want_reset = True
    elif action == "hud":
        hud.show_hud = not hud.show_hud
    elif action == "help":
        hud.show_help = not hud.show_help
    elif action == "hash":
        hud.want_hash = True
    elif action == "freeze":
        hud.frozen = not hud.frozen
    elif action == "bright-":
        display_max = max(1.0, display_max / 1.25)
    elif action == "bright+":
        display_max = min(1e6, display_max * 1.25)
    elif "-" in action or "+" in action:
        name, sign = action[:-1], action[-1]
        if name in _STEPS:
            attr, delta, lo, hi = _STEPS[name]
            cur = getattr(v, attr)
            new = cur + (delta if sign == "+" else -delta)
            new = max(lo, min(hi, new))
            if new != cur:
                setattr(v, attr, type(cur)(new))
                hud.edited = True
    return display_max
