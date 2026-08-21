#!/usr/bin/env bash
# slimebench OCaml build driver.
#
#   ./build.sh default   ocamlopt with bounds checks
#   ./build.sh unsafe    -unsafe, no array bounds checks
#
# `unsafe` is OCaml's equivalent of Rust's unchecked feature and Go's
# -gcflags=-B, and it is here for the same reason: to price the checks on this
# workload, next to the numbers section 3 of docs/RESULTS.md already has for
# the other three.
#
# No dune, no opam, no ocamlfind. This port depends on nothing beyond `unix`,
# which ships with the compiler, so one ocamlopt invocation is the honest
# build and anyone with ocaml-nox installed can run it.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PROFILE="${1:-default}"
FLAGS=()
case "$PROFILE" in
  default) ;;
  unsafe)  FLAGS=(-unsafe) ;;
  *) echo "unknown profile '$PROFILE'" >&2; exit 2 ;;
esac

# -O3 is a flambda flag. On a compiler built without flambda it is an error
# rather than a no-op, so ask before passing it. The stock ocaml-nox package
# has no flambda, which is itself a measurement -- see the module header of
# sim.ml for what that costs the f32 rounding.
if ocamlopt -config | grep -q '^flambda: true'; then
  FLAGS+=(-O3)
fi

OUT="build/$PROFILE"
mkdir -p "$OUT"

# Build inside $OUT so the .cmi/.cmx/.o files land there rather than beside
# the sources, and so two profiles cannot pick up each other's artefacts.
cp dirtable.ml sim.ml main.ml "$OUT/"
( cd "$OUT" && ocamlopt -I +unix "${FLAGS[@]}" -w +a-4-9-40..42-44-45-70 \
    -o slimebench unix.cmxa dirtable.ml sim.ml main.ml )
rm -f "$OUT"/*.ml "$OUT"/*.cmi "$OUT"/*.cmx "$OUT"/*.o
echo "built $OUT/slimebench (profile $PROFILE)"
