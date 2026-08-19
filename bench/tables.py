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


def sec_crosslang(d: pathlib.Path) -> str:
    out = []
    for upd in ("serial", "deferred"):
        rows = [r for r in load(d, f"A-crosslang-{upd}.jsonl") if r.get("status") == "ok"]
        if not rows:
            continue
        rows.sort(key=lambda r: r["ms_per_tick_median"])
        best = rows[0]["ms_per_tick_median"]
        body = []
        for i, r in enumerate(rows, 1):
            name = r["lang"]
            qual = []
            if r.get("variant") and r["variant"] not in ("scalar", "default"):
                qual.append(r["variant"])
            if r["cc"] not in ("node", "cargo", "perl", "python3", "ghc"):
                qual.append(r["cc"])
            if r.get("profile") and r["profile"] != "default":
                qual.append(r["profile"])
            body.append([
                str(i), name, " ".join(qual) or "—",
                r.get("conformance_class", "?"),
                f"{r['ms_per_tick_median']:.3f}",
                f"{r['ms_per_tick_median'] / best:.2f}×",
                str(r.get("rss_kib", 0) // 1024) if r.get("rss_kib") else "—",
            ])
        out.append(f"### §2 class S, `--update {upd}`\n")
        out.append(table(["#", "Sprache", "Variante", "Konf.", "ms/Tick", "rel.", "RSS MiB"],
                         body, "rrlcrrr"))
        hashes = {(r["grid_hash"], r["agent_hash"])
                  for r in rows if r.get("conformance_class") == "A"}
        out.append(f"\nStufe-A-Hashes: {len(hashes)} verschiedene "
                   f"{'✓ (alle gleich)' if len(hashes) == 1 else '✗'} "
                   f"{sorted(hashes)[0] if hashes else ''}\n\n")
    return "".join(out)


def sec_compilers(d: pathlib.Path) -> str:
    rows = [r for r in load(d, "C-compiler-matrix.jsonl") if r.get("status") == "ok"]
    if not rows:
        return ""
    rows.sort(key=lambda r: r["ms_total_best"])
    best = rows[0]["ms_total_best"]
    body = [[r["lang"], r["cc"], r["profile"], r.get("conformance_class", "?"),
             fnum(r["ms_total_best"]), f"{r['ms_total_best'] / best:.2f}×",
             fnum(r.get("binary_bytes", 0) / 1024, 0) if r.get("binary_bytes") else "—"]
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

    for fn in (sec_crosslang, sec_compilers, sec_parallel, sec_gpu, sec_render):
        s = fn(d)
        if s:
            print(s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
