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

import json
import pathlib
import sys
from collections import defaultdict


def load(d: pathlib.Path, name: str) -> list[dict]:
    p = d / name
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines() if l.strip()]


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
        rows = [r for r in load(d, f"A-crosslang-{upd}.jsonl")
                if r.get("status") == "ok" and r.get("class") == "S"]
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
                str(round(r["max_rss_kb"] / 1024)) if r.get("max_rss_kb") else "—",
            ])
        out.append(f"### §2 class S, `--update {upd}`\n")
        out.append(table(["#", "Sprache", "Profil", "Konf.", "ms/Tick", "rel.", "RSS MiB"],
                         body, "rlrcrrr"))
        hashes = {(r["grid_hash"], r["agent_hash"])
                  for r in rows if r.get("conformance_class") == "A"}
        n_a = sum(1 for r in rows if r.get("conformance_class") == "A")
        if len(hashes) == 1:
            g, a = hashes.pop()
            out.append(f"\n{n_a}/{n_a} Stufe-A-Läufe: `{g} / {a}` ✓\n\n")
        else:
            out.append(f"\n**{len(hashes)} verschiedene Stufe-A-Hashes** ✗ "
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
                     str(round(r["max_rss_kb"] / 1024)) if r.get("max_rss_kb") else "—",
                     f"{r.get('build_seconds', 0):.1f}" if r.get("build_seconds") else "—"])
    return ("### §9 Footprint\n"
            + table(["Sprache", "Binär KiB (gestrippt)", "RSS MiB", "Build s"], body) + "\n")


def sec_compilers(d: pathlib.Path) -> str:
    rows = [r for r in load(d, "C-compiler-matrix.jsonl") if r.get("status") == "ok"]
    if not rows:
        return ""
    rows.sort(key=lambda r: r["ms_total_best"])
    best = rows[0]["ms_total_best"]
    body = [[r["lang"], r["cc"], r["profile"], r.get("conformance_class", "?"),
             fnum(r["ms_total_best"]), f"{r['ms_total_best'] / best:.2f}×",
             fnum((r.get("stripped_bytes") or r.get("binary_bytes") or 0) / 1024, 0)
             if (r.get("stripped_bytes") or r.get("binary_bytes")) else "—"]
            for r in rows]
    return ("### §3 compiler matrix, 1024×1024, 300 Ticks\n"
            + table(["Sprache", "Compiler", "Profil", "Konf.", "ms", "rel.", "Binär KiB"],
                    body, "llrcrrr") + "\n")


def sec_parallel(d: pathlib.Path) -> str:
    rows = load(d, "P-parallel.jsonl")
    if not rows:
        return ""
    by = defaultdict(dict)
    for r in rows:
        v = r.get("variant") or ""
        strat = "binned" if "binned" in v else ("private" if "private" in v else "—")
        if r["threads"] == 1:
            strat = "1"
        by[r["lang_label"]][(r["threads"], strat)] = r["ms_total"]

    out = ["### §5 class P, Thread-Sweep\n"]
    threads = [1, 2, 4, 8, 16, 32]
    for strat in ("binned", "private", "—"):
        body = []
        for lang, d2 in by.items():
            base = d2.get((1, "1"))
            if base is None:
                continue
            cells = []
            have = False
            for t in threads:
                v = base if t == 1 else d2.get((t, strat))
                if v is None:
                    cells.append("—")
                else:
                    have = True
                    cells.append(fnum(v))
            if have:
                bestv = min((d2.get((t, strat), 1e18) for t in threads if t > 1),
                            default=None)
                body.append([lang] + cells +
                            [f"{base / bestv:.1f}×" if bestv and bestv < 1e17 else "—"])
        if body:
            out.append(f"\n**{strat}**\n")
            out.append(table(["Sprache"] + [f"T={t}" for t in threads] + ["Speedup"], body))
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
    return ("### §7 class G, alle Presets, 100 Ticks\n"
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
            + table(["Sprache", "SDL2 llvmpipe", "SDL2 RTX 5080",
                     "raylib llvmpipe", "raylib RTX 5080"], body) + "\n")


def main() -> int:
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

    for fn in (sec_crosslang, sec_compilers, sec_parallel, sec_gpu,
               sec_render, sec_footprint):
        s = fn(d)
        if s:
            print(s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
