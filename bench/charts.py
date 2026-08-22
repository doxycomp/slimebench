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
OUT = ROOT / "docs" / "charts"

# One run directory, not the accumulated pile: every chart has to come from the
# same machine state as the tables in docs/RESULTS.md, or a reader comparing a
# chart against a table is comparing two different afternoons.
#
#   bench/charts.py results/run-YYYYmmdd-HHMM
#
# Required, with no default. There used to be one, and it was a series name
# frozen into this line -- which meant that after that directory was replaced,
# running this script with no argument regenerated every chart from nothing
# (see `load`) and reported success. A stale default is a worse outcome than a
# usage error, because it is the one the reader cannot see.
if len(sys.argv) != 2:
    sys.exit(f"usage: {sys.argv[0]} results/run-YYYYmmdd-HHMM")
RESULTS = pathlib.Path(sys.argv[1])
if not RESULTS.is_dir():
    sys.exit(f"error: {RESULTS} is not a directory")

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


MISSING: list[str] = []


def load(name: str) -> list[dict]:
    """Rows from one result file, or none -- and a note either way.

    An absent file and an empty one both mean a chart is about to be drawn
    from nothing. Returning [] silently is how a run that lost a whole phase
    still produced a full set of charts.
    """
    p = RESULTS / name
    if not p.exists():
        MISSING.append(f"{name}: absent")
        return []
    rows = [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines()
            if l.strip()]
    if not rows:
        MISSING.append(f"{name}: no rows")
    return rows


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
               ideal: bool = False, baseline: float | None = None,
               baseline_label: str = "") -> None:
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

    # A horizontal reference the reader is meant to compare against -- for the
    # GIL chart, "1.0" is the whole point and it falls between two gridlines.
    if baseline is not None:
        y = py(baseline)
        s.append(f'<line x1="{pad_l}" y1="{y:.1f}" x2="{pad_l + plot_w}" '
                 f'y2="{y:.1f}" stroke="{MUTED}" stroke-width="1" '
                 f'stroke-dasharray="5 4"/>')
        if baseline_label:
            s.append(f'<text x="{pad_l + plot_w + 6}" y="{y + 4:.1f}" '
                     f'class="lbl-s">{esc(baseline_label)}</text>')

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
    rows = [r for r in load("A-crosslang-serial.jsonl")
            if r.get("status") == "ok" and r.get("class") == "S"
            and r.get("conformance_class") in ("A", "B")]
    # One row per implementation, at its best profile -- the compiler axis has
    # its own chart.
    best: dict[str, dict] = {}
    for r in rows:
        k = (r["lang"], r.get("variant") or "", r["cc"])
        if k not in best or r["ms_per_tick_median"] < best[k]["ms_per_tick_median"]:
            best[k] = r
    rows = list(best.values())
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
        # Compilers that carry no information beyond the language name.
        generic_cc = {"node", "cargo", "perl", "python3", "ghc", "nvcc", "gcc",
                      "ocamlopt", "javac", "dotnet", "gfortran", "numba",
                      "lake", "swift"}
        if lang_count[name] > 1 and r["cc"] not in generic_cc | {"gcc"}:
            qual.append(r["cc"])
        elif lang_count[name] > 1 and r["cc"] == "gcc":
            qual.append("gcc")
        v = r.get("variant") or ""
        if v and v not in ("scalar", "default"):
            qual.append(v)
        elif r["backend"] not in ("headless", "node"):
            qual.append(r["backend"])
        # De-duplicate: the numba target's compiler *and* variant are both
        # "numba", which produced "Python numba numba". Drop repeats and
        # anything that just echoes the language.
        seen, uniq = {name.lower()}, []
        for q in qual:
            if q.lower() in seen:
                continue
            seen.add(q.lower())
            uniq.append(q)
        if uniq:
            name += " " + " ".join(uniq)
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
    """The two reduction strategies, in C."""
    rows = [r for r in load("P-parallel.jsonl") if r.get("lang_label") == "c"]
    base = next((r["ms_total"] for r in rows if r.get("threads") == 1), None)
    if not base:
        return
    series = []
    for want, colour in (("binned", PALETTE["c"]), ("private", PALETTE["ts"])):
        pts = [(1.0, 1.0)]
        for r in sorted(rows, key=lambda r: r.get("threads", 1)):
            if r.get("threads", 1) > 1 and want in (r.get("variant") or ""):
                pts.append((float(r["threads"]), base / r["ms_total"]))
        if len(pts) > 1:
            series.append((want, colour, pts))
    if series:
        line_chart(OUT / "scaling.svg",
                   "Class P: how the two deposit reductions scale",
                   "2048x2048, 1 048 576 agents, deferred. 16 physical cores, "
                   "32 logical.",
                   series, "threads", "speedup vs 1 thread", ideal=True)


def chart_classes() -> None:
    """The headline: how far the same simulation can be pushed."""
    par = load("P-parallel.jsonl")
    gpu = load("H-gpu.jsonl")

    def par_at(lang, threads, want):
        for r in par:
            if (r.get("lang_label") == lang and r.get("threads") == threads
                    and (threads == 1 or want in (r.get("variant") or ""))):
                return r["ms_total"]
        return None

    def gpu_at(host, preset="medium"):
        for r in gpu:
            if r.get("lang_label") == host and r.get("preset") == preset:
                return r["ms_total"]
        return None

    cpu1 = par_at("c", 1, "")
    best_par = min((v for v in (par_at("cpp", t, "binned") for t in (16, 32))
                    if v), default=None)
    entries = []
    for label, val, col in (
        ("C, 1 thread (class S)", cpu1, PALETTE["c"]),
        ("C++, 32 threads (class P)", best_par, PALETTE["cpp"]),
        ("GL compute (class G)", gpu_at("gl43 C"), PALETTE["glcompute"]),
        ("CUDA (class G)", gpu_at("cuda"), PALETTE["cuda"]),
    ):
        if val:
            entries.append(Bar(label, val, col,
                               note=f"{cpu1 / val:.0f}x" if cpu1 else ""))
    if len(entries) >= 2:
        hbar_chart(OUT / "classes.svg",
                   "How far the same simulation goes",
                   "2048x2048, 1 048 576 agents, 100 ticks, deferred. Log scale.",
                   entries, "ms total (log)", log=True)


def chart_haskell_style() -> None:
    """One language, three ways of writing it -- the style axis."""
    rows = load("M-haskell-style.jsonl")
    if not rows:
        return
    label = {
        "C reference (gcc -O3 -native)": "C reference",
        "haskell lowlevel, (!) lookups": "Haskell low-level, (!)",
        "haskell lowlevel, unsafeAt": "Haskell low-level, unsafeAt",
        "haskell idiomatic (vector)": "Haskell idiomatic, vector",
    }
    bars = []
    for r in rows:
        v = r.get("variant", "")
        col = PALETTE["c"] if v.startswith("C ") else PALETTE["haskell"]
        base = next((x["ms_total"] for x in rows if x.get("variant", "").startswith("C ")), None)
        bars.append(Bar(label.get(v, v), r["ms_total"], col,
                        note=f"{r['ms_total'] / base:.2f}x" if base else ""))
    hbar_chart(OUT / "haskell-style.svg",
               "One language, three ways of writing it",
               "1024x1024, 262 144 agents, 300 ticks, deferred. All four bit-identical.",
               bars, "ms total")


def chart_scaling_langs() -> None:
    """Speedup curves for every language that has a class-P port."""
    rows = load("P-parallel.jsonl")
    if not rows:
        return
    colours = {"c": PALETTE["c"], "cpp": PALETTE["cpp"], "rust": PALETTE["rust"],
               "ts": PALETTE["ts"], "haskell": PALETTE["haskell"],
               "python": PALETTE["python"], "perl": PALETTE["perl"]}
    names = {"c": "C", "cpp": "C++", "rust": "Rust", "ts": "TypeScript",
             "haskell": "Haskell", "python": "Python", "perl": "Perl"}
    series = []
    for lang in ("c", "cpp", "haskell", "rust", "ts", "python", "perl"):
        mine = [r for r in rows if r.get("lang_label") == lang]
        base = next((r["ms_total"] for r in mine if r.get("threads") == 1), None)
        if not base:
            continue
        pts = [(1.0, 1.0)]
        for r in sorted(mine, key=lambda r: r.get("threads", 1)):
            t = r.get("threads", 1)
            v = r.get("variant") or ""
            if t <= 1:
                continue
            # Perl's reduction is replicated, not binned; take whatever the
            # language's own best-guaranteed strategy produced.
            if lang != "perl" and "binned" not in v:
                continue
            pts.append((float(t), base / r["ms_total"]))
        if len(pts) > 1:
            series.append((names[lang], colours[lang], pts))
    if series:
        line_chart(OUT / "scaling-langs.svg",
                   "Class P: the same design in nine languages",
                   "2048x2048, 100 ticks, deferred, binned. Perl at 512x512 -- "
                   "medium would be hours. 16 physical cores, 32 logical.",
                   series, "threads / processes", "speedup vs 1", ideal=True)


def chart_render() -> None:
    """Class R: six languages, two backends, two renderers."""
    rows = load("Q-render.jsonl")
    if not rows:
        return
    order = ["c", "cpp", "haskell", "rust", "python", "perl"]
    gpu = [r for r in rows if "D3D12" in r.get("renderer", "")]
    bars = []
    for impl in order:
        for be in ("sdl2", "pygame", "raylib"):
            r = next((x for x in gpu if x["impl"] == impl and x["backend"] == be), None)
            if not r:
                continue
            # Perl is off the scale of everything else; the log axis carries it.
            label = f"{impl} {be}"
            bars.append(Bar(label, r["ms_render_median"], PALETTE.get(impl, ACCENT)))
    if bars:
        hbar_chart(OUT / "render.svg",
                   "Class R: the pixel format decides, not the language",
                   "1024x1024, --freeze-sim, RTX 5080 via Mesa D3D12. Log scale.",
                   bars, "ms per frame (log)", log=True)


def chart_kernels() -> None:
    """The four-way diffusion-kernel comparison.

    ms_diffuse, not ms_total: the agent pass is the same code in all of them
    and would flatten the difference to nothing.
    """
    rows = load("V-asm-kernels.jsonl")
    if not rows:
        return
    names = {"no-simd": "scalar loop", "simd": "intrinsics", "asm": "hand-written asm"}
    order = ["no-simd", "simd", "asm"]
    colours = {"no-simd": "#8c8c8c", "simd": ACCENT, "asm": "#54a24b"}
    bars = []
    for cc in sorted({r["cc"] for r in rows}):
        for k in order:
            m = [r for r in rows if r["cc"] == cc and r["kernel"] == k]
            if not m:
                continue
            bars.append(Bar(f"{cc}  {names[k]}", m[0]["ms_diffuse"], colours[k]))
    if not bars:
        return
    preset = rows[0]["preset"]
    hbar_chart(OUT / "kernels.svg",
               "Class V: what is left for hand-written assembly",
               f"Diffusion pass only, {preset} {rows[0]['width']}^2, 100 ticks. "
               "Same grid hash throughout.",
               bars, "ms in the diffusion pass")


def chart_gil() -> None:
    """Free-threading against the GIL, threads against processes.

    Plotted as speedup rather than milliseconds. In milliseconds the GIL
    thread line reaches 14.7 s while everything else sits near 0.5 s, and a
    linear axis collapses the three interesting curves into one flat line at
    the bottom. As speedup all four are legible, and the shape that matters --
    one curve going the wrong way past 1.0 -- is the shape you see.
    """
    rows = load("P-gil-matrix.jsonl")
    if not rows:
        return
    base = {r["interp"]: r["ms_total"] for r in rows if r.get("mp_backend") == "serial"}
    if not base:
        return
    series = []
    style = {
        ("gil", "threads"): ("3.12 threads", "#e45756"),
        ("gil", "processes"): ("3.12 processes", "#f58518"),
        ("nogil", "threads"): ("3.14t threads", "#54a24b"),
        ("nogil", "processes"): ("3.14t processes", "#4c78a8"),
    }
    threads = [1, 2, 4, 8, 16]
    for (interp, be), (label, colour) in style.items():
        if interp not in base:
            continue
        pts = [(1, 1.0)]
        for t in threads[1:]:
            m = [r for r in rows
                 if r.get("interp") == interp and r.get("mp_backend") == be
                 and r["threads"] == t and "binned" in (r.get("variant") or "")]
            if m:
                pts.append((t, base[interp] / m[0]["ms_total"]))
        if len(pts) > 1:
            series.append((label, colour, pts))
    if not series:
        return
    line_chart(OUT / "gil.svg",
               "What the GIL costs, with everything else held fixed",
               "Same Worker, same phase order, binned reduction, small 1024^2, "
               "100 ticks. Above the dashed line the extra workers are "
               "paying for themselves.",
               series, "threads", "speedup vs 1 thread",
               baseline=1.0, baseline_label="1 thread")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    print("charts:")
    chart_languages()
    chart_compilers()
    chart_scaling()
    chart_classes()
    chart_haskell_style()
    chart_scaling_langs()
    chart_render()
    chart_kernels()
    chart_gil()
    if MISSING:
        print("  charts drawn from missing or empty inputs:")
        for m in sorted(set(MISSING)):
            print(f"    {m}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
