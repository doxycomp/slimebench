#!/usr/bin/env bash
# What does the interpreter cost, and what does fast-math actually break?
#
# impl/python/slimebench_numba.py is slimebench_pure.py with @njit on the
# kernels: the same loops, the same order, the same variable names. That makes
# the pair a controlled experiment rather than two ports that happen to be in
# the same language.
#
#   A  the interpreter's share      pure / numba, at tier B and at tier A
#   B  the JIT's warm-up cost       compile time against per-tick time
#   C  when fast-math becomes visible
#
# C is the one worth reading. The `fastmath` profile changes the grid hash on
# tick 1 and the agent hash not for hundreds of ticks, so a conformance check
# that only looked at agents would call it conformant. SPEC-1 section 6 splits
# the two hashes for fault localisation; this measures how long the wrong half
# would have lied.
#
# usage: bench/numba-jit.sh [outfile]
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
OUT="${1:-results/S-numba-jit.txt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"

NB="${SLIMEBENCH_NUMBAPY:-$HOME/opt/numba/bin/python}"
if [ ! -x "$NB" ]; then
  echo "skip: no numba interpreter at $NB" >&2
  echo "      uv venv --python 3.12 ~/opt/numba && uv pip install --python ~/opt/numba/bin/python numba numpy" >&2
  exit 0
fi

C=impl/c/build/gcc-o2/slimebench-headless
[ -x "$C" ] || ( cd impl/c && make -s gcc-o2 ) >/dev/null 2>&1

{
echo "# host: $(uname -sr)  cores: $(nproc)"
echo "# numba: $("$NB" -c 'import numba; print(numba.__version__)')  on $("$NB" -V 2>&1)"
echo

# ---- A. what the interpreter costs --------------------------------------
# 128x128 with 4096 agents, because pure Python has to finish it.
CFG="--width 128 --height 128 --agents 4096 --ticks 100 --warmup 3 --update serial"
echo "=== A. the same program, interpreted and compiled (128x128/4096, 100 ticks, serial)"
# The statistics rule (bench/run.py): minimum of the repetitions, spread
# beside it. Three for the fast targets; pure Python and Perl get one, because
# a repetition there is tens of seconds and the ratio being measured is 300x.
printf '%-32s %-12s %-12s %10s %8s\n' target grid agents ms/tick spread
row() { # reps label cmd...
  local reps=$1 label=$2; shift 2
  for _ in $(seq "$reps"); do
    "$@" $CFG --json 2>/dev/null | grep -m1 '^{'
  done | LBL="$label" python3 -c '
import json, os, sys
rows = [json.loads(l) for l in sys.stdin if l.startswith("{")]
if not rows:
    print("%-32s NO OUTPUT" % os.environ["LBL"])
else:
    v = sorted(r["ms_per_tick_mean"] for r in rows)
    sp = (v[-1] - v[0]) / v[0] * 100 if len(v) > 1 else float("nan")
    print("%-32s %-12s %-12s %10.4f %7s" % (
        os.environ["LBL"], rows[0]["grid_hash"], rows[0]["agent_hash"], v[0],
        "—" if len(v) < 2 else "%.1f%%" % sp))'
}
row 1 "python pure (tier B)"          python3 impl/python/slimebench_pure.py
row 1 "python pure --strict-f32 (A)"  python3 impl/python/slimebench_pure.py --strict-f32
row 3 "numba (tier A)"                "$NB"   impl/python/slimebench_numba.py
row 3 "numba --fastmath (tier C)"     "$NB"   impl/python/slimebench_numba.py --fastmath
[ -x "$C" ] && row 3 "c gcc-o2 (tier A)" "$C"
echo

# ---- B. what the JIT costs up front -------------------------------------
echo "=== B. compile time, against the work it is compiled for"
"$NB" impl/python/slimebench_numba.py --preset tiny --ticks 100 --warmup 5 --json 2>&1 >/dev/null \
  | grep jit_compile_ms
echo "   (compiled against a 4x4 grid before the clock starts; see _precompile)"
echo

# ---- C. when fast-math reaches the agents --------------------------------
echo "=== C. how long the agent hash keeps saying 'conformant' (512x512/65536)"
printf '%-10s %7s   %-10s %-10s\n' mode ticks grid agents
for upd in serial deferred; do
  for t in 1 5 50 400 800; do
    ga=$("$NB" impl/python/slimebench_numba.py --preset tiny --ticks "$t" --warmup 0 \
         --update "$upd" --json 2>/dev/null | grep -m1 '^{')
    gc=$("$NB" impl/python/slimebench_numba.py --preset tiny --ticks "$t" --warmup 0 \
         --update "$upd" --fastmath --json 2>/dev/null | grep -m1 '^{')
    [ -z "$ga" ] || [ -z "$gc" ] && { printf '%-10s %7s   NO OUTPUT\n' "$upd" "$t"; continue; }
    A="$ga" B="$gc" M="$upd" T="$t" python3 -c '
import json, os
a = json.loads(os.environ["A"]); b = json.loads(os.environ["B"])
print("%-10s %7s   %-10s %-10s" % (
    os.environ["M"], os.environ["T"],
    "same" if a["grid_hash"]  == b["grid_hash"]  else "DIFF",
    "same" if a["agent_hash"] == b["agent_hash"] else "DIFF"))'
  done
done
} | tee "$OUT"
echo "wrote $OUT" >&2
