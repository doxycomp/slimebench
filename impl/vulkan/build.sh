#!/usr/bin/env bash
# slimebench -- build the Vulkan compute host.
#
#   ./build.sh [profile]        default: `default`
#
# The shaders are compiled with -O0 on purpose. glslc's optimiser reassociates
# past `precise` -- measured: -O gives a different grid hash on every device,
# including the software rasteriser, where -O0 is bit-exact with the C
# reference. And it buys nothing, because the driver recompiles the SPIR-V
# anyway: 35.5 ms against 36.0 on the RTX 5080 at `medium`, which is noise.
set -eu
cd -- "$(dirname -- "$0")"

PROFILE="${1:-default}"
case "$PROFILE" in
  default) OPT=(-O2) ;;
  o3)      OPT=(-O3 -march=native) ;;
  *) echo "unknown profile '$PROFILE'" >&2; exit 2 ;;
esac

OUT="build/$PROFILE"
mkdir -p "$OUT/spv"

python3 gen_shaders.py

for f in agents merge diffuse; do
  glslc -fshader-stage=compute --target-env=vulkan1.1 -O0 \
        "shaders/$f.comp" -o "$OUT/spv/$f.spv"
done

cc -std=c11 -Wall -Wextra -Wno-unused-parameter "${OPT[@]}" \
   -ffp-contract=off -fno-fast-math \
   -o "$OUT/slimebench-vk" slimebench_vk.c -lvulkan -lm

echo "built $OUT/slimebench-vk (profile $PROFILE)"
