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
import re
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


def kib(r: dict) -> str:
    """A binary's size in KiB, or an em dash when it does not have one.

    Rounding to whole KiB turns anything under 512 bytes into "0", and no
    binary is 0 KiB -- for the runtimes that ship IL or class files rather
    than an executable, the honest cell is empty.
    """
    sz = r.get("stripped_bytes") or r.get("binary_bytes")
    if not sz or sz < 1024:
        return "—"
    return fnum(sz / 1024, 0)


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
        body.append([name,
                     kib(r),
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
             kib(r)]
            for r in rows]
    return ("### §3 compiler matrix, 1024×1024, 300 ticks\n"
            + table(["Language", "Compiler", "Profile", "Tier", "ms", "rel.",
                     "spread", "Binary KiB"], body, "llrcrrrr")
            + spread_note(rows) + "\n")


PLABEL = {
    "c": "C", "cpp": "C++", "rust": "Rust", "haskell": "Haskell",
    "ts": "TypeScript", "python": "Python", "go": "Go", "swift": "Swift",
    "java": "Java", "csharp": "C#", "fortran": "Fortran", "perl": "Perl",
}


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
        elif "openmp" in v:
            # Fortran has one strategy rather than two: an atomic add. It is
            # bit-exact for any thread count because SPEC-1's deposit is a
            # constant, so the order in which threads apply it to a cell
            # cannot change the sum. Neither binned nor private applies.
            strat = "atomic"
        else:
            # Perl's reduction is none of those: it is replicated across
            # processes, which is exactly the serial chain. See SPEC-1 5.6 and
            # the header of impl/perl/slimebench.pl.
            strat = "replicated"
        by[r["lang_label"]][(r["threads"], strat)] = r["ms_total"]

    threads = [1, 2, 4, 8, 16, 32]
    # The sweep is a ranking of how well each language scales, so it is sorted
    # like one. Unsorted, in the order the run happened to emit them, the
    # column that carries the finding is the one the reader has to sort by eye.
    out = ["### §5 class P, thread sweep (ms)\n"]
    for strat in ("binned", "private", "atomic", "replicated"):
        body = []
        for lang, d2 in by.items():
            base = d2.get((1, "1"))
            have = [d2.get((t, strat)) for t in threads if t > 1]
            if base is None or not any(v is not None for v in have):
                continue
            cells = [fnum(base)] + [fnum(d2[(t, strat)]) if (t, strat) in d2 else "—"
                                    for t in threads[1:]]
            bestv = min(v for v in have if v is not None)
            body.append([PLABEL.get(lang, lang)] + cells
                        + [f"{base / bestv:.1f}×", base / bestv])
        body.sort(key=lambda r: -r[-1])
        for r in body:
            r.pop()
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
        note = f"\nOne shader hash across every GL host: `{shaders.pop()}`\n"
    return ("### §7 class G, every preset, 100 ticks (ms)\n"
            + table(["Host"] + presets, body) + note + "\n")


RLABEL = {
    "c": "C", "cpp": "C++", "haskell": "Haskell", "rust": "Rust",
    "python": "Python", "perl": "Perl",
}


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
    # How each language reaches the two C libraries is the point of this
    # table -- the numbers alone do not say whether a row went through a
    # binding or straight at the header. Static, because it is a fact about
    # the ports rather than about the run.
    binding = {
        "c": "direct", "cpp": "direct",
        "haskell": "`sdl2` / `foreign import`",
        "rust": "`sdl2` / `raylib` crate",
        "python": "pygame / cffi", "perl": "FFI::Platypus",
    }
    body = []
    for lang in langs:
        d2 = by.get(lang)
        if not d2:
            continue
        body.append([RLABEL.get(lang, lang), binding.get(lang, "—")]
                    + [f"{d2[k]:.3f}" if k in d2 else "—"
                       for k in (("sdl2", True), ("sdl2", False),
                                 ("raylib", True), ("raylib", False))])
    return ("### §8 class R, 1024×1024, `--freeze-sim`\n"
            + table(["Language", "Binding", "SDL2 llvmpipe", "SDL2 RTX 5080",
                     "raylib llvmpipe", "raylib RTX 5080"], body) + "\n")


# How each row reaches the vector unit. Derived where the run records it
# (`variant` carries the instruction set or the portable width) and named here
# where it does not -- the difference between "Native AOT told to target this
# machine" and "Native AOT at its default" is a build flag, not a field.
VLABEL = {
    ("c-simd", "o3-native"): ("C, `-O3 -march=native`", "AVX-512 intrinsics"),
    ("cpp-simd", "o3-native"): ("C++, `-O3 -march=native`", "AVX-512 intrinsics"),
    ("c-simd", "o3-v3"): ("C, `-O3 -mavx2`", "AVX2 intrinsics"),
    ("cpp-simd", "o3-v3"): ("C++, `-O3 -mavx2`", "AVX2 intrinsics"),
    ("rust-simd", "release-native"): ("Rust, safe", "AVX-512 intrinsics"),
    ("rust-simd", "release-native-unchecked"): ("Rust, unchecked",
                                                "AVX-512 intrinsics"),
    ("csharp-simd", "aot-native"): ("C#, Native AOT + `IlcInstructionSet=native`",
                                    "`Vector512<float>`"),
    ("csharp-simd", "tier1"): ("C#, JIT", "`Vector512<float>`"),
    ("csharp-simd", "aot"): ("C#, Native AOT, default",
                             "`Vector512` unavailable, 128-bit"),
    ("csharp-simd-portable", "aot"): ("C#, `--simd-portable`",
                                      "`Vector<float>`, 128-bit"),
    ("java-simd", "default"): ("Java, tiered", "Vector API, 512-bit"),
    ("java-simd", "c2"): ("Java, C2 only", "Vector API, 512-bit"),
}


def sec_simd(d: pathlib.Path) -> str:
    """Class V, ranked on the diffusion pass.

    The agent pass is identical in every one of these builds and dilutes the
    difference, so the ranking column is ms_diffuse -- and the spread beside it
    is ms_diffuse's own, across the same repetitions. It used to be absent,
    because the phase timings were taken from whichever repetition won on
    ms_total rather than measured across all of them.
    """
    rows = [r for r in load(d, "G-simd.jsonl") if r.get("ms_diffuse")]
    if not rows:
        return ""
    best: dict[tuple, dict] = {}
    for r in rows:
        k = (r["target"], r.get("profile"))
        if k not in best or r["ms_diffuse"] < best[k]["ms_diffuse"]:
            best[k] = r
    ranked = sorted(best.items(), key=lambda kv: kv[1]["ms_diffuse"])
    ranked_rows = [r for _, r in ranked]
    base = ranked[0][1]["ms_diffuse"]
    body = []
    for k, r in ranked:
        label, vec = VLABEL.get(k, (f"{k[0]} {k[1]}", r.get("variant") or "—"))
        body.append([label, vec, f"{r['ms_diffuse']:.1f}",
                     spread_cell(r, "ms_diffuse_spread"),
                     f"{r['ms_diffuse'] / base:.2f}×"])
    one = {r["grid_hash"] for r in rows}
    note = (f"\nAll {len(rows)} runs across {len(best)} configurations, one grid "
            f"hash: `{one.pop()}`\n" if len(one) == 1 else "")
    w, t = rows[0]["width"], rows[0]["ticks"]
    return (f"### §6c class V, {w}×{w}, {t} ticks, diffusion pass only\n"
            + table(["Target", "Vector", "diffuse ms", "spread", "vs best"],
                    body)
            + spread_note(ranked_rows, "ms_diffuse_spread")
            + note + "\n")


# ---------------------------------------------------------------------------
# The four phases driven by shell scripts rather than by bench/run.py. They
# used to produce column-aligned text and nothing else, so their tables were
# transcribed into the document by hand. They now write a .jsonl beside the
# .txt -- see bench/jsonl.sh -- and these read it.


def rows_of(d: pathlib.Path, fn: str, table: str) -> list[dict]:
    return [r for r in load(d, fn) if r.get("table") == table]


def sec_gc(d: pathlib.Path) -> str:
    """What each collected runtime's collector did. Mostly: nothing."""
    rows = rows_of(d, "S-gc-stats.jsonl", "gc")
    if not rows:
        return ""
    by = {r["lang"]: r for r in rows}

    def cell(lang: str) -> list[str] | None:
        r = by.get(lang)
        if not r:
            return None
        if lang == "go":
            return ["Go", str(r.get("collections", "—")),
                    f"{r.get('gc_ms', 0):.2f} ms",
                    f"{r.get('allocated_mib', 0)} MiB, "
                    f"{r.get('mallocs', 0)} mallocs"]
        if lang == "java":
            return ["**Java**", f"**{r.get('collections', '—')}**",
                    f"{r.get('gc_ms', 0):.0f} ms", "—"]
        if lang == "csharp":
            c = str(r.get("collections", "—")).split("/")
            gens = " / ".join(f"{n} gen{i}" for i, n in enumerate(c))
            return ["C#", gens, "—", f"{r.get('allocated_mib', 0)} MiB"]
        if lang == "ocaml":
            return ["OCaml",
                    f"{r.get('minor_collections', 0)} minor, "
                    f"{r.get('major_collections', 0)} major", "—",
                    f"{r.get('minor_words', 0) * 8 / 1048576:.1f} MiB "
                    f"of minor words"]
        if lang == "haskell":
            return ["Haskell", "—",
                    f"{r.get('gc_seconds', 0):.3f} s of "
                    f"{r.get('total_seconds', 0):.3f}",
                    f"{r.get('allocated_bytes', 0) / 1048576:.1f} MiB"]
        return None

    body = [c for c in (cell(k) for k in
                        ("java", "go", "csharp", "haskell", "ocaml")) if c]
    return ("### §11 garbage collection, `tiny`, 200 ticks\n"
            + table(["runtime", "collections", "GC time",
                     "allocated over the whole run"], body, "lrrr") + "\n")


def sec_barriers(d: pathlib.Path) -> str:
    """Work against barrier wait, per phase, for the C reference."""
    rows = [r for r in rows_of(d, "P-barriers.jsonl", "barrier-phase")
            if r.get("lang") == "c"]
    if not rows:
        return ""
    order = ["agents", "prefix", "scatter", "deposit", "merge", "diffuse"]
    rows.sort(key=lambda r: order.index(r["phase"])
              if r["phase"] in order else 99)
    body = []
    for r in rows:
        w, b = r["work"], r["barrier"]
        # The diffusion pass ends the tick, so there is no barrier after it.
        bar = "—" if r["phase"] == "diffuse" else f"{b:.3f}"
        body.append([r["phase"],
                     f"**{w:.3f}**" if r["phase"] == "prefix" else f"{w:.3f}",
                     bar, f"{w + b:.3f}"])
    return ("### §5 work and barrier per phase, C, `medium`, T=32\n"
            + table(["Phase", "work", "barrier", "total"], body, "lrrr")
            + "\n")


def sec_ramp(d: pathlib.Path) -> str:
    """The cold-start ramp, both runtimes in one table.

    Two scripts measure it -- the JVM's halves in jvm-warmup, .NET's three in
    dotnet-aot -- and the document has always shown them side by side. They
    are joined here on the block label rather than by hand.
    """
    jv = {r["block"]: r for r in rows_of(d, "S-jvm-warmup.jsonl", "ramp")}
    dn = {r["block"]: r for r in rows_of(d, "S-dotnet-aot.jsonl", "ramp-dotnet")}
    if not jv or not dn:
        return ""
    # The two scripts label their last block differently (the JVM runs to 400
    # ticks, .NET to 300) and their ratio rows differently again.
    pairs = [("1-5", "1-5"), ("6-10", "6-10"), ("11-25", "11-25"),
             ("26-50", "26-50"), ("51-100", "51-100"),
             ("200-400", "200-300"), ("first tick", "first tick"),
             ("best tick", "best tick"), ("first / best", "first/best")]
    show = {"200-400": "201+", "first tick": "**first tick**",
            "first / best": "**first / best**"}
    body = []
    for jk, dk in pairs:
        a, b = jv.get(jk), dn.get(dk)
        if not a or not b:
            continue
        suffix = "×" if jk == "first / best" else ""
        vals = [a["java_tiered"], a["java_c2"],
                b["csharp_jit"], b["csharp_tier1"], b["csharp_aot"]]
        fmt = [f"{v:.1f}{suffix}" if suffix else f"{v:.3f}" for v in vals]
        if jk in ("first tick", "first / best"):
            fmt = [f"**{v}**" for v in fmt]
        body.append([show.get(jk, jk)] + fmt)
    return ("### §6 the cold-start ramp, ms per tick\n"
            + table(["ticks", "Java tiered", "Java C2-only", "C# jit",
                     "C# tier1", "**C# aot**"], body) + "\n")


def sec_interpreters(d: pathlib.Path) -> str:
    """Two interpreters and three compiled paths, same algorithm."""
    rows = rows_of(d, "S-jvm-warmup.jsonl", "interpreters")
    if not rows:
        return ""
    rows.sort(key=lambda r: r["ms_per_tick"])
    base = min(r["ms_per_tick"] for r in rows
               if r["runtime"].startswith("c gcc")) or rows[0]["ms_per_tick"]
    body = []
    for r in rows:
        v = r["ms_per_tick"]
        loud = v / base > 10
        name = f"**{r['runtime']}**" if loud else r["runtime"]
        val = f"**{v:.4f}**" if loud else f"{v:.4f}"
        rel = f"**{v / base:.0f}×**" if loud else f"{v / base:.2f}×"
        sp = r.get("spread")
        body.append([name, val, "—" if sp is None else f"{sp * 100:.1f}%", rel])
    return ("### §6 two interpreters and three compiled paths\n"
            + table(["Runtime", "ms/tick", "spread", "vs C"], body, "lrrr")
            + "\n")


def sec_ship(d: pathlib.Path) -> str:
    """What each .NET configuration costs to publish and to start."""
    rows = rows_of(d, "S-dotnet-aot.jsonl", "ship")
    if not rows:
        return ""
    name = {"jit": "C# jit", "tier1": "C# tier1", "r2r": "C# ReadyToRun",
            "aot": "**C# Native AOT**"}
    body = []
    for r in rows:
        n = name.get(r["profile"], r["profile"])
        sz, st = r.get("size", "—"), r.get("start_ms", 0)
        if r["profile"] == "aot":
            sz, st = f"**{sz}**", f"**{st} ms**"
        else:
            st = f"{st} ms"
        body.append([n, sz, st])
    return ("### §6 what each configuration costs to ship\n"
            + table(["Configuration", "published", "start-up"], body, "lrr")
            + "\n")


def sec_branchy(d: pathlib.Path) -> str:
    """The agent pass, which has branches, against the stencil, which does not."""
    rows = rows_of(d, "S-dotnet-aot.jsonl", "branchy")
    if not rows:
        return ""
    name = {"tier1": "JIT, tier-1", "aot": "Native AOT, default",
            "aot-native": "Native AOT, `IlcInstructionSet=native`"}
    best = min(r["ms_agents"] for r in rows)
    body = []
    for r in rows:
        a = f"**{r['ms_agents']:.2f}**" if r["ms_agents"] == best \
            else f"{r['ms_agents']:.2f}"
        body.append([name.get(r["profile"], r["profile"]), a,
                     f"{r['spread'] * 100:.1f} %", f"{r['ms_diffuse']:.2f}"])
    return ("### §6 straight-line code against branchy code\n"
            + table(["configuration", "agent pass, ms", "spread",
                     "stencil, ms"], body, "lrrr") + "\n")


# The agent pass, four ways. Two changes that attack the same bottleneck from
# opposite ends -- fewer instructions, and shorter distances between the
# addresses those instructions touch -- so they are reported together, and
# separately, at four grid sizes.
AGENT_VARIANTS = [
    ("c", "scalar"),
    ("c-tiled", "+ tiles"),
    ("c-simd-agents", "+ simd"),
    ("c-simd-agents-tiled", "both"),
]


def _agent_grid(d: pathlib.Path) -> tuple[list[str], dict]:
    rows = load(d, "G-agents.jsonl")
    by: dict = {}
    presets: list[str] = []
    for r in rows:
        if r.get("status", "ok") != "ok":
            continue
        pre = r["preset"]
        if pre not in presets:
            presets.append(pre)
        k = (pre, r["target"])
        if k not in by or r["ms_agents"] < by[k]["ms_agents"]:
            by[k] = r
    # tiny before large, whatever order the run emitted them in.
    order = ["tiny", "small", "medium", "large", "huge"]
    presets.sort(key=lambda x: order.index(x) if x in order else 99)
    return presets, by


def _agent_table(d: pathlib.Path, field: str, heading: str) -> str:
    presets, by = _agent_grid(d)
    if not by:
        return ""
    body = []
    for pre in presets:
        got = [by.get((pre, t)) for t, _ in AGENT_VARIANTS]
        if not got[0]:
            continue
        ref = got[0]
        mib = ref["width"] * ref["height"] * 4 / 1048576
        vals = [r[field] if r else None for r in got]
        best = min(v for v in vals if v is not None)
        cells = []
        for v in vals:
            if v is None:
                cells.append("—")
            elif v == best and best != vals[0]:
                cells.append(f"**{v:.1f}**")
            else:
                cells.append(f"{v:.1f}")
        body.append([pre, f"{mib:.0f} MiB"] + cells
                    + [f"{vals[0] / best:.2f}×"])
    return (heading + "\n"
            + table(["preset", "grid"] + [n for _, n in AGENT_VARIANTS]
                    + ["best"], body, "lrrrrrr") + "\n")


def sec_agents(d: pathlib.Path) -> str:
    """Class V, the agent pass -- the phase itself."""
    return _agent_table(
        d, "ms_agents",
        "### §6d class V, the agent pass, ms in the agent phase")


def sec_agents_total(d: pathlib.Path) -> str:
    """The same runs, whole program.

    Separate from the phase table because the two disagree, and that is the
    finding: on a grid that fits in cache the sort costs more than the
    locality saves, so the phase improves and the program does not.
    """
    return _agent_table(
        d, "ms_total_best",
        "### §6d class V, the same runs, ms for the whole program")


# The ordering ported to two more languages, at one size. Pairs, because the
# question is what the change is worth in each language rather than which
# language is fastest -- the second is what class S is for.
AGENT_LANGS = [
    ("C", "c", "c-tiled"),
    ("C++", "cpp", "cpp-tiled"),
    ("Rust", "rust", "rust-tiled"),
    ("Go", "go", "go-tiled"),
    ("Java", "java", "java-tiled"),
    ("C#", "csharp", "csharp-tiled"),
    ("Swift", "swift", "swift-tiled"),
    ("Haskell", "haskell", "haskell-tiled"),
]


def sec_agents_langs(d: pathlib.Path) -> str:
    """Spatial ordering in three languages, `medium`."""
    rows = [r for r in load(d, "G-agents.jsonl")
            if r.get("status", "ok") == "ok" and r.get("preset") == "medium"]
    if not rows:
        return ""
    by: dict = {}
    for r in rows:
        k = r["target"]
        if k not in by or r["ms_agents"] < by[k]["ms_agents"]:
            by[k] = r
    body = []
    for name, plain, tiled in AGENT_LANGS:
        a, b = by.get(plain), by.get(tiled)
        if not a or not b:
            continue
        body.append([name, f"{a['ms_agents']:.1f}", f"{b['ms_agents']:.1f}",
                     f"**{a['ms_agents'] / b['ms_agents']:.2f}×**",
                     f"{a['ms_total_best']:.1f}", f"{b['ms_total_best']:.1f}",
                     f"{a['ms_total_best'] / b['ms_total_best']:.2f}×"])
    if not body:
        return ""
    return ("### §6d spatial ordering in three languages, `medium`\n"
            + table(["Language", "agents", "agents, ordered", "phase",
                     "total", "total, ordered", "program"], body, "lrrrrrr")
            + "\n")


# ---------------------------------------------------------------------------
# Managed tables
#
# Half of docs/RESULTS.md used to be generated and half typed in by hand, and
# the file said all of it was generated. The hand-kept half drifted every time
# a series was replaced -- silently, because nothing compared the document to
# the data.
#
# So each generated table is claimed by an id, the document marks where it
# goes, and `--check` fails when the two disagree. Adding a generator means
# adding one line here and one marker pair in the document; nothing else has
# to remember.
#
# The ids per section are positional: a section's tables in the order the
# generator emits them.
MANAGED: list[tuple[str, list[str]]] = [
    ("sec_crosslang", ["s-serial", "s-deferred"]),
    ("sec_compilers", ["compilers"]),
    ("sec_parallel", ["p-binned", "p-private", "p-atomic", "p-replicated"]),
    ("sec_gil", ["gil-binned", "gil-private"]),
    ("sec_simd", ["simd"]),
    ("sec_agents", ["agent-pass"]),
    ("sec_agents_total", ["agent-total"]),
    ("sec_agents_langs", ["agent-langs"]),
    ("sec_gpu", ["gpu"]),
    ("sec_render", ["render"]),
    ("sec_footprint", ["footprint"]),
    ("sec_gc", ["gc"]),
    ("sec_barriers", ["barrier-phase"]),
    ("sec_ramp", ["ramp"]),
    ("sec_interpreters", ["interpreters"]),
    ("sec_ship", ["ship"]),
    ("sec_branchy", ["branchy"]),
]

OPEN = "<!-- sb:table {} -->"
CLOSE = "<!-- /sb:table -->"


def split_tables(text: str) -> list[str]:
    """Every markdown table in a block of generated output, in order."""
    lines = text.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        if lines[i].startswith("|"):
            j = i
            while j < len(lines) and lines[j].startswith("|"):
                j += 1
            out.append("\n".join(lines[i:j]))
            i = j
        else:
            i += 1
    return out


def managed_tables(d: pathlib.Path) -> dict[str, str]:
    found: dict[str, str] = {}
    for fname, ids in MANAGED:
        tables = split_tables(globals()[fname](d))
        for n, tid in enumerate(ids):
            if n < len(tables):
                found[tid] = tables[n]
    return found


def named_series(text: str) -> str | None:
    """The series directory the document's header claims every number is from."""
    m = re.search(r"\(\.\./(results/run-[0-9-]+)/\)", text)
    return m.group(1) if m else None


def apply_to_doc(doc: pathlib.Path, d: pathlib.Path,
                 write: bool) -> tuple[int, list[str]]:
    """Replace or verify every marked table. Returns (changed, problems)."""
    text = doc.read_text(encoding="utf-8")
    tables = managed_tables(d)
    problems: list[str] = []
    changed = 0

    # Tables from one series under a header naming another is the exact
    # failure the one-run rule exists to stop, and checking against an
    # explicitly named directory cannot see it -- CI derives the name from the
    # document, but a local run does not. So the two are compared here.
    named = named_series(text)
    want = d.as_posix().rstrip("/")
    if named and not want.endswith(named):
        problems.append(f"the document's header names {named}, "
                        f"but these tables are from {want}")
    for tid, new in sorted(tables.items()):
        start = OPEN.format(tid)
        i = text.find(start)
        if i < 0:
            problems.append(f"{tid}: no marker in {doc}")
            continue
        j = text.find(CLOSE, i)
        if j < 0:
            problems.append(f"{tid}: marker never closed")
            continue
        cur = text[i + len(start):j].strip("\n")
        if cur == new:
            continue
        changed += 1
        if write:
            text = text[:i + len(start)] + "\n" + new + "\n" + text[j:]
        else:
            problems.append(f"{tid}: table in {doc} differs from the series")
    # A marker with no generator behind it is the same failure in reverse.
    for tid in [m.split()[2] for m in
                [text[k:text.find("-->", k) + 3]
                 for k in range(len(text)) if text.startswith("<!-- sb:table ", k)]]:
        if tid not in tables:
            problems.append(f"{tid}: marked in {doc} but no generator claims it")
    if write and changed:
        doc.write_text(text, encoding="utf-8", newline="\n")
    return changed, problems


def main() -> int:
    # The tables carry U+2713 and U+00D7; on a cp1252 console print() would
    # raise rather than transliterate.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    else:
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

    argv = sys.argv[1:]
    mode = ""
    if argv and argv[0] in ("--write", "--check"):
        mode, argv = argv[0], argv[1:]
    if mode and len(argv) != 2:
        print(f"usage: tables.py {mode} docs/RESULTS.md results/run-...")
        return 2
    if not mode and len(argv) != 1:
        print(__doc__.strip())
        return 2
    if mode:
        doc = pathlib.Path(argv[0])
        d = pathlib.Path(argv[1])
        if not d.is_dir():
            print(f"error: {d} is not a directory", file=sys.stderr)
            return 1
        changed, problems = apply_to_doc(doc, d, write=(mode == "--write"))
        for m in problems:
            print(f"  {m}")
        if mode == "--write":
            print(f"{changed} table(s) updated in {doc}")
            return 1 if problems else 0
        if changed or problems:
            print(f"{changed} table(s) in {doc} do not match {d}.")
            print("run: bench/tables.py --write docs/RESULTS.md " + str(d))
            return 1
        print(f"{doc}: every managed table matches {d}")
        return 0
    d = pathlib.Path(argv[0])
    if not d.is_dir():
        print(f"error: {d} is not a directory", file=sys.stderr)
        return 1

    env = d / "environment.txt"
    if env.exists():
        print("```\n" + env.read_text(encoding="utf-8").rstrip() + "\n```\n")

    for fn in (sec_crosslang, sec_compilers, sec_parallel, sec_gil,
               sec_kernels, sec_simd, sec_agents, sec_agents_total,
               sec_agents_langs,
               sec_gpu, sec_render, sec_footprint,
               sec_gc, sec_barriers, sec_ramp, sec_interpreters,
               sec_ship, sec_branchy):
        s = fn(d)
        if s:
            print(s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
