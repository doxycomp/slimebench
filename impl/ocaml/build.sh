#!/usr/bin/env bash
# slimebench OCaml build driver.
#
#   ./build.sh default   ocamlopt with bounds checks
#   ./build.sh unsafe    -unsafe, no array bounds checks
#   ./build.sh cstub         round to f32 through a C stub, not through Int32
#   ./build.sh cstub-unsafe  both
#
# The cstub profiles exist because OCaml 4.14's only rounding is *two* runtime
# calls where the hardware needs two instructions, and one call is cheaper than
# two. impl/ocaml/f32_stub.c has the microbenchmark.
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
F32=int32
case "$PROFILE" in
  default)      ;;
  unsafe)       FLAGS=(-unsafe) ;;
  cstub)        F32=cstub ;;
  cstub-unsafe) FLAGS=(-unsafe); F32=cstub ;;
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
SRC=(dirtable.ml sim.ml main.ml)

# The `cstub` profiles rewrite the one line that rounds to f32.
#
# A build-time rewrite rather than two source files or a runtime flag, because
# both alternatives would spoil the measurement: two files drift, and a runtime
# choice means a `float -> float` argument, which without flambda is an
# indirect call charged to both halves of the comparison. This way each build
# inlines its own rounding and the difference between them is one line. The
# grep is there so a rename in sim.ml fails the build instead of silently
# producing two identical binaries.
if [ "$F32" = cstub ]; then
  sed -i 's|^let\[@inline\] f32 (x : float) : float =.*|external f32 : float -> float = "sb_f32_byte" "sb_f32" [@@unboxed] [@@noalloc]|' "$OUT/sim.ml"
  grep -q '^external f32' "$OUT/sim.ml" || {
    echo "error: the f32 rewrite matched nothing -- did sim.ml change?" >&2
    exit 1
  }
  cp f32_stub.c "$OUT/"
  SRC=(f32_stub.c "${SRC[@]}")
fi

( cd "$OUT" && ocamlopt -I +unix "${FLAGS[@]}" -w +a-4-9-40..42-44-45-70 \
    -o slimebench unix.cmxa "${SRC[@]}" )
rm -f "$OUT"/*.ml "$OUT"/*.c "$OUT"/*.cmi "$OUT"/*.cmx "$OUT"/*.o
echo "built $OUT/slimebench (profile $PROFILE)"
