#!/usr/bin/env bash
# One consistent measurement of everything, in one sitting.
#
#   bench/full-run.sh [outdir]
#
# The numbers in docs/RESULTS.md accumulated over a dozen sessions on
# different days, which is fine for comparisons drawn *inside* one series and
# misleading for anything drawn across two. This produces one series: every
# class, every language, one machine state, one timestamp.
#
# Run it from the Linux filesystem (scripts/stage-wsl.sh) -- on the 9p bridge
# the build times and binary sizes measure the bridge.
#
# Roughly 90 minutes. Each phase writes its own .jsonl as it finishes, so an
# interrupted run still leaves usable output.

set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

OUT=${1:-results/run-$(date +%Y%m%d-%H%M)}
mkdir -p "$OUT"
echo "==> writing to $OUT"

export LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH:-}
export PERL5LIB="$HOME/perl5/lib/perl5:${PERL5LIB:-}"
export PATH=/usr/local/cuda/bin:$PATH
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
[ -f "$HOME/.ghcup/env" ] && . "$HOME/.ghcup/env"

# Machine and toolchain state, recorded once so the numbers stay attributable.
{
  echo "date        $(date -Is)"
  echo "host        $(uname -srm)"
  echo "cpu         $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | xargs)"
  echo "cores       $(nproc) logical"
  echo "mem         $(awk '/MemTotal/{printf "%.0f GiB", $2/1048576}' /proc/meminfo)"
  echo "gcc         $(gcc -dumpversion 2>/dev/null)"
  echo "clang       $(clang -dumpversion 2>/dev/null)"
  echo "rustc       $(rustc --version 2>/dev/null | awk '{print $2}')"
  echo "ghc         $(ghc --numeric-version 2>/dev/null)"
  echo "node        $(node --version 2>/dev/null)"
  echo "python      $(python3 -V 2>&1 | awk '{print $2}')"
  echo "perl        $(perl -e 'print $^V' 2>/dev/null)"
  echo "nvcc        $(nvcc --version 2>/dev/null | awk '/release/{print $6}')"
  # SLIMEBENCH_COMMIT lets the launcher pass it in: the staged copy has no
  # .git, and a run whose numbers cannot be tied to a revision is a
  # transcript rather than a measurement.
  echo "commit      ${SLIMEBENCH_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
} | tee "$OUT/environment.txt"
echo

phase() { echo; echo "=== $* ==="; }

# ---- 1. cross-language, class S -----------------------------------------
# 256x256 with 16 384 agents: the largest size pure Python and Perl finish in
# seconds, which is the only reason all of them fit in one table.
phase "class S, all languages, 256x256"
for upd in serial deferred; do
  python3 bench/run.py bench --width 256 --height 256 --agents 16384 \
    --ticks 100 --reps 3 --update "$upd" \
    --out "$OUT/A-crosslang-$upd.jsonl" || true
done

# ---- 2. compiler matrix --------------------------------------------------
phase "compiler matrix, 1024x1024, 300 ticks"
python3 bench/run.py bench --preset small --ticks 300 --reps 3 \
  --targets c,cpp,rust,haskell,haskell-vector,c-pgo \
  --out "$OUT/C-compiler-matrix.jsonl" || true

# ---- 3. class V ----------------------------------------------------------
phase "class V (SIMD), 1024x1024, 300 ticks"
python3 bench/run.py bench --preset small --ticks 300 --reps 3 \
  --targets c-simd,cpp-simd,rust-simd \
  --out "$OUT/G-simd.jsonl" || true

# ---- 4. class P ----------------------------------------------------------
# One thread sweep per language. Perl runs at `tiny`: `medium` there is hours,
# and the shape of its curve is the datapoint, not a cross-language absolute.
phase "class P, thread sweep"
: > "$OUT/P-parallel.jsonl"
psweep() { # label preset ticks extra-args... -- cmd...
  local label=$1 preset=$2 ticks=$3; shift 3
  local -a red=()
  while [ "$1" != "--" ]; do red+=("$1"); shift; done
  shift
  for t in 1 2 4 8 16 32; do
    for r in "${red[@]}"; do
      [ "$t" = 1 ] && [ "$r" != "${red[0]}" ] && continue
      local -a args=(--preset "$preset" --ticks "$ticks" --update deferred)
      [ "$t" -gt 1 ] && args+=(--threads "$t")
      [ "$t" -gt 1 ] && [ -n "$r" ] && args+=(--deposit-reduce "$r")
      local j
      j=$(timeout 3600 "$@" "${args[@]}" --json 2>/dev/null | grep -m1 '^{') || continue
      [ -z "$j" ] && continue
      echo "$j" | LBL="$label" T="$t" python3 -c "
import sys, json, os
d = json.load(sys.stdin)
d['lang_label'] = os.environ['LBL']; d['threads'] = int(os.environ['T'])
print(json.dumps(d))" >> "$OUT/P-parallel.jsonl"
      printf "  %-12s T=%-3s %-8s %8.0f ms\n" "$label" "$t" "$r" \
        "$(echo "$j" | python3 -c 'import sys,json; print(json.load(sys.stdin)["ms_total"])')"
    done
  done
}
psweep c       medium 100 binned private -- impl/c/build/gcc-o3-native/slimebench-headless
psweep cpp     medium 100 binned private -- impl/cpp/build/g++-o3-native/slimebench-headless
psweep rust    medium 100 binned private -- impl/rust/build/release-native-unchecked/slimebench
psweep haskell medium 100 binned private -- impl/haskell/build/o2-llvm/slimebench
psweep ts      medium 100 binned private -- node --experimental-strip-types --no-warnings impl/ts/src/main-node.ts
psweep python  medium 100 binned private -- python3 impl/python/slimebench_numpy.py
psweep perl    tiny    20 ""              -- perl impl/perl/slimebench.pl

# ---- 5. class G ----------------------------------------------------------
phase "class G, every preset"
: > "$OUT/H-gpu.jsonl"
gpu() { # label cmd...
  local label=$1; shift
  for p in tiny small medium large huge; do
    local j
    j=$(timeout 3600 "$@" --preset "$p" --ticks 100 --update deferred --json 2>/dev/null \
        | grep -m1 '^{') || continue
    [ -z "$j" ] && continue
    echo "$j" | LBL="$label" python3 -c "
import sys, json, os
d = json.load(sys.stdin); d['lang_label'] = os.environ['LBL']
print(json.dumps(d))" >> "$OUT/H-gpu.jsonl"
    printf "  %-14s %-7s %8.0f ms  %9.0f MCUPS\n" "$label" "$p" \
      "$(echo "$j" | python3 -c 'import sys,json; print(json.load(sys.stdin)["ms_total"])')" \
      "$(echo "$j" | python3 -c 'import sys,json; print(json.load(sys.stdin)["mcups"])')"
  done
}
export GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA
gpu "cuda"        impl/cuda/build/default/slimebench-cuda
gpu "gl43 C"      impl/glcompute/build/default/slimebench-gl
gpu "gl43 Python" python3 impl/pygl/slimebench_pygl.py
unset GALLIUM_DRIVER MESA_D3D12_DEFAULT_ADAPTER_NAME

# ---- 6. class R ----------------------------------------------------------
phase "class R, both backends, both renderers"
: > "$OUT/Q-render.jsonl"
render() { # lang label cmd...
  local lang=$1 label=$2; shift 2
  local n=200; [ "$lang" = perl ] && n=20
  local j
  j=$(timeout 900 "$@" --preset small --ticks "$n" --freeze-sim --json 2>/dev/null \
      | grep -m1 '^{') || { echo "  $label FAILED"; return; }
  [ -z "$j" ] && { echo "  $label no json"; return; }
  echo "$j" | RL="$RLABEL" python3 -c "
import sys, json, os
d = json.load(sys.stdin); d['renderer'] = os.environ['RL']
print(json.dumps(d))" >> "$OUT/Q-render.jsonl"
  echo "$j" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  {d['impl']:8s} {d['backend']:8s} {d['ms_render_median']:9.3f} ms  {d['fps_equiv']:8.1f} fps\")"
}
render_all() {
  render c       c-sdl2      impl/c/build/gcc-o3-native/slimebench-sdl2
  render c       c-raylib    impl/c/build/gcc-o3-native/slimebench-raylib
  render cpp     cpp-sdl2    impl/cpp/build/g++-o3-native/slimebench-sdl2
  render cpp     cpp-raylib  impl/cpp/build/g++-o3-native/slimebench-raylib
  render rust    rs-sdl2     impl/rust/target/release/slimebench-sdl2
  render rust    rs-raylib   impl/rust/target/release/slimebench-raylib
  render haskell hs-sdl2     impl/haskell/build/o2-sdl2/slimebench-sdl2
  render haskell hs-raylib   impl/haskell/build/o2-raylib/slimebench-raylib
  render python  py-pygame   python3 impl/python/slimebench_pygame.py
  render python  py-raylib   python3 impl/python/slimebench_pyray.py
  render perl    pl-sdl2     perl impl/perl/slimebench-render.pl --backend sdl2
  render perl    pl-raylib   perl impl/perl/slimebench-render.pl --backend raylib
}
echo "  -- llvmpipe --"
unset GALLIUM_DRIVER MESA_D3D12_DEFAULT_ADAPTER_NAME
RLABEL="llvmpipe" render_all
echo "  -- RTX 5080 via D3D12 --"
export GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA
RLABEL="D3D12 NVIDIA RTX 5080" render_all
unset GALLIUM_DRIVER MESA_D3D12_DEFAULT_ADAPTER_NAME

echo
echo "==> done. $(cat "$OUT"/*.jsonl 2>/dev/null | wc -l) rows in $OUT"
ls -1 "$OUT"
