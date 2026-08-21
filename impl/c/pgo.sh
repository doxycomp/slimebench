#!/usr/bin/env bash
# Profile-guided optimisation for the C target.
#
#   ./pgo.sh gcc     -> build/gcc-o3-native-pgo/slimebench-headless
#   ./pgo.sh clang   -> build/clang-o3-native-pgo/slimebench-headless
#
# Three stages: build instrumented, run a training workload, rebuild using the
# profile. gcc and clang disagree on every detail of this, hence the branch.
#
# The training run deliberately uses a *smaller* preset than the benchmark.
# PGO is meant to learn branch behaviour, not to memorise a working set, and a
# short run keeps the instrumented pass (which is several times slower) cheap.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

CC="${1:-gcc}"
BASE="-O3 -march=native -mtune=native"
FP="-ffp-contract=off -fno-fast-math"
COMMON="-std=c11 -D_POSIX_C_SOURCE=200809L $BASE $FP"
# Must match CORE_SRC in the Makefile. It did not: sb_simd.c and sb_asm.c
# were added to the Makefile and not here, so every PGO build since has failed
# to link with "undefined reference to sb_diffuse_rows_simd" -- and a
# build-failed target is a missing row in the results, not a failed run.
SRC="sb_core.c sb_cli.c sb_parallel.c sb_simd.c sb_asm.c main_headless.c"
OUT="build/$CC-o3-native-pgo"
PROF="build/.pgo-$CC"

TRAIN=(--preset tiny --ticks 120 --update serial)
TRAIN2=(--preset tiny --ticks 60 --update deferred)

rm -rf "$OUT" "$PROF"
mkdir -p "$OUT" "$PROF"

case "$CC" in
  gcc|gcc-*)
    echo "==> [1/3] instrumented build"
    $CC $COMMON -fprofile-generate="$PROF" $SRC -o "$OUT/train" -lm -lpthread
    echo "==> [2/3] training run"
    "$OUT/train" "${TRAIN[@]}"  >/dev/null
    "$OUT/train" "${TRAIN2[@]}" >/dev/null
    echo "==> [3/3] optimised build"
    # -fprofile-correction: the threaded run leaves counters updated from
    # several threads without locking, which gcc otherwise reports as corrupt.
    $CC $COMMON -fprofile-use="$PROF" -fprofile-correction \
        -Wno-missing-profile $SRC -o "$OUT/slimebench-headless" -lm -lpthread
    ;;
  clang|clang-*)
    LLVM_BIN=""
    command -v llvm-profdata >/dev/null 2>&1 || \
      for d in $(ls -d /usr/lib/llvm-*/bin 2>/dev/null | sort -V -r); do
        [ -x "$d/llvm-profdata" ] && { LLVM_BIN="$d/"; break; }
      done
    [ -n "$LLVM_BIN" ] || command -v llvm-profdata >/dev/null 2>&1 || {
      echo "error: llvm-profdata not found (apt install llvm)" >&2; exit 3; }

    echo "==> [1/3] instrumented build"
    $CC $COMMON -fprofile-instr-generate $SRC -o "$OUT/train" -lm -lpthread
    echo "==> [2/3] training run"
    LLVM_PROFILE_FILE="$PROF/train-1.profraw" "$OUT/train" "${TRAIN[@]}"  >/dev/null
    LLVM_PROFILE_FILE="$PROF/train-2.profraw" "$OUT/train" "${TRAIN2[@]}" >/dev/null
    "${LLVM_BIN}llvm-profdata" merge -output="$PROF/merged.profdata" "$PROF"/*.profraw
    echo "==> [3/3] optimised build"
    $CC $COMMON -fprofile-instr-use="$PROF/merged.profdata" \
        $SRC -o "$OUT/slimebench-headless" -lm -lpthread
    ;;
  *)
    echo "error: unknown compiler '$CC' (expected gcc or clang)" >&2
    exit 2
    ;;
esac

rm -f "$OUT/train"
echo "built $OUT/slimebench-headless"
