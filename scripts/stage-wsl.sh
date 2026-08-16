#!/usr/bin/env bash
# Copy the repo onto the Linux filesystem and run the harness there.
#
# Why this exists: the checkout lives on NTFS, reachable from WSL2 only through
# the 9p bridge at /mnt/c. Builds are several times slower there, and any
# benchmark that touches the filesystem measures the bridge instead of the
# code. The simulation itself is CPU-bound and would survive, but build times,
# binary sizes and process startup would all be polluted -- so stage first.
#
#   scripts/stage-wsl.sh                          # sync only
#   scripts/stage-wsl.sh bench --preset medium    # sync, then run the harness
#
# Results are copied back into results/ of the original checkout.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${SLIMEBENCH_STAGE:-$HOME/.cache/slimebench/work}"

case "$SRC" in
  /mnt/*) ;;
  *) echo "note: $SRC is already on the Linux filesystem; staging is unnecessary." >&2 ;;
esac

mkdir -p "$DEST"

echo "==> syncing $SRC -> $DEST"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude '.git/' \
    --exclude 'results/' \
    --exclude 'node_modules/' \
    --exclude 'build/' \
    --exclude 'target/' \
    --exclude 'dist-newstyle/' \
    "$SRC/" "$DEST/"
else
  # Fall back to tar so the script still works on a bare WSL install.
  ( cd "$SRC" && tar -cf - \
      --exclude=.git --exclude=results --exclude=node_modules \
      --exclude=build --exclude=target --exclude=dist-newstyle . ) \
    | ( cd "$DEST" && tar -xf - )
fi

mkdir -p "$DEST/results"

if [ $# -eq 0 ]; then
  echo "==> staged. Now:  cd $DEST && python3 bench/run.py bench --preset medium"
  exit 0
fi

echo "==> running: bench/run.py $*"
cd "$DEST"
python3 bench/run.py "$@"

echo "==> copying results back to $SRC/results/"
mkdir -p "$SRC/results"
cp -f "$DEST"/results/*.jsonl "$SRC/results/" 2>/dev/null || true
