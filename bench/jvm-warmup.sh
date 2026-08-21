#!/usr/bin/env bash
# The one thing only the JVM target can show: the measurement depends on how
# long you have been measuring.
#
# Every other implementation in this project is at full speed on tick 1. A JVM
# starts interpreting, promotes to C1 after a few thousand invocations and to
# C2 after a few tens of thousands, so the first ticks are running a different
# program from the later ones. That is not noise to be warmed away and then
# ignored -- it is the cost model of the platform, and it is measurable.
#
#   A  the ramp            per-tick milliseconds, tiered against C2-only
#   B  the ladder          two interpreters and three compiled paths, one size
#
# B is where the JVM's interpreter earns its place in this document. -Xint runs
# the identical algorithm with no JIT at all, which makes it directly
# comparable to CPython running the identical algorithm -- and that comparison
# is not available anywhere else, because no other runtime here lets you switch
# the compiler off.
#
# usage: bench/jvm-warmup.sh [outfile]
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
OUT="${1:-results/S-jvm-warmup.txt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"

if ! command -v javac >/dev/null 2>&1; then
  echo "skip: javac not found (apt install openjdk-21-jdk-headless)" >&2
  exit 0
fi

for p in default c2 int; do
  [ -x "impl/java/build/$p/slimebench" ] || ( cd impl/java && ./build.sh "$p" ) >/dev/null 2>&1
done

SIZE="--width 256 --height 256 --agents 16384"
NB="${SLIMEBENCH_NUMBAPY:-$HOME/opt/numba/bin/python}"

{
echo "# host: $(uname -sr)  cores: $(nproc)"
echo "# java: $(java -version 2>&1 | head -1)"
echo

# ---- A. the ramp ---------------------------------------------------------
echo "=== A. per-tick milliseconds from a cold JVM (256x256/16384, serial, no warmup)"
printf '%-14s %10s %10s\n' "ticks" "tiered" "c2-only"
for p in default c2; do
  SLIMEBENCH_TICK_MS=1 "impl/java/build/$p/slimebench" $SIZE \
    --ticks 400 --warmup 0 --update serial --json 2>"$OUT.$p.raw" >/dev/null
  awk '/^tick_ms/{print $3}' "$OUT.$p.raw" > "$OUT.$p.ms"
  rm -f "$OUT.$p.raw"
done
python3 - "$OUT.default.ms" "$OUT.c2.ms" <<'PY'
import sys
a = [float(x) for x in open(sys.argv[1])]
b = [float(x) for x in open(sys.argv[2])]
def blk(v, lo, hi): return sum(v[lo:hi]) / (hi - lo)
for lo, hi in ((0,5),(5,10),(10,25),(25,50),(50,100),(100,200),(200,400)):
    print("%-14s %10.3f %10.3f" % (f"{lo+1}-{hi}", blk(a,lo,hi), blk(b,lo,hi)))
print("%-14s %10.3f %10.3f" % ("first tick", a[0], b[0]))
print("%-14s %10.3f %10.3f" % ("best tick", min(a), min(b)))
print("%-14s %9.1fx %9.1fx" % ("first / best", a[0]/min(a), b[0]/min(b)))
PY
rm -f "$OUT.default.ms" "$OUT.c2.ms"
echo

# ---- B. the ladder -------------------------------------------------------
echo "=== B. two interpreters and three compiled paths (same size, warmup 50)"
# The statistics rule (bench/run.py): minimum of the repetitions, spread
# beside it. One repetition for pure Python, where a run is ninety seconds and
# the ratio being measured is 340x.
printf '%-28s %-12s %12s %8s\n' target grid ms/tick spread
lad() { # label reps cmd...
  local label=$1 reps=$2; shift 2
  local i
  for i in $(seq "$reps"); do
    "$@" $SIZE --ticks 100 --warmup 50 --update serial --json 2>/dev/null | grep -m1 '^{'
  done | LBL="$label" python3 -c '
import json, os, sys
rows = [json.loads(l) for l in sys.stdin if l.startswith("{")]
if not rows:
    print("%-28s NO OUTPUT" % os.environ["LBL"])
else:
    v = sorted(r["ms_per_tick_mean"] for r in rows)
    sp = "—" if len(v) < 2 else "%.1f%%" % ((v[-1] - v[0]) / v[0] * 100)
    print("%-28s %-12s %12.4f %8s"
          % (os.environ["LBL"], rows[0]["grid_hash"], v[0], sp))'
}
lad "c gcc -O3 -march=native" 3 impl/c/build/gcc-o3-native/slimebench-headless
lad "java, C2 only"           3 impl/java/build/c2/slimebench
lad "java, tiered (default)"  3 impl/java/build/default/slimebench
lad "go, -gcflags=-B"         3 impl/go/build/nobounds/slimebench
[ -x "$NB" ] && lad "numba"   3 "$NB" impl/python/slimebench_numba.py
lad "java, -Xint"             3 impl/java/build/int/slimebench
lad "python pure --strict-f32" 1 python3 impl/python/slimebench_pure.py --strict-f32
echo
echo "   Every tier-A row above carries the same grid hash. The two interpreter"
echo "   rows are the point: identical algorithm, identical exactness, and the"
echo "   only difference is whose interpreter is running it."
} | tee "$OUT"
echo "wrote $OUT" >&2
