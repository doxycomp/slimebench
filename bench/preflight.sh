#!/usr/bin/env bash
# What can this machine actually measure?
#
#   bench/preflight.sh
#
# Run before bench/full-run.sh on a machine it has not seen. It reports what is
# present, what is missing and which phases will be skipped -- rather than
# having the run discover that ninety minutes in, or worse, produce a plausible
# number for something that did not happen. (Both have happened here: see
# docs/RESULTS.md section 11.)
#
# Exits 0 always. Missing toolchains are a fact about the machine, not an error.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
[ -f "$HOME/.ghcup/env" ] && . "$HOME/.ghcup/env"
# pygame greets the community on import; not here.
export PYGAME_HIDE_SUPPORT_PROMPT=1

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m' "$1"; }

ok=0; missing=0
have_tool() { # name  cmd  what-it-unlocks
  printf '  %-14s ' "$1"
  if command -v "$2" >/dev/null 2>&1; then
    green "yes"; printf '  %s\n' "$(dim "$("$2" --version 2>/dev/null | head -1 | cut -c1-46)")"
    ok=$((ok + 1)); return 0
  fi
  red "no "; printf '   %s\n' "$(dim "-> $3")"
  missing=$((missing + 1)); return 1
}

have_lib() { # name  pkg-config-name  what-it-unlocks
  printf '  %-14s ' "$1"
  if pkg-config --exists "$2" 2>/dev/null; then
    green "yes"; printf '  %s\n' "$(dim "$(pkg-config --modversion "$2")")"
    ok=$((ok + 1)); return 0
  fi
  red "no "; printf '   %s\n' "$(dim "-> $3")"
  missing=$((missing + 1)); return 1
}

have_py() { # module  what-it-unlocks
  printf '  %-14s ' "python:$1"
  if python3 -c "import $1" >/dev/null 2>&1; then
    green "yes"; printf '\n'; ok=$((ok + 1)); return 0
  fi
  red "no "; printf '   %s\n' "$(dim "-> $2")"
  missing=$((missing + 1)); return 1
}

echo "=== platform ==="
printf '  %-14s %s\n' "kernel" "$(uname -sr)"
printf '  %-14s %s\n' "cpu" "$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | xargs)"
printf '  %-14s %s logical\n' "cores" "$(nproc)"
if grep -qi microsoft /proc/version 2>/dev/null; then
  printf '  %-14s %s\n' "wsl" "$(green yes) -- GL goes through Mesa's D3D12 translation"
  IS_WSL=1
else
  printf '  %-14s %s\n' "wsl" "no -- native GL"
  IS_WSL=0
fi
case "$PWD" in
  /mnt/*) printf '  %-14s %s\n' "filesystem" "$(red '9p bridge') -- run scripts/stage-wsl.sh first" ;;
  *)      printf '  %-14s %s\n' "filesystem" "$(green native)" ;;
esac

echo
# The same two $HOME toolchains full-run.sh adds, so preflight sees the
# PATH the run will see.
# Appended, not prepended, and that matters: the Swift toolchain ships its
# own clang 21, which would shadow the system clang 18 and silently change
# what the compiler matrix measured. These two entries exist to add `go`
# and `swiftc`, not to reorder anything already on PATH.
[ -d "$HOME/opt/go/bin" ]        && export PATH="$PATH:$HOME/opt/go/bin"
[ -d "$HOME/opt/swift/usr/bin" ] && export PATH="$PATH:$HOME/opt/swift/usr/bin"

echo "=== compilers ==="
have_tool "gcc"     gcc     "class S/P/V/R for C"
have_tool "clang"   clang   "the clang half of the compiler matrix"
have_tool "g++"     g++     "class S/P/V/R for C++"
have_tool "clang++" clang++ "the clang++ half of the compiler matrix"
have_tool "cargo"   cargo   "all Rust targets"
have_tool "ghc"     ghc     "all Haskell targets"
have_tool "node"    node    "class S and P for TypeScript"
have_tool "python3" python3 "class S/P/G/R for Python -- and the harness itself"
have_tool "perl"    perl    "class S/P/R for Perl"
have_tool "go"      go      "class S/P for Go"
have_tool "swiftc"  swiftc  "class S/P for Swift"
have_tool "nvcc"    nvcc    "class G via CUDA"

echo
echo "=== libraries ==="
have_lib  "SDL2"    sdl2    "class R (both backends) and the GL compute host"
have_lib  "raylib"  raylib  "the raylib half of class R"
have_py   numpy             "the numpy target, class P for Python, and pygl"
have_py   pygame            "class R for Python and the GL context for pygl"
have_py   pyray             "the raylib half of class R for Python"
have_py   OpenGL            "class G from Python (impl/pygl)"

printf '  %-14s ' "perl:Platypus"
if perl -MFFI::Platypus -e1 2>/dev/null; then
  green "yes"; printf '\n'; ok=$((ok + 1))
else
  red "no "; printf '   %s\n' "$(dim '-> class R for Perl; cpanm --local-lib=~/perl5 FFI::Platypus')"
  missing=$((missing + 1))
fi

printf '  %-14s ' "ghc:vector"
if ls impl/haskell/.ghc.environment.* >/dev/null 2>&1; then
  green "yes"; printf '\n'; ok=$((ok + 1))
else
  red "no "; printf '   %s\n' "$(dim '-> the idiomatic Haskell target; scripts/setup-wsl.sh haskell')"
  missing=$((missing + 1))
fi

# The two capabilities added since this file was written. Both are optional and
# both are the kind of thing that silently produces a missing phase rather than
# an error, which is what preflight exists to prevent.
printf '  %-14s ' "python3.14t"
FT="${SLIMEBENCH_PY314T:-$HOME/opt/ft314/bin/python}"
if [ -x "$FT" ] && "$FT" -c 'import sys, numpy; sys.exit(0 if not sys._is_gil_enabled() else 1)' 2>/dev/null; then
  green "yes"; printf '  %s
' "$(dim "$("$FT" -c 'import sys;print(sys.version.split()[0])') free-threaded, numpy present")"
  ok=$((ok + 1))
else
  red "no "; printf '   %s
' "$(dim '-> the no-GIL half of the class P matrix; uv venv --python 3.14t ~/opt/ft314 && uv pip install numpy')"
  missing=$((missing + 1))
fi

printf '  %-14s ' "avx512f"
if grep -qm1 ' avx512f' /proc/cpuinfo 2>/dev/null; then
  green "yes"; printf '  %s
' "$(dim 'impl/asm builds and --asm runs')"
  ok=$((ok + 1))
else
  red "no "; printf '   %s
' "$(dim '-> the hand-written assembly kernel; the class V table loses one column')"
  missing=$((missing + 1))
fi

echo
echo "=== display ==="
# Class R needs a window. Everything else is happy headless.
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  printf '  %-14s %s  %s\n' "display" "$(green yes)" \
    "$(dim "DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}")"
else
  printf '  %-14s %s   %s\n' "display" "$(red no)" \
    "$(dim '-> class R is skipped. Over SSH try `ssh -X`, or run on the console.')"
fi

echo
echo "=== GL renderer ==="
if command -v glxinfo >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  printf '  %-14s %s\n' "renderer" "$(glxinfo -B 2>/dev/null | awk -F': ' '/Device:|OpenGL renderer/{print $2; exit}')"
  printf '  %-14s %s\n' "version"  "$(glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL core profile version|OpenGL version/{print $2; exit}')"
  if [ "$IS_WSL" = 1 ]; then
    echo "  $(dim 'On WSL, set GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA')"
    echo "  $(dim 'to reach the discrete GPU; without it you get llvmpipe (software).')"
  fi
else
  echo "  $(dim 'glxinfo not installed (apt install mesa-utils) or no display.')"
  echo "  $(dim 'Not required -- every GL target prints its own renderer string.')"
fi

echo
echo "=== summary ==="
printf '  %d present, %d missing\n' "$ok" "$missing"
if [ "$missing" -eq 0 ]; then
  echo "  $(green 'Everything the full run touches is here.')"
else
  echo "  A missing toolchain only skips its own targets; the run still"
  echo "  produces a usable series for everything else."
fi
echo
echo "  next:  bench/full-run.sh"
