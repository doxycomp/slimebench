#!/usr/bin/env bash
# The free-threading experiment: {GIL, no-GIL} x {threads, processes} x T.
#
# Everything else is held fixed -- same source, same Worker, same reduction,
# same host. The only variables are the interpreter and what carries the
# workers, so a difference between two cells is attributable.
#
# usage: bench/gil-matrix.sh [outfile] [preset] [ticks]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/results/P-gil-matrix.jsonl}"
PRESET="${2:-small}"
TICKS="${3:-100}"

GIL_PY="${SLIMEBENCH_PY312:-python3}"
FT_PY="${SLIMEBENCH_PY314T:-$HOME/opt/ft314/bin/python}"

: > "$OUT"
cd "$ROOT/impl/python" || exit 1

probe() {   # interpreter -> "ok" or a reason to skip
  "$1" -c 'import numpy' >/dev/null 2>&1 || { echo "no numpy"; return; }
  echo ok
}

one() {   # $1 interpreter, $2 label, $3 backend, $4 threads, $5 reduce
  local py=$1 tag=$2 be=$3 t=$4 red=$5
  local args=(--preset "$PRESET" --ticks "$TICKS" --warmup 5 --json --update deferred)
  if [ "$t" -gt 1 ]; then
    args+=(--threads "$t" --deposit-reduce "$red" --mp-backend "$be")
  fi
  local line
  line=$(timeout 1800 "$py" slimebench_numpy.py "${args[@]}" 2>/dev/null | tail -1)
  if [ -z "$line" ]; then
    printf '  %-8s %-9s T=%-2d %-7s FAILED\n' "$tag" "$be" "$t" "$red" >&2
    return
  fi
  # Tag the row with the interpreter so the matrix is reconstructable.
  echo "${line%\}}, \"interp\":\"$tag\", \"mp_backend\":\"$be\"}" >> "$OUT"
  printf '  %-8s %-9s T=%-2d %-7s %8.1f ms\n' "$tag" "$be" "$t" "$red" \
    "$(echo "$line" | sed -n 's/.*"ms_total":\([0-9.]*\).*/\1/p')" >&2
}

for spec in "gil:$GIL_PY" "nogil:$FT_PY"; do
  tag=${spec%%:*}; py=${spec#*:}
  why=$(probe "$py")
  if [ "$why" != ok ]; then
    echo "skip $tag ($py): $why" >&2
    continue
  fi
  echo "$tag -- $("$py" -c 'import sys;print(sys.version.split()[0])') gil=$("$py" -c 'import sys;print(getattr(sys,"_is_gil_enabled",lambda:True)())')" >&2
  one "$py" "$tag" serial 1 scalar
  for t in 2 4 8 16; do
    for be in threads processes; do
      for red in binned private; do
        one "$py" "$tag" "$be" "$t" "$red"
      done
    done
  done
done
echo "wrote $OUT" >&2
