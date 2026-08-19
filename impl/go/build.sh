#!/usr/bin/env bash
# slimebench Go build driver.
#
#   ./build.sh default
#   ./build.sh nobounds     -gcflags=-B, the closest Go has to Rust's unchecked
#
# Output is build/<profile>/slimebench, mirroring the other targets so
# bench/targets.toml can treat all of them the same way.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export PATH="$HOME/opt/go/bin:$PATH"

PROFILE="${1:-default}"
FLAGS=()
case "$PROFILE" in
  default)  ;;
  # -B disables bounds checking. Unlike Rust's `unchecked` feature this is a
  # compiler flag rather than a language construct, and Go documents it as
  # unsupported -- it is here to price the checks, not as a shipping config.
  nobounds) FLAGS=(-gcflags=all=-B) ;;
  *) echo "unknown profile '$PROFILE'" >&2; exit 2 ;;
esac

mkdir -p "build/$PROFILE"
go build "${FLAGS[@]}" -o "build/$PROFILE/slimebench" .
echo "built build/$PROFILE/slimebench"
