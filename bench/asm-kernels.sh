#!/usr/bin/env bash
# The four-way diffusion-kernel comparison (benchmark class V).
#
#   scalar      the plain loop, whatever the compiler makes of it
#   simd        sb_simd.c, intrinsics, nine unaligned loads per vector
#   asm         impl/asm/sb_diffuse_avx512.S, three loads plus VALIGND
#
# times both compilers, and reports ms_diffuse rather than ms_total: the agent
# pass is identical in all three and would dilute the difference.
#
# usage: bench/asm-kernels.sh [outfile] [preset] [ticks]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/results/V-asm-kernels.jsonl}"
PRESET="${2:-medium}"
TICKS="${3:-100}"
REPS="${REPS:-3}"

: > "$OUT"
cd "$ROOT/impl/c" || exit 1

for cc in gcc clang; do
  command -v "$cc" >/dev/null 2>&1 || { echo "skip $cc (not installed)" >&2; continue; }
  make --no-print-directory CC=$cc PROFILE=o3-native ASM=1 headless >/dev/null 2>&1 || {
    echo "skip $cc (build failed)" >&2; continue; }
  BIN="build/$cc-o3-native-asm/slimebench-headless"
  for mode in --no-simd --simd --asm; do
    best=""
    for _ in $(seq "$REPS"); do
      line=$("$BIN" --preset "$PRESET" --ticks "$TICKS" --warmup 5 --json \
                    --update deferred "$mode" 2>/dev/null | tail -1)
      [ -z "$line" ] && continue
      d=$(echo "$line" | sed -n 's/.*"ms_diffuse":\([0-9.]*\).*/\1/p')
      if [ -z "$best" ] || awk "BEGIN{exit !($d < $bestd)}"; then best=$line; bestd=$d; fi
    done
    [ -z "$best" ] && { echo "  $cc $mode FAILED" >&2; continue; }
    echo "${best%\}}, \"cc\":\"$cc\", \"kernel\":\"${mode#--}\"}" >> "$OUT"
    printf '  %-6s %-9s diffuse %8.1f ms   total %8.1f ms   %s\n' \
      "$cc" "${mode#--}" "$bestd" \
      "$(echo "$best" | sed -n 's/.*"ms_total":\([0-9.]*\).*/\1/p')" \
      "$(echo "$best" | sed -n 's/.*"grid_hash":"\([^"]*\)".*/\1/p')" >&2
  done
done
echo "wrote $OUT" >&2
