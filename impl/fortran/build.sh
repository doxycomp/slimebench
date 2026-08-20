#!/usr/bin/env bash
# slimebench Fortran build driver.
#
#   ./build.sh o2            -O2
#   ./build.sh o3            -O3
#   ./build.sh o3-native     -O3 -march=native
#   ./build.sh ofast-native  -Ofast -march=native  -- NOT tier A, see below
#
# -ffp-contract=off is on every profile except ofast-native, and it is not
# optional. The Fortran standard lets a processor evaluate an expression any
# mathematically equivalent way, and gfortran takes that as licence to fuse
# `acc + 4.0*g` into one FMA with one rounding. The stencil then computes a
# different number from every other port in this project, the grid hash moves,
# and nothing else looks wrong. This is the same flag the C reference needs
# and the same reason.
#
# ofast-native is the deliberate counterexample: -Ofast implies
# -ffast-math, which reassociates the nine-term sum. It is conformance tier C
# and bench/targets.toml marks it as such.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PROFILE="${1:-o2}"
FLAGS=(-ffp-contract=off)
case "$PROFILE" in
  o2)            FLAGS+=(-O2) ;;
  o3)            FLAGS+=(-O3) ;;
  o3-native)     FLAGS+=(-O3 -march=native) ;;
  ofast-native)  FLAGS=(-Ofast -march=native) ;;
  *) echo "unknown profile '$PROFILE'" >&2; exit 2 ;;
esac

OUT="build/$PROFILE"
mkdir -p "$OUT"

# -J puts the .mod files in the profile directory, so two profiles cannot pick
# up each other's module interfaces.
gfortran "${FLAGS[@]}" -std=f2008 -Wall -Wno-compare-reals -J "$OUT" \
  -o "$OUT/slimebench" dirtable.f90 sim.f90 main.f90
echo "built $OUT/slimebench (profile $PROFILE)"
