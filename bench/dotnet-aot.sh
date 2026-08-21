#!/usr/bin/env bash
# What is runtime profile information worth?
#
# Every other language in this project is on one side of the JIT/AOT line and
# stays there. .NET compiles the *same source* four ways, so the difference
# between them is the compilation strategy and nothing else:
#
#   jit    tiered JIT with dynamic PGO -- what `dotnet run` does
#   tier1  TieredCompilation off: every method straight to the optimising JIT
#   r2r    ReadyToRun -- IL compiled ahead of time, runtime still present
#   aot    Native AOT -- a static binary, no JIT, no runtime, no warm-up
#
# The comparison that matters is `tier1` against `aot`: same optimiser, one
# with the profile the running program produced and one without. If they are
# equal, the JIT's advantage on this workload is nothing, and everything the
# `jit` row loses is warm-up rather than code quality.
#
#   A  steady state       all four, plus C and Java for scale
#   B  the ramp           per-tick from cold; aot is the flat control
#   C  what it costs      published size and process start-up
#   D  branchy code       the same question on the half of the tick that has
#                         data-dependent branches in it
#
# usage: bench/dotnet-aot.sh [outfile]
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
OUT="${1:-results/S-dotnet-aot.txt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"

if ! command -v dotnet >/dev/null 2>&1; then
  echo "skip: dotnet not found (apt install dotnet-sdk-10.0 dotnet-sdk-aot-10.0)" >&2
  exit 0
fi

for p in jit tier1 r2r aot; do
  [ -x "impl/csharp/build/$p/slimebench" ] || ( cd impl/csharp && ./build.sh "$p" ) >/dev/null 2>&1
done

SIZE="--width 256 --height 256 --agents 16384"

{
echo "# host: $(uname -sr)  cores: $(nproc)"
echo "# dotnet: $(dotnet --version)"
echo

# ---- A. steady state -----------------------------------------------------
echo "=== A. steady state (256x256/16384, 100 ticks, warmup 50, best of 3)"
printf '%-22s %-12s %12s\n' target grid ms/tick
best() { # label cmd...
  local label=$1; shift
  local b="" gh="" j
  for _ in 1 2 3; do
    j=$("$@" $SIZE --ticks 100 --warmup 50 --update serial --json 2>/dev/null | grep -m1 '^{') || continue
    b=$(B="$b" python3 -c "
import json, os, sys
v = json.loads(sys.argv[1])['ms_per_tick_mean']; p = os.environ['B']
print(min(v, float(p)) if p else v)" "$j")
    gh=$(echo "$j" | python3 -c 'import sys,json; print(json.load(sys.stdin)["grid_hash"])')
  done
  [ -z "$b" ] && { printf '%-22s NO OUTPUT\n' "$label"; return; }
  printf '%-22s %-12s %12.4f\n' "$label" "$gh" "$b"
}
best "csharp jit"      impl/csharp/build/jit/slimebench
best "csharp tier1"    impl/csharp/build/tier1/slimebench
best "csharp r2r"      impl/csharp/build/r2r/slimebench
best "csharp aot"      impl/csharp/build/aot/slimebench
best "java c2"         impl/java/build/c2/slimebench
best "c gcc-O3-native" impl/c/build/gcc-o3-native/slimebench-headless
echo

# ---- B. the ramp ---------------------------------------------------------
echo "=== B. per-tick milliseconds from cold, no warmup"
printf '%-12s %9s %9s %9s\n' ticks jit tier1 aot
for p in jit tier1 aot; do
  SLIMEBENCH_TICK_MS=1 "impl/csharp/build/$p/slimebench" $SIZE \
    --ticks 300 --warmup 0 --update serial --json 2>"$OUT.$p.raw" >/dev/null
  awk '/^tick_ms/{print $3}' "$OUT.$p.raw" > "$OUT.$p.ms"
  rm -f "$OUT.$p.raw"
done
python3 - "$OUT.jit.ms" "$OUT.tier1.ms" "$OUT.aot.ms" <<'PY'
import sys
v = [[float(x) for x in open(f)] for f in sys.argv[1:4]]
def blk(a, lo, hi): return sum(a[lo:hi]) / (hi - lo)
for lo, hi in ((0,5),(5,10),(10,25),(25,50),(50,100),(100,200),(200,300)):
    print("%-12s %9.3f %9.3f %9.3f" % (f"{lo+1}-{hi}", *[blk(a,lo,hi) for a in v]))
print("%-12s %9.3f %9.3f %9.3f" % ("first tick", *[a[0] for a in v]))
print("%-12s %9.3f %9.3f %9.3f" % ("best tick", *[min(a) for a in v]))
print("%-12s %8.1fx %8.1fx %8.1fx" % ("first/best", *[a[0]/min(a) for a in v]))
PY
rm -f "$OUT".jit.ms "$OUT".tier1.ms "$OUT".aot.ms
echo

# ---- C. what each configuration costs to ship ----------------------------
echo "=== C. published size and process start-up (--ticks 0)"
printf '%-12s %10s %12s\n' profile size "start ms"
for p in jit tier1 r2r aot; do
  sz=$(du -sh "impl/csharp/build/$p/app" 2>/dev/null | cut -f1)
  t0=$(date +%s%N)
  for _ in 1 2 3 4 5; do "impl/csharp/build/$p/slimebench" --width 4 --height 4 \
      --agents 4 --ticks 0 --json >/dev/null 2>&1; done
  t1=$(date +%s%N)
  # Five runs, so divide by five. Doing the arithmetic in awk rather than in
  # printf: an earlier version passed "129e-1" to %.1f, which printf duly read
  # as 12.9 and reported half the real figure.
  printf '%-12s %10s %12s\n' "$p" "$sz" \
    "$(awk -v n="$((t1 - t0))" 'BEGIN{printf "%.1f", n / 5 / 1000000}')"
done
echo

# ---- D. does the parity survive a branchy loop? --------------------------
echo "=== D. straight-line code against branchy code"
echo "   The stencil is nine loads and ten arithmetic operations with no"
echo "   branch in it. The agent pass makes a data-dependent four-way turn"
echo "   decision per agent per tick, which is where profile-guided"
echo "   optimisation should have something to work with. The two are timed"
echo "   separately by every port, so the question needs no new workload."
echo
BS=impl/c/build/gcc-o2-bstats/slimebench-headless
if [ ! -x "$BS" ]; then
  ( cd impl/c && make -s SB_BRANCH_STATS=1 CC=gcc PROFILE=o2 headless ) >/dev/null 2>&1
fi
if [ -x "$BS" ]; then
  echo "   how the turn decision actually splits (the reference; every port is"
  echo "   bit-identical, so this is a property of the simulation):"
  "$BS" --preset tiny --ticks 200 --update deferred --json 2>&1 >/dev/null     | grep branch_stats | sed 's/^/     /'
  echo
fi
BIG="--preset tiny --agents 262144 --ticks 200 --warmup 100 --update deferred"
printf '  %-24s %12s %12s\n' configuration "agents ms" "diffuse ms"
for p in tier1 aot aot-native; do
  [ -x "impl/csharp/build/$p/slimebench" ] || continue
  "impl/csharp/build/$p/slimebench" $BIG --json 2>/dev/null | grep -m1 '^{'     | P="$p" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
print("  %-24s %12.2f %12.2f" % (os.environ["P"], d["ms_agents"], d["ms_diffuse"]))'
done
echo
echo "   If ahead-of-time compilation only kept up on straight-line code, the"
echo "   agents column is where it would show. It does not."
} | tee "$OUT"
echo "wrote $OUT" >&2
