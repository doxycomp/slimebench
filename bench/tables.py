#!/usr/bin/env python3
"""Render the markdown tables in docs/RESULTS.md from one measurement run.

    bench/tables.py results/run-20260819-2130

Writes each table to stdout under a heading naming the section it belongs to.
The point is that the numbers in the document come out of a directory rather
than out of a transcript: paste-and-check instead of paste-and-hope, and a
re-run regenerates every table from the same code.

Only the tables. The prose around them is the part worth writing by hand.
"""

from __future__ import annotations

import io
import json
import pathlib
import sys
from collections import defaultdict


def load(d: pathlib.Path, name: str) -> list[dict]:
    p = d / name
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines() if l.strip()]


# The statistics rule, reader-facing half. bench/run.py records the minimum of
# the repetitions plus (max - min) / min; these render it and flag the rows
# where it is large enough that neighbouring positions mean nothing.
NOISY_SPREAD = 0.05


def spread_cell(r: dict, key: str = "ms_total_spread") -> str:
    """The repetition spread of the column this table ranks by.

    `key` is not decoration: ms_total and ms_per_tick_median differ by an
    order of magnitude in noise, and quoting the wrong one puts a warning
    next to a number nobody is reading.
    """
    s = r.get(key)
    if s is None:
        return "—"
    return f"{s * 100:.1f}%" + (" ⚠" if s > NOISY_SPREAD else "")


def spread_note(rows: list[dict], key: str = "ms_total_spread") -> str:
    """One line under a table, naming the rows that cannot be ranked."""
    noisy = [r for r in rows if (r.get(key) or 0) > NOISY_SPREAD]
    if not noisy:
        return ""
    worst = max(r[key] for r in noisy)
    return (f"\n⚠ {len(noisy)} row(s) varied by more than "
            f"{NOISY_SPREAD * 100:.0f} % between repetitions, up to "
            f"{worst * 100:.0f} %. Differences smaller than a row's own spread "
            f"are not rankings.\n")


def table(headers: list[str], rows: list[list[str]], align: str | None = None) -> str:
    if not rows:
        return "_(no rows)_\n"
    align = align or ("l" + "r" * (len(headers) - 1))
    sep = {"l": "---", "r": "---:", "c": ":-:"}
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join(sep[a] for a in align) + "|"]
    for r in rows:
        out.append("| " + " | ".join(r) + " |")
    return "\n".join(out) + "\n"


def fnum(v: float, digits: int = 0) -> str:
    return f"{v:,.{digits}f}".replace(",", " ")


# --------------------------------------------------------------------------- #


def label_of(r: dict) -> str:
    """One row per implementation, not per compiler profile."""
    name = r["lang"]
    v = r.get("variant") or ""
    if v and v not in ("scalar", "default"):
        return f"{name} ({v})"
    if r["cc"] not in ("node", "perl", "python3", "cargo", "ghc"):
        return f"{name} ({r['cc']})"
    return name


def sec_crosslang(d: pathlib.Path) -> str:
    out = []
    for upd in ("serial", "deferred"):
        # Class S only: the same run also times the SIMD targets, and a
        # vectorised diffusion pass in a scalar table would make class V look
        # like a language result.
        # Class S, and conformance tier A or B only. A fast-math build is a
        # different tier and belongs in the compiler section; ranking one
        # second in a language table would be comparing two different
        # simulations.
        rows = [r for r in load(d, f"A-crosslang-{upd}.jsonl")
                if r.get("status") == "ok" and r.get("class") == "S"
                and r.get("conformance_class") in ("A", "B")]
        if not rows:
            continue
        # The class S table compares implementations; the compiler axis has its
        # own section, so each implementation appears once, at its best profile.
        best_of: dict[str, dict] = {}
        for r in rows:
            k = label_of(r)
            if k not in best_of or r["ms_per_tick_median"] < best_of[k]["ms_per_tick_median"]:
                best_of[k] = r
        ranked = sorted(best_of.items(), key=lambda kv: kv[1]["ms_per_tick_median"])
        fastest = ranked[0][1]["ms_per_tick_median"]
        body = []
        for i, (name, r) in enumerate(ranked, 1):
            body.append([
                str(i), name, r.get("profile", "—"),
                r.get("conformance_class", "?"),
                f"{r['ms_per_tick_median']:.3f}",
                f"{r['ms_per_tick_median'] / fastest:.2f}×",
                spread_cell(r, "ms_per_tick_spread"),
                str(round(r["max_rss_kb"] / 1024)) if r.get("max_rss_kb") else "—",
            ])
        out.append(f"### §2 class S, `--update {upd}`\n")
        out.append(table(["#", "Language", "Profile", "Tier", "ms/tick", "rel.",
                          "spread", "RSS MiB"], body, "rlrcrrrr"))
        out.append(spread_note([r for _, r in ranked], "ms_per_tick_spread"))
        hashes = {(r["grid_hash"], r["agent_hash"])
                  for r in rows if r.get("conformance_class") == "A"}
        n_a = sum(1 for r in rows if r.get("conformance_class") == "A")
        if len(hashes) == 1:
            g, a = hashes.pop()
            out.append(f"\n{n_a} of {n_a} tier-A runs: `{g} / {a}` ✓\n\n")
        else:
            out.append(f"\n**{len(hashes)} different tier-A hashes** ✗ "
                       f"{sorted(hashes)}\n\n")
    return "".join(out)


def sec_footprint(d: pathlib.Path) -> str:
    rows = [r for r in load(d, "C-compiler-matrix.jsonl") if r.get("status") == "ok"]
    rows += [r for r in load(d, "A-crosslang-serial.jsonl")
             if r.get("status") == "ok" and r.get("class") == "S"]
    if not rows:
        return ""
    by: dict[str, dict] = {}
    for r in rows:
        k = label_of(r)
        cur = by.get(k)
        sz = r.get("stripped_bytes") or r.get("binary_bytes") or 0
        if sz and (cur is None or sz < (cur.get("stripped_bytes")
                                        or cur.get("binary_bytes") or 1 << 62)):
            by[k] = r
        by.setdefault(k, r)
    body = []
    for name, r in sorted(by.items(),
                          key=lambda kv: kv[1].get("stripped_bytes")
                          or kv[1].get("binary_bytes") or 0):
        sz = r.get("stripped_bytes") or r.get("binary_bytes")
        body.append([name,
                     fnum(sz / 1024) if sz else "— (interpretiert)",
                     str(round(r["max_rss_kb"] / 1024)) if r.get("max_rss_kb") else "—"])
    return ("### §9 Footprint\n"
            + table(["Language", "Binary KiB (stripped)", "RSS MiB"], body) + "\n")


def sec_compilers(d: pathlib.Path) -> str:
    rows = [r for r in load(d, "C-compiler-matrix.jsonl") if r.get("status") == "ok"]
    if not rows:
        return ""
    rows.sort(key=lambda r: r["ms_total_best"])
    best = rows[0]["ms_total_best"]
    body = [[r["lang"], r["cc"], r["profile"], r.get("conformance_class", "?"),
             fnum(r["ms_total_best"]), f"{r['ms_total_best'] / best:.2f}×",
             spread_cell(r),
             fnum((r.get("stripped_bytes") or r.get("binary_bytes") or 0) / 1024, 0)
             if (r.get("stripped_bytes") or r.get("binary_bytes")) else "—"]
            for r in rows]
    return ("### §3 compiler matrix, 1024×1024, 300 Ticks\n"
            + table(["Language", "Compiler", "Profile", "Tier", "ms", "rel.",
                     "spread", "Binary KiB"], body, "llrcrrrr")
            + spread_note(rows) + "\n")


def sec_parallel(d: pathlib.Path) -> str:
    rows = load(d, "P-parallel.jsonl")
    if not rows:
        return ""
    by = defaultdict(dict)
    for r in rows:
        v = r.get("variant") or ""
        if r["threads"] == 1:
            strat = "1"
        elif "binned" in v:
            strat = "binned"
        elif "private" in v:
            strat = "private"
        else:
            # Perl's reduction is neither: it is replicated across processes,
            # which is exactly the serial chain. See SPEC-1 5.6 and the header
            # of impl/perl/slimebench.pl.
            strat = "replicated"
        by[r["lang_label"]][(r["threads"], strat)] = r["ms_total"]

    threads = [1, 2, 4, 8, 16, 32]
    out = ["### §5 class P, thread sweep (ms)\n"]
    for strat in ("binned", "private", "replicated"):
        body = []
        for lang, d2 in by.items():
            base = d2.get((1, "1"))
            have = [d2.get((t, strat)) for t in threads if t > 1]
            if base is None or not any(v is not None for v in have):
                continue
            cells = [fnum(base)] + [fnum(d2[(t, strat)]) if (t, strat) in d2 else "—"
                                    for t in threads[1:]]
            bestv = min(v for v in have if v is not None)
            body.append([lang] + cells + [f"{base / bestv:.1f}×"])
        if body:
            out.append(f"\n**{strat}**\n")
            out.append(table(["Language"] + [f"T={t}" for t in threads] + ["Speedup"], body))
    return "".join(out) + "\n"


def sec_kernels(d: pathlib.Path) -> str:
    """The four-way diffusion-kernel comparison.

    Reported as ms_diffuse rather than ms_total: the agent pass is identical
    in all of them and would dilute the difference into invisibility.
    """
    rows = load(d, "V-asm-kernels.jsonl")
    if not rows:
        return ""
    names = {"no-simd": "scalar loop", "simd": "intrinsics",
             "asm": "hand-written assembly"}
    order = ["no-simd", "simd", "asm"]
    ccs = sorted({r["cc"] for r in rows})
    by = {(r["cc"], r["kernel"]): r for r in rows}

    preset = rows[0]["preset"]
    w = rows[0]["width"]
    body = []
    for k in order:
        cells = []
        for cc in ccs:
            r = by.get((cc, k))
            cells.append(fnum(r["ms_diffuse"], 1) if r else "—")
        # Speedup against the scalar loop of the same compiler, which is the
        # only comparison the row supports: the assembly is identical across
        # compilers by construction.
        rel = []
        for cc in ccs:
            base, cur = by.get((cc, "no-simd")), by.get((cc, k))
            rel.append(f"{base['ms_diffuse'] / cur['ms_diffuse']:.2f}×"
                       if base and cur else "—")
        body.append([names[k]] + cells + rel)

    hashes = {r["grid_hash"] for r in rows}
    note = ""
    if len(hashes) == 1:
        note = ("\nAll three kernels, both compilers, one grid hash: "
                f"`{hashes.pop()}`\n")
    return (f"### §6b diffusion kernels, `{preset}` {w}², diffusion pass only\n"
            + table(["Kernel"] + [f"{c} (ms)" for c in ccs] + [f"{c} rel." for c in ccs],
                    body)
            + note + "\n")


def sec_gil(d: pathlib.Path) -> str:
    """{GIL, no-GIL} x {threads, processes} x thread count.

    Everything else is held fixed -- same Worker, same phase order, same
    reduction, same host -- so a difference between two cells is attributable
    to the carrier and the interpreter and nothing else.
    """
    rows = load(d, "P-gil-matrix.jsonl")
    if not rows:
        return ""
    base = {r["interp"]: r["ms_total"] for r in rows if r["mp_backend"] == "serial"}
    if not base:
        return ""
    interps = [i for i in ("gil", "nogil") if i in base]
    names = {"gil": "3.12", "nogil": "3.14t"}
    threads = [2, 4, 8, 16]

    out = []
    preset = rows[0]["preset"]
    out.append(f"### §5b CPython, GIL against free-threading, `{preset}`\n")
    out.append("\nOne thread: "
               + ", ".join(f"{names[i]} {fnum(base[i])} ms" for i in interps)
               + ". The interpreters carry numpy 2.5.2 and 1.26.4 respectively, "
                 "so that pair is confounded and says nothing about what "
                 "free-threading costs.\n\n")

    for red in ("binned", "private"):
        cols, body = [], []
        for i in interps:
            for be in ("threads", "processes"):
                cols.append((i, be))
        for t in threads:
            cells = []
            for i, be in cols:
                m = [r for r in rows
                     if r["interp"] == i and r["mp_backend"] == be
                     and r["threads"] == t and red in (r.get("variant") or "")]
                cells.append(f"{fnum(m[0]['ms_total'])} ({base[i] / m[0]['ms_total']:.2f}×)"
                             if m else "—")
            body.append([f"T={t}"] + cells)
        if body:
            out.append(f"\n**{red}** — ms, with the speedup against the same "
                       "interpreter at one thread in brackets\n\n")
            be_en = {"threads": "threads", "processes": "processes"}
            out.append(table([""] + [f"{names[i]} {be_en[be]}" for i, be in cols], body))

    hashes = {(r["grid_hash"], r["agent_hash"]) for r in rows}
    if len(hashes) == 1:
        g, a = hashes.pop()
        out.append(f"\nAll {len(rows)} runs: grid `{g}`, agents `{a}`.\n")
    return "".join(out) + "\n"


def sec_gpu(d: pathlib.Path) -> str:
    rows = load(d, "H-gpu.jsonl")
    if not rows:
        return ""
    presets = ["tiny", "small", "medium", "large", "huge"]
    by = defaultdict(dict)
    for r in rows:
        by[r["lang_label"]][r["preset"]] = r
    body = []
    for lang, d2 in by.items():
        body.append([lang] + [fnum(d2[p]["ms_total"]) if p in d2 else "—" for p in presets])
        body.append([f"{lang} MCUPS"] +
                    [fnum(d2[p]["mcups"]) if p in d2 else "—" for p in presets])
    shaders = {r.get("shader_hash") for r in rows if r.get("shader_hash")}
    note = ""
    if len(shaders) == 1:
        note = f"\nShader-Hash in allen GL-Hosts identisch: `{shaders.pop()}`\n"
    return ("### §7 class G, every preset, 100 ticks (ms)\n"
            + table(["Host"] + presets, body) + note + "\n")


def sec_render(d: pathlib.Path) -> str:
    rows = load(d, "Q-render.jsonl")
    if not rows:
        return ""
    langs = ["c", "cpp", "haskell", "rust", "python", "perl"]
    by = defaultdict(dict)
    for r in rows:
        soft = "llvmpipe" in r.get("renderer", "")
        be = "sdl2" if r["backend"] in ("sdl2", "pygame") else "raylib"
        by[r["impl"]][(be, soft)] = r["ms_render_median"]
    body = []
    for lang in langs:
        d2 = by.get(lang)
        if not d2:
            continue
        body.append([lang] + [f"{d2[k]:.3f}" if k in d2 else "—"
                              for k in (("sdl2", True), ("sdl2", False),
                                        ("raylib", True), ("raylib", False))])
    return ("### §8 class R, 1024×1024, `--freeze-sim`\n"
            + table(["Language", "SDL2 llvmpipe", "SDL2 RTX 5080",
                     "raylib llvmpipe", "raylib RTX 5080"], body) + "\n")


def main() -> int:
    # The tables carry U+2713 and U+00D7; on a cp1252 console print() would
    # raise rather than transliterate.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    else:
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

    if len(sys.argv) != 2:
        print(__doc__.strip())
        return 2
    d = pathlib.Path(sys.argv[1])
    if not d.is_dir():
        print(f"error: {d} is not a directory", file=sys.stderr)
        return 1

    env = d / "environment.txt"
    if env.exists():
        print("```\n" + env.read_text(encoding="utf-8").rstrip() + "\n```\n")

    for fn in (sec_crosslang, sec_compilers, sec_parallel, sec_gil,
               sec_kernels, sec_gpu, sec_render, sec_footprint):
        s = fn(d)
        if s:
            print(s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
