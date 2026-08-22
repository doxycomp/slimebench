#!/usr/bin/env python3
"""What a planned run will cost, priced from a run that already happened.

`bench/full-run.sh --dry-run` calls this. It answers the question that comes
up before every long measurement -- "how long will this take, and is
`thorough` affordable tonight?" -- without a table of constants that would be
wrong on anyone else's machine.

The method: take the newest series in results/, read how long each phase
actually measured for, divide by the repetition count that series used, and
multiply by the one being planned. Phases that do not repeat (the GPU sweep,
class R, the four .txt phases) are carried across unscaled.

Wall clock is not the sum of the measurements. Builds, warm-up ticks and
process start-up were 32 % of the last full run, and a plan has to pay for
them too, so the measured total is scaled by the overhead ratio the reference
series recorded in run.json. Without that file the ratio is unknown and the
estimate says so rather than inventing one.

    bench/estimate.py --reps 5 --p-reps 5
    bench/estimate.py --reps 3 --p-reps 3 --series results/run-20260822-0311
"""
from __future__ import annotations

import argparse
import io
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Which result file each phase writes, and whether its rows were repeated.
# `reps` phases scale with --reps, `p_reps` with --p-reps, and the rest are
# measured once however long the run is.
PHASES = [
    ("class S, serial", "A-crosslang-serial.jsonl", "reps"),
    ("class S, deferred", "A-crosslang-deferred.jsonl", "reps"),
    ("compiler matrix", "C-compiler-matrix.jsonl", "reps"),
    ("Haskell style", "M-haskell-style.jsonl", "reps"),
    ("class V, SIMD", "G-simd.jsonl", "reps"),
    ("class P, thread sweep", "P-parallel.jsonl", "p_reps"),
    ("CPython GIL matrix", "P-gil-matrix.jsonl", "once"),
    ("class G, GPU", "H-gpu.jsonl", "once"),
    ("class R, rendering", "Q-render.jsonl", "once"),
    ("assembly kernels", "V-asm-kernels.jsonl", "reps"),
]


def newest_series() -> pathlib.Path | None:
    runs = sorted((ROOT / "results").glob("run-*"))
    return runs[-1] if runs else None


def phase_cost(path: pathlib.Path) -> tuple[float, int, int]:
    """(measured seconds, rows, repetitions per row) for one result file."""
    if not path.exists():
        return 0.0, 0, 1
    ms = 0.0
    rows = 0
    reps = 1
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        d = json.loads(line)
        rows += 1
        r = d.get("ms_total_reps")
        if r:
            ms += sum(r)
            reps = max(reps, len(r))
        else:
            ms += d.get("ms_total") or 0.0
    return ms / 1000.0, rows, reps


def main() -> int:
    if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--p-reps", type=int, default=3)
    ap.add_argument("--profile", default="standard")
    ap.add_argument("--series", default=None,
                    help="reference series; default is the newest in results/")
    a = ap.parse_args()

    ref = pathlib.Path(a.series) if a.series else newest_series()
    if ref is None or not ref.is_dir():
        print("no series in results/ to price a plan from.", file=sys.stderr)
        print("run bench/full-run.sh --profile quick once, then ask again.",
              file=sys.stderr)
        return 1

    print(f"plan:      profile {a.profile}, reps {a.reps}, class P {a.p_reps}")
    print(f"priced on: {ref}")
    print()
    print(f"  {'phase':<24} {'rows':>5} {'ref reps':>9} {'plan reps':>10} {'est':>9}")
    total = 0.0
    for name, fn, kind in PHASES:
        secs, rows, ref_reps = phase_cost(ref / fn)
        if rows == 0:
            continue
        want = {"reps": a.reps, "p_reps": a.p_reps}.get(kind, ref_reps)
        est = secs / ref_reps * want
        total += est
        print(f"  {name:<24} {rows:>5} {ref_reps:>9} {want:>10} {est / 60:>7.1f} m")

    # The phases driven by the four .txt scripts are not in any jsonl. They are
    # part of the wall clock the reference series recorded, so they arrive in
    # the overhead ratio rather than as a line of their own.
    meta = ref / "run.json"
    if meta.exists():
        wall = json.loads(meta.read_text(encoding="utf-8")).get("wall_seconds")
    else:
        wall = None
    ref_total = sum(phase_cost(ref / fn)[0] for _, fn, _ in PHASES)

    print(f"  {'':<24} {'':>5} {'':>9} {'measured':>10} {total / 60:>7.1f} m")
    if wall and ref_total > 0:
        overhead = wall / ref_total
        print(f"  {'':<24} {'':>5} {'':>9} {'x overhead':>10} {overhead:>7.2f}")
        print()
        print(f"estimated wall clock: {total * overhead / 60:.0f} min")
    else:
        print()
        print(f"estimated measuring time: {total / 60:.0f} min")
        print("builds, warm-up and process start-up are on top of that, and the")
        print(f"reference series has no run.json to say how much -- on the run")
        print("this was written against they were about a third again.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
