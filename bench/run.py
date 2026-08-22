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
    # Same size, one parameter changed, and it is the only case in this suite
    # that can catch a fused multiply-add.
    #
    # The default --step is 1.0, so `cos[d] * step` is exact and an FMA over it
    # produces the identical value. The sensor multiply by --sensor-dist 9.0 is
    # inexact, but its result only feeds an int() truncation, where a 1-ULP
    # difference almost never crosses a cell boundary. The consequence is that
    # every port in this project passed every case with or without its
    # contraction flag: gfortran at -ffp-contract=fast emits thirteen f32 FMAs
    # into the agent pass and still matched the reference on all twenty.
    #
    # Sweeping --step made the rule visible -- 1.0 and 2.0 agree, 1.25, 1.3,
    # 0.7 and 3.7 diverge -- because only a power of two keeps the multiply
    # exact. 1.3 is not one, so this case fails the moment a port lets its
    # compiler fuse.
    "fma": ["--width", "128", "--height", "128", "--agents", "4096",
            "--step", "1.3"],
    "tiny": ["--preset", "tiny"],
    "small": ["--preset", "small"],
}
CONFORMANCE_TICKS = {
    "micro": [1, 10, 100],
    "fma": [100],
    "tiny": [1, 10, 100, 1000],
    "small": [1, 10, 100],
}
# Which sizes a target runs, by its declared conformance_set. "fma" is in both:
# it costs one run at the smallest size and it is the only guard against a
# whole class of silent divergence.
CONFORMANCE_SETS = {
    "micro": ["micro", "fma"],
    "full": ["micro", "fma", "tiny", "small"],
}
UPDATE_MODES = ["serial", "deferred"]

# A repetition spread above this is called out in the run log and marked in the
# generated tables. Not a failure -- some targets are legitimately noisy, and
# class P at 32 threads is one of them -- but a row the reader should not read
# to three significant figures.
NOISY_SPREAD = 0.05

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
    # Extra arguments a *profile* adds. A C target expresses "this profile
    # deliberately breaks tier A" by building a different binary; an
    # interpreted target has no build step, so it says the same thing with a
    # flag. See python-numba/fastmath.
    profile_args: dict[str, list[str]] = field(default_factory=dict)
    # Variants of another target that differ only in a benchmark knob. They
    # would re-verify identical behaviour, so conformance skips them; the
    # target they vary is already covered.
    skip_conformance: bool = False

    def subst(self, s: str, cc: str, profile: str) -> str:
        out = s.replace("{cc}", cc).replace("{profile}", profile)
        out = out.replace("{dir}", str(self.dir))
        out = out.replace("{python314t}", free_threaded_python())
        out = out.replace("{numbapy}", numba_python())
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
            profile_args=t.get("profile_args", {}),
            skip_conformance=t.get("skip_conformance", False),
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

    # One retry, and only one.
    #
    # A ninety-minute series lost a row to
    #   error: unable to rename temporary '...o.tmp' to output file '...o':
    #   No such file or directory
    # from clang, on a build that then succeeded five times out of five when
    # asked again. Under the I/O this run generates, the filesystem
    # occasionally loses a rename; a build-failed target is a missing row and
    # the run still reports success, which is the failure shape section 14 of
    # docs/RESULTS.md collects.
    #
    # Retrying once is not the same as ignoring the failure: a build that is
    # actually broken fails twice, the second log is what gets reported, and
    # the retry itself is printed so it cannot pass unnoticed.
    if p.returncode != 0:
        print(f"   build failed, retrying once: {cmd}")
        t1 = time.monotonic()
        p = subprocess.run(shlex.split(cmd), cwd=t.dir, capture_output=True, text=True)
        dt += time.monotonic() - t1
        log += "\n--- retry ---\n" + p.stdout + p.stderr

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
    # "a" when asked: a phase that sweeps several presets is one table, and
    # writing it needs several invocations because --preset takes one value.
    with outpath.open("a" if a.append else "w", encoding="utf-8") as sink:
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

    argv = ([t.subst(x, cc, profile) for x in t.run] + sim_args(a)
            + t.extra_args + t.profile_args.get(profile, []))
    argv[0] = resolve_exe(argv[0])
    if not runnable(argv):
        print(f"   {argv[0]} not found, skipping")
        return {"target": t.id, "lang": t.lang, "cc": cc, "profile": profile,
                "status": "unavailable"}

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

    if a.reps > 1:
        _ms = [p["ms_total"] for p in reps]
        _pt = [p["ms_per_tick_median"] for p in reps]
        _sp = (max(_pt) - min(_pt)) / min(_pt) if min(_pt) > 0 else 0.0
        if _sp > NOISY_SPREAD:
            print(f"   per-tick spread {_sp*100:.1f}% -- noisy, "
                  f"see the statistics rule")

    # THE STATISTICS RULE. One place, one convention, applied everywhere.
    #
    # Report the *minimum* of the repetitions, and report the spread beside it.
    #
    # The minimum, because interference is one-sided: another process, a
    # migration, a page fault can only make a run slower, never faster. The
    # fastest repetition is the best estimate of what the code costs when
    # nothing else is happening, and the mean of a distribution with a hard
    # floor and an unbounded tail estimates the machine's mood instead.
    #
    # The spread, because a minimum on its own invites exactly the mistake
    # this rule was written after: two rows differing by less than the
    # run-to-run variation, read as a ranking. `ms_total_spread` is
    # (max - min) / min over the repetitions. A difference between two rows
    # that is smaller than either row's spread is not a difference, and
    # tables.py marks such rows rather than leaving the reader to notice.
    #
    # Median is kept because it is the honest thing to look at when the spread
    # is large -- if best and median disagree by more than the spread, the
    # distribution is not what any single number describes.
    # Two spreads, because there are two ranking columns and they are not
    # equally noisy. `ms_total` is one wall-clock measurement of the whole
    # loop, so a single scheduling hiccup lands in it whole. `ms_per_tick_median`
    # is the middle of a hundred per-tick measurements, which is why the class
    # S table ranks on it -- and it is an order of magnitude steadier: 0.7 %
    # against 6.7 % over the same five runs of the same binary. A table must
    # quote the spread of the column it sorts by, or the warning describes a
    # number nobody is reading.
    def _spread(vs: list[float]) -> float:
        return (max(vs) - min(vs)) / min(vs) if vs and min(vs) > 0 else 0.0

    ms = [p["ms_total"] for p in reps]
    per_tick = [p["ms_per_tick_median"] for p in reps]
    agents_ms = [p["ms_agents"] for p in reps]
    diffuse_ms = [p["ms_diffuse"] for p in reps]
    spread = _spread(ms)
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
        "ms_total_median": statistics.median(ms),
        # (max - min) / min across repetitions; see the statistics rule above.
        "ms_total_spread": round(spread, 4),
        "ms_total_reps": [round(v, 4) for v in ms],
        "ms_per_tick_spread": round(_spread(per_tick), 4),
        "ms_per_tick_reps": [round(v, 6) for v in per_tick],
        # Minimum across repetitions and their own spread, like every other
        # timing here. These came from `best` -- whichever repetition happened
        # to win on ms_total -- which is a different rule, and left the class V
        # table ranking on ms_diffuse with no way to say how firm the ranking
        # was. 57.3 against 59.4 ms means nothing without it.
        "ms_agents": min(agents_ms),
        "ms_agents_spread": round(_spread(agents_ms), 4),
        "ms_agents_reps": [round(v, 4) for v in agents_ms],
        "ms_diffuse": min(diffuse_ms),
        "ms_diffuse_spread": round(_spread(diffuse_ms), 4),
        "ms_diffuse_reps": [round(v, 4) for v in diffuse_ms],
        # Minimum across repetitions, like every other time here; taking
        # it from whichever rep won on ms_total would mix two rules.
        "ms_per_tick_median": min(per_tick),
        "ms_per_tick_p99": best["ms_per_tick_p99"],
        "maups": best["maups"], "mcups": best["mcups"],
        "max_rss_kb": min(p["_max_rss_kb"] for p in reps),
        "build_seconds": round(build.seconds, 3),
        "binary_bytes": build.binary_bytes,
        "stripped_bytes": build.stripped_bytes,
    }


def free_threaded_python() -> str:
    """Path to a free-threaded CPython, or a name that will not resolve.

    It is deliberately not on PATH as `python3`: a free-threaded build installs
    beside the stock one. SLIMEBENCH_PY314T overrides; the default is where the
    setup script puts it.
    """
    env = os.environ.get("SLIMEBENCH_PY314T")
    if env:
        return env
    cand = pathlib.Path.home() / "opt" / "ft314" / "bin" / "python"
    return str(cand) if cand.exists() else "python3.14t-not-installed"


def numba_python() -> str:
    """Path to an interpreter with numba, or a name that will not resolve.

    numba is not installable into the system interpreter here (PEP 668), so it
    lives in its own venv beside the free-threaded build. SLIMEBENCH_NUMBAPY
    overrides.
    """
    env = os.environ.get("SLIMEBENCH_NUMBAPY")
    if env:
        return env
    cand = pathlib.Path.home() / "opt" / "numba" / "bin" / "python"
    return str(cand) if cand.exists() else "numba-python-not-installed"


def runnable(argv: list[str]) -> bool:
    """Whether argv[0] is something the OS can actually start.

    Cheap, and it catches the failure mode that produced this function: a
    target whose command still held an unexpanded placeholder ran ten
    conformance cases and reported ten divergences, where the honest answer
    was that it never started. A target that cannot run is a skip, not a
    failure -- but only if someone checks.
    """
    exe = argv[0]
    if "/" in exe or "\\" in exe:
        return pathlib.Path(exe).exists()
    return shutil.which(exe) is not None


def device_available(argv: list[str], update: str) -> tuple[bool, str]:
    """Whether a class G target can reach its GPU, asked by trying.

    Returns (False, reason) when a zero-tick run does not succeed. The reason
    is the last line the target wrote to stderr, so the skip says what was
    missing rather than only that something was.
    """
    try:
        # The update mode is the target's own, not a default: pygl rejects
        # `serial` on principle (SPEC-1 5.5) and exits non-zero for it, which
        # would read as a missing device.
        r = subprocess.run([*argv, "--ticks", "0", "--update", update, "--json"],
                           capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"no device ({type(e).__name__})"
    if r.returncode == 0:
        return True, ""
    tail = [l for l in (r.stderr or "").splitlines() if l.strip()]
    return False, tail[-1].strip()[:120] if tail else f"exit {r.returncode}"


def resolve_exe(x: str) -> str:
    # absolute(), not resolve(): a virtualenv's bin/python is a symlink to the
    # base interpreter, and a venv works by the path it was *invoked* through.
    # Following the link lands on the base interpreter, which cannot see the
    # venv's site-packages -- the free-threaded target failed conformance ten
    # times with "No module named numpy" before this comment existed.
    if "/" in x or "\\" in x:
        return os.path.normpath(str(Path(x).absolute()))
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
    argv += t.extra_args + t.profile_args.get(profile, [])
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
        if not t.headless_capable or t.skip_conformance:
            continue
        # One compiler per target: conformance asks whether the *port* agrees,
        # and a second compiler of the same language answers a different
        # question. --compilers exists so CI can ask that other question too,
        # because a tier-A claim that only holds under gcc is not a tier-A
        # claim.
        ccs = filter_list(t.compilers, getattr(a, "compilers", None))
        if not ccs:
            continue
        cc = ccs[0]
        profile = next((p for p in t.profiles if p not in t.fastmath_profiles),
                       t.profiles[0])
        if t.build and not shutil.which(cc.split("/")[-1]):
            print(f"-- {t.id}: {cc} not installed, skipping")
            continue
        # Build first, then check the binary exists. The other order looks
        # equivalent and is not: it asks whether a target is runnable *before*
        # anything has built it, so on a machine where nothing is pre-built --
        # a fresh container, for instance -- every compiled target skips with
        # "not found" and the gate silently checks the interpreted ones only.
        # That is how the container job came to assert twelve languages while
        # exercising five.
        b = do_build(t, cc, profile, a.verbose)
        if not b.ok:
            print(f"-- {t.id}: BUILD FAILED")
            print(indent(b.log[-2000:]))
            failures += 1
            continue

        probe = [t.subst(x, cc, profile) for x in t.run]
        probe[0] = resolve_exe(probe[0])
        if not runnable(probe):
            print(f"-- {t.id}: {probe[0]} not found, skipping")
            continue
        # `runnable` answers whether the OS can start argv[0], which is the
        # right question for a compiled binary and the wrong one for a script:
        # `python3` always exists, so a GPU target whose device is absent
        # passed that check, started, and failed every conformance case. In a
        # container without a GL device that is eleven reported divergences
        # for a target that never computed anything -- exactly the failure
        # `runnable` was written to stop, one level further in.
        #
        # So class G targets are asked to do nothing at all first. A device
        # that is not there fails a zero-tick run just as surely as a
        # thousand-tick one, and costs one process to find out.
        if t.cls == "G":
            ok, why = device_available(probe, t.updates[0])
            if not ok:
                print(f"-- {t.id}: {why}, skipping")
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

    head = ("| # | Language | Backend | Compiler | Profile | Tier | ms total | "
            "spread | ms/tick | agent % | MAUPS | rel. | RSS MiB | binary KiB | "
            "build s |")
    sep = "|---|---|---|---|---|:-:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    lines = [head, sep]
    for i, r in enumerate(ok, 1):
        binkb = f"{r['stripped_bytes']/1024:.0f}" if r.get("stripped_bytes") else "–"
        phase = r["ms_agents"] + r["ms_diffuse"]
        agent_pct = f"{100.0 * r['ms_agents'] / phase:.0f}" if phase > 0 else "–"
        backend = r.get("backend", "")
        if r.get("variant"):
            backend = f"{backend}/{r['variant']}"
        sp = r.get("ms_total_spread")
        spread = "–" if sp is None else f"{sp*100:.1f}%" + ("!" if sp > NOISY_SPREAD else "")
        lines.append(
            f"| {i} | {r['lang']} | {backend} | {r['cc']} | {r['profile']} | "
            f"{r['conformance_class']} | "
            f"{r['ms_total_best']:.0f} | {spread} | "
            f"{r['ms_per_tick_median']:.3f} | "
            f"{agent_pct} | "
            f"{r['maups']:.1f} | {r['ms_total_best']/fastest:.2f}x | "
            f"{r['max_rss_kb']/1024:.0f} | {binkb} | {r['build_seconds']:.1f} |"
        )

    noisy = [r for r in ok if (r.get("ms_total_spread") or 0) > NOISY_SPREAD]
    if noisy:
        worst = max(r["ms_total_spread"] for r in noisy)
        lines.append("")
        lines.append(
            f"! {len(noisy)} row(s) varied by more than {NOISY_SPREAD*100:.0f}% "
            f"between repetitions, up to {worst*100:.0f}%. Times are the minimum "
            f"of {ok[0].get('reps', '?')} runs; a gap smaller than a row's own "
            f"spread is not a ranking.")

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
    lines.append("### Hash consensus")
    for (case, cls), hs in sorted(groups.items()):
        if len(hs) == 1:
            h = next(iter(hs))
            lines.append(f"- `{case}` tier {cls}: **{h}** — "
                         f"all {len(hs[h])} runs identical.")
        elif cls == "A":
            lines.append(f"- `{case}` tier A: **DIVERGENCE ({len(hs)} results)** — "
                         "this is a bug; tier A must be bit-exact:")
            for h, who in sorted(hs.items()):
                lines.append(f"    - `{h}` — {', '.join(who)}")
        else:
            why = {
                "B": "expected — tier B computes in doubles, see SPEC 7.2",
                "C": "expected — fast-math is not bit-reproducible",
            }.get(cls, "expected")
            lines.append(f"- `{case}` tier {cls}: {len(hs)} results ({why}):")
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
                   choices=["tiny", "small", "medium", "large", "huge"])
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
    b.add_argument("--append", action="store_true",
                   help="add to --out instead of replacing it")
    b.add_argument("-v", "--verbose", action="store_true")
    b.set_defaults(fn=cmd_bench)

    c = sub.add_parser("conformance", help="verify hashes against spec/testvectors")
    c.add_argument("--targets")
    c.add_argument("--compilers",
                   help="comma-separated compiler filter; a target whose "
                        "compilers are all filtered out is skipped")
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
