#!/usr/bin/env bash
# slimebench Swift build driver.
#
#   ./build.sh release
#   ./build.sh unchecked     -Ounchecked
#
# Output is build/<profile>/slimebench, mirroring the other targets so
# bench/targets.toml can treat all of them the same way.
#
# A note on `unchecked`: -Ounchecked removes array bounds checks *and* integer
# overflow traps. The PRNG here relies on wrapping, but it spells that with
# `&*` and `&+`, which are wrapping in both modes -- so the flag changes only
# the bounds checks for this code. That is why the comparison is meaningful
# rather than a comparison of two different programs.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export PATH="$HOME/opt/swift/usr/bin:$PATH"

PROFILE="${1:-release}"
FLAGS=()
case "$PROFILE" in
  release)   ;;
  unchecked) FLAGS=(-Xswiftc -Ounchecked) ;;
  *) echo "unknown profile '$PROFILE'" >&2; exit 2 ;;
esac

swift build -c release "${FLAGS[@]}" --scratch-path ".build-$PROFILE"
mkdir -p "build/$PROFILE"
cp -f ".build-$PROFILE/release/slimebench" "build/$PROFILE/slimebench"
echo "built build/$PROFILE/slimebench"
