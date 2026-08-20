#!/usr/bin/env bash
# Can Lean tasks make the diffusion pass faster?
#
# This is the class P question for impl/lean, and it is not the question the
# other ports face. Everywhere else the obstacle is a barrier between workers
# sharing one grid. Lean has no shared mutable grid: arrays are reference
# counted and copy-on-write, so two tasks holding the same destination buffer
# would each copy it on the first write. The design space is ownership, not
# synchronisation.
#
# Three shapes, all bit-identical to the serial run, all reported:
#
#   striped boxed    grid as Array (Array Float32), one block per task
#   sliced boxed     flat shared Array Float32, per-task slice, concatenate
#   sliced unboxed   the same with f32 bit patterns in an Array UInt32
#
# usage: bench/lean-tasks.sh [outfile]
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
OUT="${1:-results/P-lean-tasks.txt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"

[ -d "$HOME/.elan/bin" ] && export PATH="$PATH:$HOME/.elan/bin"
if ! command -v lake >/dev/null 2>&1; then
  echo "skip: lake not found (install via elan)" >&2
  exit 0
fi

( cd impl/lean && lake build lean-tasks ) >/dev/null 2>&1 || {
  echo "error: lean-tasks failed to build" >&2; exit 1; }

# The scheduler size is the whole point of the experiment, so it is set
# explicitly rather than left to whatever the runtime picks.
{
  echo "# host: $(uname -sr)  cores: $(nproc)"
  for n in 1 16; do
    echo "# --- LEAN_NUM_THREADS=$n ---"
    LEAN_NUM_THREADS=$n ./impl/lean/.lake/build/bin/lean-tasks
  done
} | tee "$OUT"
echo "wrote $OUT" >&2
