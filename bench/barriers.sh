#!/usr/bin/env bash
# Why do the two managed runtimes stop scaling?
#
# Section 5 observed that Java and C# both peak at or before 16 threads and
# then regress, and attributed it to the barrier. C and Go could already report
# their own work/barrier split; Java and C# could not, so the attribution was a
# guess -- the category section 14 collects.
#
# They can now, and the guess was half right and wrong in different ways for
# each of them. This script prints the split as the thread count grows, which
# is what separates "the barrier costs too much" from "the work stops
# scaling". Only worker 0 records, in all four languages, for the reason
# impl/c gives: averaging the workers would hide the imbalance the numbers are
# for.
#
# usage: bench/barriers.sh [outfile]
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
OUT="${1:-results/P-barriers.txt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"

[ -d "$HOME/opt/go/bin" ] && export PATH="$PATH:$HOME/opt/go/bin"

# shellcheck source=bench/jsonl.sh
. "$(dirname "$0")/jsonl.sh"
jsonl_for "$OUT"

C=impl/c/build/gcc-o3-native/slimebench-headless
GO=impl/go/build/nobounds/slimebench
JAVA=impl/java/build/default/slimebench
CS=impl/csharp/build/aot-native/slimebench

{
echo "# host: $(uname -sr)  cores: $(nproc)"
echo "# medium (2048x2048, 1 M agents), 60 ticks after 20 of warm-up, binned"
echo "# work and barrier are worker 0's, in ms per tick"
echo

# The instrumentation is two clock reads per phase and it is not free. Report
# what it costs, so the reader can see the breakdown is not an artefact of
# taking it.
echo "=== what the instrumentation itself costs (ms/tick at T=32)"
printf '  %-8s %10s %10s %8s\n' lang off on ratio
cost() { # label binary
  [ -x "$2" ] || { printf '  %-8s not built\n' "$1"; return; }
  local a b
  a=$("$2" --preset medium --ticks 60 --warmup 20 --update deferred --threads 32 \
        --deposit-reduce binned --json 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["ms_per_tick_mean"])')
  b=$(SLIMEBENCH_PHASE_STATS=1 "$2" --preset medium --ticks 60 --warmup 20 \
        --update deferred --threads 32 --deposit-reduce binned --json 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["ms_per_tick_mean"])')
  python3 -c "print('  %-8s %10.3f %10.3f %7.2fx' % ('$1', $a, $b, $b/$a))"
  jrow table=instr-cost lang="$1" off="$a" on="$b"
}
cost c "$C"; cost go "$GO"; cost java "$JAVA"; cost csharp "$CS"
echo

echo "=== work and barrier as the thread count grows"
printf '  %-8s %4s %10s %10s %10s\n' lang T work barrier total
sweep() { # label binary
  [ -x "$2" ] || { printf '  %-8s not built\n' "$1"; return; }
  local row l t2 w b tot
  for t in 4 8 16 32; do
    row=$(SLIMEBENCH_PHASE_STATS=1 "$2" --preset medium --ticks 60 --warmup 20 \
      --update deferred --threads "$t" --deposit-reduce binned --json 2>&1 >/dev/null \
      | awk -v L="$1" -v T="$t" '/^  total/{print L, T, $2, $3, $4}')
    [ -z "$row" ] && continue
    read -r l t2 w b tot <<<"$row"
    printf '  %-8s %4s %10.3f %10.3f %10.3f\n' "$l" "$t2" "$w" "$b" "$tot"
    jrow table=barrier-sweep lang="$l" threads="$t2" work="$w" barrier="$b" \
         total="$tot"
  done
}
sweep c "$C"; sweep go "$GO"; sweep java "$JAVA"; sweep csharp "$CS"
echo

echo "=== the per-phase barrier at T=32, where the two managed runtimes differ"
printf '  %-8s %-10s %10s %10s\n' lang phase work barrier
for pair in "c $C" "go $GO" "java $JAVA" "csharp $CS"; do
  set -- $pair
  [ -x "$2" ] || continue
  SLIMEBENCH_PHASE_STATS=1 "$2" --preset medium --ticks 60 --warmup 20 \
    --update deferred --threads 32 --deposit-reduce binned --json 2>&1 >/dev/null \
    | awk -v L="$1" '/^  (agents|prefix|scatter|deposit|merge|diffuse)/ \
        {print L, $1, $2, $3}' \
    | while read -r l ph w b; do
        printf '  %-8s %-10s %10.3f %10.3f\n' "$l" "$ph" "$w" "$b"
        jrow table=barrier-phase lang="$l" phase="$ph" work="$w" barrier="$b"
      done
done
echo
echo "Reading: work that halves as T doubles is a decomposition doing its job."
echo "Work that stops halving is not a barrier problem, whatever the barrier"
echo "column says next to it."
} | tee "$OUT"
echo "wrote $OUT" >&2
