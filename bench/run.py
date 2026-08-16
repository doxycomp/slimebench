#!/usr/bin/env python3
"""slimebench benchmark harness.

    bench/run.py list
    bench/run.py bench --preset small --reps 3
    bench/run.py bench --preset medium --targets c --compilers gcc,clang
    bench/run.py conformance
    bench/run.py conformance --write        # (re)generate spec/testvectors
    bench/run.py report results/*.jsonl

Measures wall time and peak RSS per process via os.wait4(), so no external
`time(1)` dependency and no cumulative-rusage confusion.

Build times and binary sizes are measured here rather than inside the
implementations -- an implementation must not be able to flatter its own
footprint.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import shlex
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
import time
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"
TESTVECTORS = ROOT / "spec" / "testvectors" / "SPEC-1.json"

# Conformance matrix.
#
# Cases carry explicit dimensions rather than preset names so that the slow
# interpreted targets have something they can actually finish: `micro` runs in
# milliseconds even in pure Python, while the compiled targets also verify the
# larger sizes where cache behaviour and index wrapping differ.
CONFORMANCE_SIZES = {
    "micro": ["--width", "128", "--height", "128", "--agents", "4096"],
    "tiny": ["--preset", "tiny"],
    "small": ["--preset", "small"],
}
CONFORMANCE_TICKS = {
    "micro": [1, 10, 100],
    "tiny": [1, 10, 100, 1000],
    "small": [1, 10, 100],
}
# Which sizes a target runs, by its declared conformance_set.
CONFORMANCE_SETS = {
    "micro": ["micro"],
    "full": ["micro", "tiny", "small"],
}
UPDATE_MODES = ["serial", "deferred"]

REFERENCE_TARGET = "c"
REFERENCE_CC = "gcc"
REFERENCE_PROFILE = "o2"

# SPEC-1 section 7.2 tolerances for conformance tier B.
#
# Split by what the metric actually measures, because a single tolerance is
# wrong for both. Measured drift of the tier-B Python target against the C
# reference at 128x128 / 4096 agents:
#
#     ticks        sum/mean     stddev     frac>1
#         1         1.7e-10    1.8e-09          0
#       100         5.1e-09    2.6e-04          0
#      1000         8.6e-09    6.7e-04     7.3e-04
#
# sum and mean are near-conserved: total pheromone is set by the deposit rate
# and the decay factor, essentially independent of where the agents went. They
# stay at 1e-9 forever, so the tolerance can be *tighter* than originally
# specified -- a wrong decay, deposit or kernel normalisation blows past 1e-6
# immediately. stddev and frac>1 measure where the filaments ended up, which
# genuinely diverges under chaos; holding them to 1e-4 would only ever flag
# the chaos, never a bug.
TIER_B_CONSERVED_REL_TOL = 1e-6      # sum, mean
TIER_B_STRUCTURE_REL_TOL = 2e-2      # stddev
TIER_B_STRUCTURE_ABS_TOL = 2e-2      # frac_gt1


# --------------------------------------------------------------------------- #
# target registry
# --------------------------------------------------------------------------- #


@dataclass
class Target:
    id: str
    lang: str
    backend: str
    cls: str
    dir: Path
    run: list[str]
    compilers: list[str]
    profiles: list[str]
    build: str | None = None
    binary: str | None = None
    fastmath_profiles: list[str] = field(default_factory=list)
    headless_capable: bool = True
    # Update modes this target can implement at all (SPEC-1 section 5.5).
    # The numpy target is deferred-only, and that is a finding, not a bug.
    updates: list[str] = field(default_factory=lambda: list(UPDATE_MODES))
    # "full" or "micro" -- see CONFORMANCE_SETS.
    conformance_set: str = "full"
    # "A" = bit-exact, "B" = tolerance-based (SPEC-1 section 7).
    tier: str = "A"
    extra_args: list[str] = field(default_factory=list)

    def subst(self, s: str, cc: str, profile: str) -> str:
        out = s.replace("{cc}", cc).replace("{profile}", profile)
        out = out.replace("{dir}", str(self.dir))
        if self.binary:
            b = self.binary.replace("{cc}", cc).replace("{profile}", profile)
            out = out.replace("{binary}", str(self.dir / b))
        return out

    def binary_path(self, cc: str, profile: str) -> Path | None:
        if not self.binary:
            return None
        return self.dir / self.binary.replace("{cc}", cc).replace("{profile}", profile)

    def conformance_class(self, profile: str) -> str:
        return "C" if profile in self.fastmath_profiles else "A"


def load_targets() -> dict[str, Target]:
    with (ROOT / "bench" / "targets.toml").open("rb") as fh:
        doc = tomllib.load(fh)
    out: dict[str, Target] = {}
    for t in doc.get("target", []):
        out[t["id"]] = Target(
            id=t["id"],
            lang=t["lang"],
            backend=t.get("backend", "headless"),
            cls=t.get("class", "S"),
            dir=ROOT / t["dir"],
            run=t["run"],
            compilers=t.get("compilers", ["default"]),
            profiles=t.get("profiles", ["default"]),
            build=t.get("build"),
            binary=t.get("binary"),
            fastmath_profiles=t.get("fastmath_profiles", []),
            headless_capable=t.get("headless_capable", True),
            updates=t.get("updates", list(UPDATE_MODES)),
            conformance_set=t.get("conformance_set", "full"),
            tier=t.get("tier", "A"),
            extra_args=t.get("extra_args", []),
        )
    return out


# --------------------------------------------------------------------------- #
# process execution with rusage
# --------------------------------------------------------------------------- #


@dataclass
class RunOutcome:
    ok: bool
    wall_s: float
    max_rss_kb: int
    stdout: str
    stderr: str
    exit_code: int


def spawn_measured(argv: list[str], cwd: Path, timeout: float | None = None) -> RunOutcome:
    """Run argv, returning wall time and the child's own peak RSS."""
    with tempfile.TemporaryFile() as fout, tempfile.TemporaryFile() as ferr:
        t0 = time.monotonic()
        try:
            pid = os.posix_spawn(
                argv[0], argv, os.environ,
                file_actions=[
                    (os.POSIX_SPAWN_OPEN, 0, os.devnull, os.O_RDONLY, 0),
                    (os.POSIX_SPAWN_DUP2, fout.fileno(), 1),
                    (os.POSIX_SPAWN_DUP2, ferr.fileno(), 2),
                ],
            )
        except (FileNotFoundError, PermissionError) as e:
            return RunOutcome(False, 0.0, 0, "", f"{e}", 127)

        _, status, rusage = os.wait4(pid, 0)
        wall = time.monotonic() - t0

        fout.seek(0)
        ferr.seek(0)
        out = fout.read().decode("utf-8", "replace")
        err = ferr.read().decode("utf-8", "replace")

    code = os.waitstatus_to_exitcode(status)
    return RunOutcome(code == 0, wall, int(rusage.ru_maxrss), out, err, code)


def last_json_line(text: str) -> dict | None:
    for line in reversed(text.strip().splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


# --------------------------------------------------------------------------- #
# build
# --------------------------------------------------------------------------- #


@dataclass
class BuildInfo:
    ok: bool
    seconds: float
    binary_bytes: int | None
    stripped_bytes: int | None
    log: str


def do_build(t: Target, cc: str, profile: str, verbose: bool) -> BuildInfo:
    if not t.build:
        return BuildInfo(True, 0.0, None, None, "")

    cmd = t.subst(t.build, cc, profile)
    if verbose:
        print(f"    $ {cmd}")
    t0 = time.monotonic()
    p = subprocess.run(shlex.split(cmd), cwd=t.dir, capture_output=True, text=True)
    dt = time.monotonic() - t0
    log = p.stdout + p.stderr
    if p.returncode != 0:
        return BuildInfo(False, dt, None, None, log)

    size = stripped = None
    b = t.binary_path(cc, profile)
    if b and b.exists():
        size = b.stat().st_size
        stripped = strip_size(b)
    return BuildInfo(True, dt, size, stripped, log)


def strip_size(binary: Path) -> int | None:
    """Size after `strip` on a throwaway copy -- the honest footprint number."""
    if not shutil.which("strip"):
        return None
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / binary.name
        shutil.copy2(binary, tmp)
        r = subprocess.run(["strip", "-s", str(tmp)], capture_output=True)
        return tmp.stat().st_size if r.returncode == 0 else None


# --------------------------------------------------------------------------- #
# bench
# --------------------------------------------------------------------------- #


def sim_args(a: argparse.Namespace) -> list[str]:
    args = ["--update", a.update, "--json", "--seed", str(a.seed)]
    if a.width or a.height or a.agents:
        # Explicit dimensions: the only way to get one table that the
        # interpreted targets can actually finish alongside the compiled ones.
        if not (a.width and a.height and a.agents):
            sys.exit("error: --width, --height and --agents must be given together")
        args += ["--width", str(a.width), "--height", str(a.height),
                 "--agents", str(a.agents)]
    else:
        args += ["--preset", a.preset]
    if a.ticks is not None:
        args += ["--ticks", str(a.ticks)]
    if a.warmup:
        args += ["--warmup", str(a.warmup)]
    if a.threads != 1:
        args += ["--threads", str(a.threads)]
    return args


def cmd_bench(a: argparse.Namespace) -> int:
    targets = load_targets()
    selected = pick_targets(targets, a.targets)
    RESULTS.mkdir(exist_ok=True)
    outpath = Path(a.out).resolve() if a.out else RESULTS / f"{a.preset}-{int(time.time())}.jsonl"
    outpath.parent.mkdir(parents=True, exist_ok=True)

    rows: list[dict] = []
    with outpath.open("w", encoding="utf-8") as sink:
        for t in selected:
            if not t.headless_capable:
                print(f"-- {t.id}: skipped (not headless-capable)")
                continue
            if a.update not in t.updates:
                print(f"-- {t.id}: skipped (does not implement --update {a.update})")
                continue
            for cc in filter_list(t.compilers, a.compilers):
                if t.build and not shutil.which(cc):
                    print(f"-- {t.id}/{cc}: compiler not installed, skipping")
                    continue
                for profile in filter_list(t.profiles, a.profiles):
                    row = bench_one(t, cc, profile, a)
                    rows.append(row)
                    sink.write(json.dumps(row) + "\n")
                    sink.flush()

    try:
        shown = outpath.relative_to(ROOT)
    except ValueError:
        shown = outpath          # staged run: outside the repo tree
    print(f"\nwrote {shown}\n")
    print(render_report(rows))
    return 0


def bench_one(t: Target, cc: str, profile: str, a: argparse.Namespace) -> dict:
    label = f"{t.id}/{cc}/{profile}"
    print(f"-- {label}")

    build = do_build(t, cc, profile, a.verbose)
    if not build.ok:
        print(f"   BUILD FAILED\n{indent(build.log)}")
        return {"target": t.id, "lang": t.lang, "cc": cc, "profile": profile,
                "status": "build-failed", "log": build.log[-4000:]}

    argv = [t.subst(x, cc, profile) for x in t.run] + sim_args(a) + t.extra_args
    argv[0] = resolve_exe(argv[0])

    reps: list[dict] = []
    for i in range(a.reps):
        r = spawn_measured(argv, t.dir)
        if not r.ok:
            print(f"   RUN FAILED (exit {r.exit_code})\n{indent(r.stderr[-2000:])}")
            return {"target": t.id, "lang": t.lang, "cc": cc, "profile": profile,
                    "status": "run-failed", "exit_code": r.exit_code,
                    "log": r.stderr[-4000:]}
        payload = last_json_line(r.stdout)
        if payload is None:
            print(f"   NO RESULT JSON\n{indent(r.stdout[-2000:])}")
            return {"target": t.id, "lang": t.lang, "cc": cc, "profile": profile,
                    "status": "no-json", "log": r.stdout[-4000:]}
        payload["_wall_s"] = r.wall_s
        payload["_max_rss_kb"] = r.max_rss_kb
        reps.append(payload)
        print(f"   rep {i+1}/{a.reps}: {payload['ms_total']:.1f} ms  "
              f"{payload['maups']:.1f} MAUPS  rss {r.max_rss_kb/1024:.1f} MiB")

    best = min(reps, key=lambda p: p["ms_total"])
    hashes = {(p["grid_hash"], p["agent_hash"]) for p in reps}
    return {
        "target": t.id, "lang": t.lang, "backend": t.backend, "class": t.cls,
        "cc": cc, "profile": profile,
        "variant": best.get("variant"),
        "conformance_class": "C" if profile in t.fastmath_profiles else t.tier,
        "status": "ok",
        "reps": a.reps,
        "deterministic_across_reps": len(hashes) == 1,
        "grid_hash": best["grid_hash"], "agent_hash": best["agent_hash"],
        "dirtable_hash": best.get("dirtable_hash"),
        "preset": best["preset"], "width": best["width"], "height": best["height"],
        "agents": best["agents"], "ticks": best["ticks"], "update": best["update"],
        "threads": best["threads"],
        "ms_total_best": best["ms_total"],
        "ms_total_median": statistics.median(p["ms_total"] for p in reps),
        "ms_agents": best["ms_agents"], "ms_diffuse": best["ms_diffuse"],
        "ms_per_tick_median": best["ms_per_tick_median"],
        "ms_per_tick_p99": best["ms_per_tick_p99"],
        "maups": best["maups"], "mcups": best["mcups"],
        "max_rss_kb": min(p["_max_rss_kb"] for p in reps),
        "build_seconds": round(build.seconds, 3),
        "binary_bytes": build.binary_bytes,
        "stripped_bytes": build.stripped_bytes,
    }


def resolve_exe(x: str) -> str:
    if "/" in x or "\\" in x:
        return str(Path(x).resolve())
    found = shutil.which(x)
    return found if found else x


def filter_list(available: list[str], wanted: str | None) -> list[str]:
    if not wanted:
        return available
    want = [w.strip() for w in wanted.split(",")]
    return [x for x in available if x in want]


def pick_targets(targets: dict[str, Target], wanted: str | None) -> list[Target]:
    if not wanted:
        return list(targets.values())
    out = []
    for w in (x.strip() for x in wanted.split(",")):
        if w not in targets:
            sys.exit(f"error: unknown target '{w}' (have: {', '.join(targets)})")
        out.append(targets[w])
    return out


def indent(s: str, pad: str = "      ") -> str:
    return "\n".join(pad + line for line in s.strip().splitlines())


# --------------------------------------------------------------------------- #
# conformance
# --------------------------------------------------------------------------- #


def case_list(conformance_set: str, updates: list[str]) -> list[tuple[str, str, int]]:
    """(size, update, ticks) triples a target should verify."""
    out = []
    for size in CONFORMANCE_SETS[conformance_set]:
        for update in UPDATE_MODES:
            if update not in updates:
                continue
            for n in CONFORMANCE_TICKS[size]:
                out.append((size, update, n))
    return out


def grid_metrics(path: pathlib.Path) -> dict[str, float]:
    """SPEC-1 section 7.2 tolerance metrics from a raw f32 dump."""
    raw = path.read_bytes()
    n = len(raw) // 4
    vals = struct.unpack(f"<{n}f", raw)
    total = math.fsum(vals)
    mean = total / n
    var = math.fsum((v - mean) ** 2 for v in vals) / n
    return {
        "sum": total,
        "mean": mean,
        "stddev": math.sqrt(var),
        "frac_gt1": sum(1 for v in vals if v > 1.0) / n,
    }


def compare_metrics(got: dict[str, float], want: dict[str, float]) -> list[str]:
    """Returns a list of human-readable failures (empty means pass)."""
    bad = []

    def rel(k: str) -> float:
        w = want[k]
        return abs(got[k] - w) / (abs(w) if abs(w) > 1e-12 else 1.0)

    for k in ("sum", "mean"):
        if rel(k) > TIER_B_CONSERVED_REL_TOL:
            bad.append(f"{k} rel {rel(k):.3e} > {TIER_B_CONSERVED_REL_TOL:.0e}")
    if rel("stddev") > TIER_B_STRUCTURE_REL_TOL:
        bad.append(f"stddev rel {rel('stddev'):.3e} > {TIER_B_STRUCTURE_REL_TOL:.0e}")
    d = abs(got["frac_gt1"] - want["frac_gt1"])
    if d > TIER_B_STRUCTURE_ABS_TOL:
        bad.append(f"frac_gt1 abs {d:.3e} > {TIER_B_STRUCTURE_ABS_TOL:.0e}")
    return bad


def run_case(t: Target, cc: str, profile: str, size: str, update: str, ticks: int,
             dump: pathlib.Path | None = None) -> dict | None:
    argv = [t.subst(x, cc, profile) for x in t.run]
    argv[0] = resolve_exe(argv[0])
    argv += CONFORMANCE_SIZES[size]
    argv += ["--update", update, "--ticks", str(ticks), "--seed", "12345", "--json"]
    argv += t.extra_args
    if dump is not None:
        argv += ["--dump-grid", str(dump)]
    r = spawn_measured(argv, t.dir)
    if not r.ok:
        sys.stderr.write(r.stderr[-2000:] + "\n")
        return None
    return last_json_line(r.stdout)


def cmd_conformance(a: argparse.Namespace) -> int:
    targets = load_targets()

    if a.write:
        return write_vectors(targets, a)

    if not TESTVECTORS.exists():
        sys.exit("error: no test vectors yet -- run: bench/run.py conformance --write")
    ref = json.loads(TESTVECTORS.read_text(encoding="utf-8"))
    cases = ref["cases"]

    failures = 0
    for t in pick_targets(targets, a.targets):
        if not t.headless_capable:
            continue
        cc = t.compilers[0]
        profile = next((p for p in t.profiles if p not in t.fastmath_profiles),
                       t.profiles[0])
        if t.build and not shutil.which(cc.split("/")[-1]):
            print(f"-- {t.id}: {cc} not installed, skipping")
            continue

        b = do_build(t, cc, profile, a.verbose)
        if not b.ok:
            print(f"-- {t.id}: BUILD FAILED")
            print(indent(b.log[-2000:]))
            failures += 1
            continue

        skipped = [m for m in UPDATE_MODES if m not in t.updates]
        note = f"  [tier {t.tier}, {t.conformance_set} set"
        note += f", no {'/'.join(skipped)}]" if skipped else "]"
        print(f"-- {t.id} ({cc}/{profile}){note}")

        first_bad: str | None = None
        with tempfile.TemporaryDirectory() as td:
            dump = pathlib.Path(td) / "grid.f32"
            for size, update, n in case_list(t.conformance_set, t.updates):
                key = f"{size}/{update}/{n}"
                want = cases.get(key)
                if want is None:
                    continue

                need_dump = t.tier == "B"
                got = run_case(t, cc, profile, size, update, n,
                               dump if need_dump else None)
                if got is None:
                    print(f"   {key:22s} ERROR")
                    failures += 1
                    first_bad = first_bad or key
                    continue

                if t.tier == "A":
                    gok = got["grid_hash"] == want["grid_hash"]
                    aok = got["agent_hash"] == want["agent_hash"]
                    if gok and aok:
                        print(f"   {key:22s} ok")
                    else:
                        failures += 1
                        first_bad = first_bad or key
                        detail = []
                        if not gok:
                            detail.append(f"grid {got['grid_hash']} != {want['grid_hash']}")
                        if not aok:
                            detail.append(f"agents {got['agent_hash']} != {want['agent_hash']}")
                        print(f"   {key:22s} MISMATCH  " + "  ".join(detail))
                else:
                    if got["grid_hash"] == want["grid_hash"]:
                        print(f"   {key:22s} ok (bit-exact, better than tier B needs)")
                        continue
                    if not dump.exists():
                        print(f"   {key:22s} ERROR (no --dump-grid output)")
                        failures += 1
                        continue
                    bad = compare_metrics(grid_metrics(dump), want["metrics"])
                    if not bad:
                        print(f"   {key:22s} ok (within tier B tolerance)")
                    else:
                        failures += 1
                        first_bad = first_bad or key
                        print(f"   {key:22s} OUT OF TOLERANCE  " + "; ".join(bad))

        if first_bad:
            print(f"   -> first divergence at {first_bad}. "
                  f"Re-run that case with --hash-every 1 to find the exact tick.")

    print("\nCONFORMANCE OK" if failures == 0 else f"\n{failures} FAILURE(S)")
    return 0 if failures == 0 else 1


def write_vectors(targets: dict[str, Target], a: argparse.Namespace) -> int:
    ref = targets[REFERENCE_TARGET]
    b = do_build(ref, REFERENCE_CC, REFERENCE_PROFILE, a.verbose)
    if not b.ok:
        print(b.log)
        return 1

    cases: dict[str, dict] = {}
    dirtable_hash = None
    with tempfile.TemporaryDirectory() as td:
        dump = pathlib.Path(td) / "grid.f32"
        for size, update, n in case_list("full", UPDATE_MODES):
            key = f"{size}/{update}/{n}"
            res = run_case(ref, REFERENCE_CC, REFERENCE_PROFILE, size, update, n, dump)
            if res is None:
                print(f"  {key}: FAILED to produce a result")
                return 1
            dirtable_hash = res.get("dirtable_hash")
            cases[key] = {
                "grid_hash": res["grid_hash"],
                "agent_hash": res["agent_hash"],
                "metrics": {k: round(v, 12) for k, v in grid_metrics(dump).items()},
            }
            print(f"  {key}: grid={res['grid_hash']} agents={res['agent_hash']}")

    TESTVECTORS.parent.mkdir(parents=True, exist_ok=True)
    TESTVECTORS.write_text(json.dumps({
        "spec": "SPEC-1",
        "generated_by": f"{REFERENCE_TARGET} / {REFERENCE_CC} / {REFERENCE_PROFILE}",
        "seed": 12345,
        "dirtable_hash": dirtable_hash,
        "sizes": CONFORMANCE_SIZES,
        "cases": cases,
    }, indent=2) + "\n", encoding="utf-8")
    print(f"\nwrote {TESTVECTORS.relative_to(ROOT)}")
    return 0


# --------------------------------------------------------------------------- #
# report
# --------------------------------------------------------------------------- #


def render_report(rows: list[dict]) -> str:
    ok = [r for r in rows if r.get("status") == "ok"]
    if not ok:
        return "no successful runs"

    ok.sort(key=lambda r: r["ms_total_best"])
    fastest = ok[0]["ms_total_best"]

    head = ("| # | Sprache | Backend | Compiler | Profil | Konf. | ms total | "
            "ms/tick | Agent % | MAUPS | rel. | RSS MiB | Binär KiB | Build s |")
    sep = "|---|---|---|---|---|:-:|---:|---:|---:|---:|---:|---:|---:|---:|"
    lines = [head, sep]
    for i, r in enumerate(ok, 1):
        binkb = f"{r['stripped_bytes']/1024:.0f}" if r.get("stripped_bytes") else "–"
        phase = r["ms_agents"] + r["ms_diffuse"]
        agent_pct = f"{100.0 * r['ms_agents'] / phase:.0f}" if phase > 0 else "–"
        backend = r.get("backend", "")
        if r.get("variant"):
            backend = f"{backend}/{r['variant']}"
        lines.append(
            f"| {i} | {r['lang']} | {backend} | {r['cc']} | {r['profile']} | "
            f"{r['conformance_class']} | "
            f"{r['ms_total_best']:.0f} | {r['ms_per_tick_median']:.3f} | "
            f"{agent_pct} | "
            f"{r['maups']:.1f} | {r['ms_total_best']/fastest:.2f}x | "
            f"{r['max_rss_kb']/1024:.0f} | {binkb} | {r['build_seconds']:.1f} |"
        )

    # Hash consensus is only meaningful within a conformance class: class C
    # (fast-math) is *expected* to differ from class A, and lumping them
    # together turns the designed outcome into a false alarm.
    groups: dict[tuple[str, str], dict[str, list[str]]] = {}
    for r in ok:
        key = (f"{r['preset']}/{r['update']}", r["conformance_class"])
        h = f"{r['grid_hash']}/{r['agent_hash']}"
        groups.setdefault(key, {}).setdefault(h, []).append(
            f"{r['lang']}/{r['cc']}/{r['profile']}")

    lines.append("")
    lines.append("### Hash-Konsens")
    for (case, cls), hs in sorted(groups.items()):
        if len(hs) == 1:
            h = next(iter(hs))
            lines.append(f"- `{case}` Stufe {cls}: **{h}** — "
                         f"alle {len(hs[h])} Läufe identisch.")
        elif cls == "A":
            lines.append(f"- `{case}` Stufe A: **DIVERGENZ ({len(hs)} Ergebnisse)** — "
                         "das ist ein Fehler, Stufe A muss bit-exakt sein:")
            for h, who in sorted(hs.items()):
                lines.append(f"    - `{h}` — {', '.join(who)}")
        else:
            why = {
                "B": "erwartet — Stufe B rechnet in Doubles, siehe SPEC 7.2",
                "C": "erwartet — fast-math ist nicht bit-reproduzierbar",
            }.get(cls, "erwartet")
            lines.append(f"- `{case}` Stufe {cls}: {len(hs)} Ergebnisse ({why}):")
            for h, who in sorted(hs.items()):
                lines.append(f"    - `{h}` — {', '.join(who)}")

    nondet = [r for r in ok if not r.get("deterministic_across_reps", True)]
    if nondet:
        lines.append("")
        lines.append("**Nicht reproduzierbar zwischen Wiederholungen:** " + ", ".join(
            f"{r['lang']}/{r['cc']}/{r['profile']}" for r in nondet))

    bad = [r for r in rows if r.get("status") != "ok"]
    if bad:
        lines.append("")
        lines.append("Fehlgeschlagen: " + ", ".join(
            f"{r['target']}/{r['cc']}/{r['profile']} ({r['status']})" for r in bad))
    return "\n".join(lines)


def cmd_report(a: argparse.Namespace) -> int:
    rows: list[dict] = []
    for p in a.files:
        for line in Path(p).read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
    print(render_report(rows))
    return 0


def cmd_list(a: argparse.Namespace) -> int:
    for t in load_targets().values():
        avail = "" if not t.build else "".join(
            "" if shutil.which(cc) else f"  (missing: {cc})" for cc in t.compilers)
        print(f"{t.id:10s} {t.lang:12s} {t.backend:10s} class={t.cls}"
              f"  compilers={','.join(t.compilers)}"
              f"  profiles={','.join(t.profiles)}{avail}")
    return 0


# --------------------------------------------------------------------------- #


def main() -> int:
    ap = argparse.ArgumentParser(description="slimebench benchmark harness")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="show registered targets").set_defaults(fn=cmd_list)

    b = sub.add_parser("bench", help="build and time targets")
    b.add_argument("--preset", default="small",
                   choices=["tiny", "small", "medium", "large"])
    b.add_argument("--width", type=int, help="overrides --preset (with --height/--agents)")
    b.add_argument("--height", type=int)
    b.add_argument("--agents", type=int)
    b.add_argument("--ticks", type=int)
    b.add_argument("--warmup", type=int, default=0)
    b.add_argument("--seed", type=int, default=12345)
    b.add_argument("--update", default="serial", choices=["serial", "deferred"])
    b.add_argument("--threads", type=int, default=1)
    b.add_argument("--reps", type=int, default=3)
    b.add_argument("--targets", help="comma-separated target ids")
    b.add_argument("--compilers", help="comma-separated compiler filter")
    b.add_argument("--profiles", help="comma-separated profile filter")
    b.add_argument("--out", help="output .jsonl path")
    b.add_argument("-v", "--verbose", action="store_true")
    b.set_defaults(fn=cmd_bench)

    c = sub.add_parser("conformance", help="verify hashes against spec/testvectors")
    c.add_argument("--targets")
    c.add_argument("--write", action="store_true",
                   help="regenerate the reference vectors from the C reference")
    c.add_argument("-v", "--verbose", action="store_true")
    c.set_defaults(fn=cmd_conformance)

    r = sub.add_parser("report", help="render a markdown table from .jsonl results")
    r.add_argument("files", nargs="+")
    r.set_defaults(fn=cmd_report)

    a = ap.parse_args()
    warn_if_on_drvfs()
    return a.fn(a)


def warn_if_on_drvfs() -> None:
    """Benchmarking from /mnt/c under WSL measures the 9p bridge, not the code."""
    if str(ROOT).startswith("/mnt/") and Path("/proc/version").exists():
        if "microsoft" in Path("/proc/version").read_text().lower():
            sys.stderr.write(
                "warning: repo lives on the Windows filesystem (%s).\n"
                "         Build and I/O timings will be dominated by the 9p bridge.\n"
                "         For real numbers use scripts/stage-wsl.sh first.\n\n" % ROOT
            )


if __name__ == "__main__":
    sys.exit(main())
