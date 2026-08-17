#!/usr/bin/env python3
"""Render the result JSONL files as SVG charts for docs/RESULTS.md.

    bench/charts.py            # regenerate docs/charts/*.svg

Hand-rolled SVG rather than matplotlib: the rest of this repo builds with
nothing but the toolchains under test, and a chart generator is a poor reason
to introduce the first Python dependency. It also keeps the output diffable,
which matters when the charts are committed.

The SVGs carry their own stylesheet with a prefers-color-scheme block, so they
stay readable on GitHub in both themes.
"""

from __future__ import annotations

import json
import math
import pathlib
import sys
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"
OUT = ROOT / "docs" / "charts"

# Colour-blind-safe, and distinguishable in both themes.
PALETTE = {
    "c": "#4c78a8",
    "cpp": "#f58518",
    "rust": "#54a24b",
    "haskell": "#b279a2",
    "ts": "#e45756",
    "python": "#72b7b2",
    "perl": "#eeca3b",
    "cuda": "#9d755d",
    "glcompute": "#bab0ac",
}
ACCENT = "#4c78a8"
MUTED = "#8a8a8a"

STYLE = """
  <style>
    .bg    { fill: none; }
    .lbl   { fill: #24292f; font: 12px ui-monospace, "SF Mono", Menlo, monospace; }
    .lbl-s { fill: #57606a; font: 10px ui-monospace, "SF Mono", Menlo, monospace; }
    .ttl   { fill: #24292f; font: 600 14px -apple-system, "Segoe UI", sans-serif; }
    .sub   { fill: #57606a; font: 11px -apple-system, "Segoe UI", sans-serif; }
    .axis  { stroke: #d0d7de; stroke-width: 1; }
    .grid  { stroke: #d0d7de; stroke-width: 1; stroke-dasharray: 2 3; opacity: .7; }
    @media (prefers-color-scheme: dark) {
      .lbl   { fill: #e6edf3; }
      .lbl-s { fill: #9198a1; }
      .ttl   { fill: #e6edf3; }
      .sub   { fill: #9198a1; }
      .axis  { stroke: #3d444d; }
      .grid  { stroke: #3d444d; }
    }
  </style>
"""


def load(name: str) -> list[dict]:
    p = RESULTS / name
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines() if l.strip()]


def esc(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


@dataclass
class Bar:
    label: str
    value: float
    colour: str
    note: str = ""


def hbar_chart(path: pathlib.Path, title: str, subtitle: str, bars: list[Bar],
               unit: str, log: bool = False, width: int = 760) -> None:
    """Horizontal bars, optionally log-scaled.

    Log scale exists because the language comparison spans a factor of 500 --
    on a linear axis every compiled language collapses into one pixel.
    """
    pad_l, pad_r, pad_t, pad_b = 190, 90, 52, 34
    row_h, gap = 24, 6
    plot_w = width - pad_l - pad_r
    height = pad_t + len(bars) * (row_h + gap) + pad_b

    vmax = max(b.value for b in bars)
    vmin = min(b.value for b in bars if b.value > 0)

    def x_of(v: float) -> float:
        if not log:
            return plot_w * (v / vmax)
        lo, hi = math.log10(vmin / 1.6), math.log10(vmax * 1.15)
        return plot_w * (math.log10(max(v, vmin / 1.6)) - lo) / (hi - lo)

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
         f'width="{width}" height="{height}" role="img" aria-label="{esc(title)}">',
         STYLE,
         f'<text x="16" y="22" class="ttl">{esc(title)}</text>',
         f'<text x="16" y="39" class="sub">{esc(subtitle)}</text>']

    # gridlines
    if log:
        ticks = []
        e = math.floor(math.log10(vmin))
        while 10 ** e <= vmax * 1.15:
            for m in (1, 2, 5):
                v = m * 10 ** e
                if vmin / 1.6 <= v <= vmax * 1.15:
                    ticks.append(v)
            e += 1
    else:
        ticks = [vmax * f for f in (0, 0.25, 0.5, 0.75, 1.0)]

    for v in ticks:
        x = pad_l + x_of(v)
        s.append(f'<line x1="{x:.1f}" y1="{pad_t - 8}" x2="{x:.1f}" '
                 f'y2="{height - pad_b + 4}" class="grid"/>')
        lab = f"{v:g}"
        s.append(f'<text x="{x:.1f}" y="{height - pad_b + 18}" class="lbl-s" '
                 f'text-anchor="middle">{lab}</text>')

    s.append(f'<text x="{pad_l + plot_w / 2:.0f}" y="{height - 4}" class="lbl-s" '
             f'text-anchor="middle">{esc(unit)}</text>')

    for i, b in enumerate(bars):
        y = pad_t + i * (row_h + gap)
        w = max(x_of(b.value), 2)
        s.append(f'<text x="{pad_l - 10}" y="{y + row_h * 0.7:.0f}" class="lbl" '
                 f'text-anchor="end">{esc(b.label)}</text>')
        s.append(f'<rect x="{pad_l}" y="{y}" width="{w:.1f}" height="{row_h}" '
                 f'rx="2" fill="{b.colour}"/>')
        txt = f"{b.value:,.0f}" if b.value >= 10 else f"{b.value:.2f}"
        if b.note:
            txt += f"  {b.note}"
        s.append(f'<text x="{pad_l + w + 8:.1f}" y="{y + row_h * 0.7:.0f}" '
                 f'class="lbl-s">{esc(txt)}</text>')

    s.append(f'<line x1="{pad_l}" y1="{pad_t - 8}" x2="{pad_l}" '
             f'y2="{height - pad_b + 4}" class="axis"/>')
    s.append("</svg>")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(s) + "\n", encoding="utf-8", newline="\n")
    print(f"  wrote {path.relative_to(ROOT)}")


def line_chart(path: pathlib.Path, title: str, subtitle: str,
               series: list[tuple[str, str, list[tuple[float, float]]]],
               x_label: str, y_label: str, width: int = 760, height: int = 380,
               ideal: bool = False) -> None:
    pad_l, pad_r, pad_t, pad_b = 62, 150, 52, 46
    plot_w = width - pad_l - pad_r
    plot_h = height - pad_t - pad_b

    xs = [p[0] for _, _, pts in series for p in pts]
    ys = [p[1] for _, _, pts in series for p in pts]
    xmax = max(xs)
    ymax = max(ys + ([xmax] if ideal else []))
    ymax = math.ceil(ymax / 2) * 2

    def px(v: float) -> float:
        return pad_l + plot_w * (math.log2(v) / math.log2(xmax))

    def py(v: float) -> float:
        return pad_t + plot_h * (1 - v / ymax)

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
         f'width="{width}" height="{height}" role="img" aria-label="{esc(title)}">',
         STYLE,
         f'<text x="16" y="22" class="ttl">{esc(title)}</text>',
         f'<text x="16" y="39" class="sub">{esc(subtitle)}</text>']

    step = 2 if ymax <= 12 else 4
    for v in range(0, int(ymax) + 1, step):
        y = py(v)
        s.append(f'<line x1="{pad_l}" y1="{y:.1f}" x2="{pad_l + plot_w}" '
                 f'y2="{y:.1f}" class="grid"/>')
        s.append(f'<text x="{pad_l - 8}" y="{y + 4:.1f}" class="lbl-s" '
                 f'text-anchor="end">{v}</text>')

    t = 1
    while t <= xmax:
        x = px(t)
        s.append(f'<text x="{x:.1f}" y="{height - pad_b + 18}" class="lbl-s" '
                 f'text-anchor="middle">{t}</text>')
        t *= 2

    if ideal:
        pts = " ".join(f"{px(v):.1f},{py(v):.1f}" for v in (1, xmax))
        s.append(f'<polyline points="{pts}" fill="none" stroke="{MUTED}" '
                 f'stroke-width="1" stroke-dasharray="4 4"/>')
        s.append(f'<text x="{px(xmax) + 6:.1f}" y="{py(xmax) + 4:.1f}" '
                 f'class="lbl-s">linear</text>')

    for name, colour, pts in series:
        poly = " ".join(f"{px(x):.1f},{py(y):.1f}" for x, y in pts)
        s.append(f'<polyline points="{poly}" fill="none" stroke="{colour}" '
                 f'stroke-width="2.2" stroke-linejoin="round"/>')
        for x, y in pts:
            s.append(f'<circle cx="{px(x):.1f}" cy="{py(y):.1f}" r="3.2" fill="{colour}"/>')
        lx, ly = pts[-1]
        s.append(f'<text x="{px(lx) + 8:.1f}" y="{py(ly) + 4:.1f}" class="lbl-s" '
                 f'fill="{colour}">{esc(name)}</text>')

    s.append(f'<line x1="{pad_l}" y1="{pad_t}" x2="{pad_l}" '
             f'y2="{pad_t + plot_h}" class="axis"/>')
    s.append(f'<line x1="{pad_l}" y1="{pad_t + plot_h}" x2="{pad_l + plot_w}" '
             f'y2="{pad_t + plot_h}" class="axis"/>')
    s.append(f'<text x="{pad_l + plot_w / 2:.0f}" y="{height - 8}" class="lbl-s" '
             f'text-anchor="middle">{esc(x_label)}</text>')
    s.append(f'<text x="14" y="{pad_t + plot_h / 2:.0f}" class="lbl-s" '
             f'transform="rotate(-90 14 {pad_t + plot_h / 2:.0f})" '
             f'text-anchor="middle">{esc(y_label)}</text>')
    s.append("</svg>")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(s) + "\n", encoding="utf-8", newline="\n")
    print(f"  wrote {path.relative_to(ROOT)}")


# --------------------------------------------------------------------------- #


def chart_languages() -> None:
    rows = [r for r in load("A-crosslang.jsonl") if r.get("status") == "ok"]
    if not rows:
        return
    rows.sort(key=lambda r: r["ms_per_tick_median"])

    # Several rows share a language (two compilers, two variants), so the
    # label has to carry whatever actually distinguishes them.
    lang_count: dict[str, int] = {}
    for r in rows:
        lang_count[r["lang"]] = lang_count.get(r["lang"], 0) + 1

    bars = []
    for r in rows:
        name = r["lang"]
        qual = []
        # Skip the compiler when it just repeats the language ("Perl perl").
        generic_cc = {"node", "cargo", "perl", "python3", "ghc", "nvcc", "gcc"}
        if lang_count[name] > 1 and r["cc"] not in generic_cc | {"gcc"}:
            qual.append(r["cc"])
        elif lang_count[name] > 1 and r["cc"] == "gcc":
            qual.append("gcc")
        v = r.get("variant") or ""
        if v and v not in ("scalar", "default"):
            qual.append(v)
        elif r["backend"] not in ("headless", "node"):
            qual.append(r["backend"])
        if qual:
            name += " " + " ".join(qual)
        tier = r.get("conformance_class", "A")
        bars.append(Bar(name, r["ms_per_tick_median"],
                        PALETTE.get(r["target"].split("-")[0], ACCENT),
                        note=f"tier {tier}"))
    hbar_chart(OUT / "languages.svg",
               "Class S: one thread, one core",
               "256x256, 16 384 agents, serial update. Log scale -- the range is 500x.",
               bars, "ms per tick (log)", log=True)


def chart_compilers() -> None:
    rows = [r for r in load("C-compiler-matrix.jsonl") if r.get("status") == "ok"]
    if not rows:
        return
    rows = [r for r in rows if r["profile"] not in ("o0",)]
    rows.sort(key=lambda r: r["ms_total_best"])
    bars = [Bar(f"{r['lang']} {r['cc']} {r['profile']}", r["ms_total_best"],
                "#c94c4c" if r["conformance_class"] == "C"
                else PALETTE.get(r["target"], ACCENT),
                note="fast-math" if r["conformance_class"] == "C" else "")
            for r in rows[:18]]
    hbar_chart(OUT / "compilers.svg",
               "Compiler matrix",
               "1024x1024, 262 144 agents, 300 ticks. Red = fast-math (conformance tier C).",
               bars, "ms total")


def chart_scaling() -> None:
    rows = load("E-parallel-scaling.jsonl")
    if not rows:
        return
    med = [r for r in rows if r.get("preset") == "medium" and r.get("status", "ok") == "ok"]
    base = next((r["ms_total"] for r in med if r.get("threads", 1) == 1), None)
    if not base:
        return
    series = []
    for variant, colour in (("binned", PALETTE["c"]), ("private", PALETTE["ts"])):
        pts = [(1.0, 1.0)]
        for r in sorted(med, key=lambda r: r.get("threads", 1)):
            if r.get("variant") == variant and r.get("threads", 1) > 1:
                pts.append((float(r["threads"]), base / r["ms_total"]))
        if len(pts) > 1:
            series.append((variant, colour, pts))
    if series:
        line_chart(OUT / "scaling.svg",
                   "Class P: how the two deposit reductions scale",
                   "2048x2048, 1 048 576 agents, deferred. 16 physical cores, 32 logical.",
                   series, "threads", "speedup vs 1 thread", ideal=True)


def chart_classes() -> None:
    """The headline: how far the same simulation can be pushed."""
    def pick(name, **match):
        for r in load(name):
            if all(r.get(k) == v for k, v in match.items()):
                return r
        return None

    entries = []
    g = load("H-gpu.jsonl")

    def gpu(impl):
        c = [r for r in g if r.get("impl") == impl and r.get("preset") == "medium"]
        return min((r["ms_total"] for r in c), default=None)

    cpu1 = min((r["ms_total"] for r in g
                if r.get("impl") == "c" and r.get("preset") == "medium"
                and r.get("threads", 1) == 1), default=None)
    cpu16 = min((r["ms_total"] for r in g
                 if r.get("impl") == "c" and r.get("preset") == "medium"
                 and r.get("threads", 1) == 16), default=None)
    cuda = gpu("cuda")
    gl = gpu("glcompute")

    for label, val, col in (
        ("C, 1 thread (class S)", cpu1, PALETTE["c"]),
        ("C, 16 threads (class P)", cpu16, PALETTE["rust"]),
        ("GL compute (class G)", gl, PALETTE["glcompute"]),
        ("CUDA (class G)", cuda, PALETTE["cuda"]),
    ):
        if val:
            entries.append(Bar(label, val, col,
                               note=f"{cpu1 / val:.0f}x" if cpu1 else ""))
    if len(entries) >= 2:
        hbar_chart(OUT / "classes.svg",
                   "How far the same simulation goes",
                   "2048x2048, 1 048 576 agents, 100 ticks, deferred. Log scale.",
                   entries, "ms total (log)", log=True)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    print("charts:")
    chart_languages()
    chart_compilers()
    chart_scaling()
    chart_classes()
    return 0


if __name__ == "__main__":
    sys.exit(main())
