#!/usr/bin/env bash
# slimebench -- what this machine is worth, and whether it computes correctly.
#
# Every other phase in bench/ varies the language or the compiler and holds the
# machine fixed. This one does the opposite: one implementation, one set of
# parameters, and the only variable is the computer it runs on. Two numbers a
# reader can compare against another machine, and one answer that is not a
# number at all.
#
#   1. one core        the serial kernel, nothing hidden behind parallelism
#   2. all cores       the same work across every hardware thread
#   3. memory-bound    a grid four times the last level cache, where the
#                      answer is the memory system rather than the core
#   4. GPU             the identical computation in VRAM, when there is one
#   5. correctness     every result checked against a recorded chain
#
# The fifth is the one this project can do and a benchmark normally cannot.
# SPEC-1 makes the result machine-independent, so a chain recorded once is a
# reference everywhere; see impl/c/sb_verify.h for what that catches and what
# it does not.
#
#   bench/machine.sh                     # measure and verify
#   bench/machine.sh --no-verify         # measure only
#   bench/machine.sh --record            # record a new reference chain
#
set -u

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT" || exit 1

CHAIN=spec/testvectors/machine.chain
VERIFY=1
RECORD=0
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-verify) VERIFY=0; shift ;;
    --record)    RECORD=1; shift ;;
    -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
    *)           OUT=$1; shift ;;
  esac
done

C=impl/c/build/gcc-o3-native/slimebench-headless
if [ ! -x "$C" ]; then
  echo "error: $C is not built. Run: (cd impl/c && make CC=gcc PROFILE=o3-native)" >&2
  exit 2
fi

CORES=$(nproc)

# The verification configuration is deliberately small: a chain has to be
# recordable and checkable in seconds, or nobody runs it before a long job.
# The load test is the measurement phases above it, which run the same code.
VCFG=(--preset small --ticks 200 --update deferred --seed 12345)

if [ "$RECORD" = 1 ]; then
  mkdir -p "$(dirname "$CHAIN")"
  echo "recording $CHAIN from this machine"
  echo "  only do this on a machine that passes bench/run.py conformance --"
  echo "  a fault baked into the reference is a fault nothing will ever find."
  "$C" "${VCFG[@]}" --emit-chain "$CHAIN" --json >/dev/null || exit 1
  wc -l < "$CHAIN" | xargs printf "  %s lines\n"
  exit 0
fi

emit() { [ -n "$OUT" ] && printf '%s\n' "$*" >> "$OUT"; printf '%s\n' "$*"; }
[ -n "$OUT" ] && : > "$OUT"

emit "# slimebench machine report"
emit "# host   $(uname -sr)  $(nproc) logical cores"
emit "# cpu    $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
emit "# mem    $(awk '/MemTotal/{printf "%.0f GiB", $2/1048576}' /proc/meminfo)"
emit "# date   $(date -Is)"
emit ""

# MCUPS -- million cell updates per second -- is the figure that survives a
# change of grid size, which a millisecond total does not.
run() { # label extra-args...
  local label=$1; shift
  local j
  j=$("$C" "$@" --json 2>/dev/null | grep -m1 '^{') || j=""
  if [ -z "$j" ]; then
    emit "$(printf '  %-22s  %s' "$label" "did not run")"
    return
  fi
  echo "$j" | LBL="$label" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
print("  %-22s  %9.1f MCUPS  %8.1f ms  %s"
      % (os.environ["LBL"], d["mcups"], d["ms_total"], d["grid_hash"]))' \
    | while read -r line; do emit "$line"; done
}

emit "== throughput =="
run "one core"      --preset medium --ticks 100 --update deferred --threads 1
run "all cores"     --preset medium --ticks 100 --update deferred \
                    --threads "$CORES" --deposit-reduce binned
# Four times the last level cache on most parts, and the phase where the
# ordering earns its keep -- see docs/RESULTS.md section 8.
run "memory bound"  --preset large --ticks 50 --update deferred \
                    --agent-tile 2
emit ""

emit "== gpu =="
CUDA=impl/cuda/build/default/slimebench-cuda
GL=impl/glcompute/build/default/slimebench-gl
if [ -x "$CUDA" ]; then
  C_SAVE=$C; C=$CUDA
  run "cuda"        --preset medium --ticks 100 --update deferred
  C=$C_SAVE
else
  emit "  cuda                    not built"
fi
if [ -x "$GL" ]; then
  C_SAVE=$C; C=$GL
  run "gl 4.3 compute" --preset medium --ticks 100 --update deferred
  C=$C_SAVE
else
  emit "  gl 4.3 compute          not built"
fi
# Vulkan by device kind rather than by index, and every kind the machine has:
# this is the row that makes the report about the computer rather than about
# one vendor's GPU.
VK=impl/vulkan/build/default/slimebench-vk
if [ -x "$VK" ]; then
  C_SAVE=$C; C=$VK
  for kind in discrete integrated cpu; do
    run "vulkan $kind" --preset medium --ticks 100 --update deferred \
                       --device "$kind"
  done
  C=$C_SAVE
else
  emit "  vulkan                  not built"
fi
emit ""

if [ "$VERIFY" = 1 ]; then
  emit "== correctness =="
  if [ ! -f "$CHAIN" ]; then
    emit "  no reference chain at $CHAIN"
    emit "  record one on a known-good machine: bench/machine.sh --record"
  else
    # Serial and threaded both, because a fault that only appears under load on
    # every core is the fault people actually have.
    for cfgname in "one core:--threads 1" "all cores:--threads $CORES --deposit-reduce binned"; do
      name=${cfgname%%:*}; args=${cfgname#*:}
      # shellcheck disable=SC2086
      if "$C" "${VCFG[@]}" $args --verify "$CHAIN" --json >/dev/null 2>"$OUT.v"; then
        emit "$(printf '  %-22s  %s' "$name" "OK")"
      else
        emit "$(printf '  %-22s  %s' "$name" "MISMATCH")"
        sed 's/^/    /' "$OUT.v" | while read -r l; do emit "$l"; done
      fi
    done
    rm -f "$OUT.v"
  fi
fi

emit ""
emit "Reading: MCUPS is comparable between machines, milliseconds are not."
emit "A MISMATCH is not a slow machine, it is a wrong one -- unstable memory,"
emit "an overclock past its limit, or a part that is failing. impl/c/sb_verify.h"
emit "says what that does and does not distinguish."
[ -n "$OUT" ] && echo "wrote $OUT" >&2
exit 0
