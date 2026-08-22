#!/usr/bin/env bash
# Is any garbage collector in this benchmark doing anything?
#
# Six of the fourteen languages are garbage collected, and until this script
# existed the document never said whether that mattered. It does not, and the
# point is to establish that rather than assume it: the simulation allocates
# its grids and agent arrays once and writes into them for the rest of the run,
# so a collected runtime here runs with an idle collector.
#
# That is a limitation of this benchmark as a language comparison, not a
# property of the languages. Allocation rate, pause distribution and the
# throughput cost of a write barrier are among the biggest differences between
# these runtimes and C, and this workload exercises none of them. Saying so
# with numbers is more useful than saying it as a caveat.
#
# usage: bench/gc-stats.sh [outfile]
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
OUT="${1:-results/S-gc-stats.txt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"
# shellcheck source=bench/jsonl.sh
. "$(dirname "$0")/jsonl.sh"
jsonl_for "$OUT"

[ -d "$HOME/opt/go/bin" ] && export PATH="$PATH:$HOME/opt/go/bin"
[ -f "$HOME/.ghcup/env" ] && . "$HOME/.ghcup/env"

CFG=(--preset tiny --ticks 200 --warmup 20 --update deferred --json)

{
echo "# host: $(uname -sr)"
echo "# tiny (512x512, 65 536 agents), 200 ticks, 20 warm-up"
echo

echo "=== collected runtimes, instrumented (SLIMEBENCH_GC_STATS=1)"
run() { # label binary...
  local label=$1; shift
  [ -x "$1" ] || { printf '  %-10s not built\n' "$label"; return; }
  local line
  line=$(SLIMEBENCH_GC_STATS=1 "$@" "${CFG[@]}" 2>&1 >/dev/null | grep -m1 '^gc_stats')
  printf '  %-10s %s\n' "$label" "${line:-no gc_stats output}"
  # The runtimes already report key=value pairs; jrow takes them as they are,
  # so a runtime that reports a field the others do not keeps it.
  # shellcheck disable=SC2086
  [ -n "$line" ] && jrow table=gc lang="$label" ${line#gc_stats }
}
run go     impl/go/build/nobounds/slimebench
run java   impl/java/build/c2/slimebench
run csharp impl/csharp/build/aot-native/slimebench
run ocaml  impl/ocaml/build/unsafe/slimebench
echo

# GHC reports collector statistics itself, so the Haskell target needs no
# instrumentation -- only a binary linked with -rtsopts.
echo "=== haskell, from the RTS"
HS=impl/haskell/build/o2-llvm/slimebench
if [ -x "$HS" ] && "$HS" "${CFG[@]}" +RTS -s -RTS >/dev/null 2>/tmp/sb-hs-rts; then
  grep -E 'bytes allocated|collections|Total.*elapsed|GC .*time' /tmp/sb-hs-rts \
    | head -6 | sed 's/^/  /'
  # GHC's -s output is prose, not key=value, so the three numbers the table
  # uses are pulled out here rather than in the generator.
  jrow table=gc lang=haskell \
    allocated_bytes="$(sed -n 's/^ *\([0-9,]*\) bytes allocated in the heap.*/\1/p' \
                        /tmp/sb-hs-rts | head -1 | tr -d ,)" \
    gc_seconds="$(sed -n 's/^ *GC *time *\([0-9.]*\)s.*/\1/p' \
                   /tmp/sb-hs-rts | head -1)" \
    total_seconds="$(sed -n 's/^ *Total *time *\([0-9.]*\)s.*/\1/p' \
                      /tmp/sb-hs-rts | head -1)"
  rm -f /tmp/sb-hs-rts
else
  echo "  not built, or not linked with -rtsopts"
fi
echo

echo "=== the control: no collector at all"
echo "  c, c++, rust, fortran, swift and the two Python targets have no"
echo "  garbage collector on this path. Their allocation after startup is"
echo "  zero by construction, which is what the rows above converge to."
echo

echo "Reading: a collection count in single digits over 200 ticks, and a total"
echo "GC time under a millisecond, mean the collector is idle. Whatever these"
echo "numbers say about the runtimes, they do not say it about their"
echo "collectors -- so docs/RESULTS.md should not, either."
} | tee "$OUT"
echo "wrote $OUT" >&2
