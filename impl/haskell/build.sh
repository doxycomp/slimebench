#!/usr/bin/env bash
# slimebench Haskell build driver.
#
#   ./build.sh o1
#   ./build.sh o2
#   ./build.sh o2-llvm
#
# Output is build/<profile>/slimebench, mirroring the C/C++/Rust layout so
# bench/targets.toml can treat all of them the same way.
#
# ghc is invoked directly rather than through cabal: there are no dependencies
# outside base + array + bytestring, and this keeps the optimisation profile a
# plain command-line flag instead of a package-description edit.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
[ -f "$HOME/.ghcup/env" ] && . "$HOME/.ghcup/env"

PROFILE="${1:-o2}"

case "$PROFILE" in
  o0)      OPT=(-O0) ;;
  o1)      OPT=(-O1) ;;
  o2)      OPT=(-O2) ;;
  o2-llvm) OPT=(-O2 -fllvm) ;;
  *) echo "unknown profile '$PROFILE'" >&2; exit 2 ;;
esac

if [ "$PROFILE" = "o2-llvm" ] && ! command -v opt >/dev/null 2>&1; then
  echo "error: -fllvm needs LLVM's opt/llc on PATH (apt install llvm-18)" >&2
  exit 3
fi

OUT="build/$PROFILE"
mkdir -p "$OUT/obj"

# GHC links against libgmp. Ubuntu ships libgmp.so.10 via libgmp10 but the
# unversioned libgmp.so only comes with libgmp-dev, and GHCup does not pull it
# in -- the failure shows up here, at link time. Rather than require root just
# to build, drop a symlink into a build-local directory and point the linker at
# it. scripts/setup-wsl.sh haskell installs libgmp-dev properly.
LINKDIRS=()
if ! ls /usr/lib/*/libgmp.so >/dev/null 2>&1 && ! ls /usr/lib/libgmp.so >/dev/null 2>&1; then
  real=$(ls /usr/lib/*/libgmp.so.10 2>/dev/null | head -1 || true)
  if [ -n "$real" ]; then
    mkdir -p build/.libshim
    ln -sf "$real" build/.libshim/libgmp.so
    LINKDIRS=(-optl-L"$PWD/build/.libshim")
    echo "note: libgmp-dev missing; using build-local libgmp.so shim" >&2
  fi
fi

ghc "${OPT[@]}" \
    -Wall -Wno-unused-imports \
    -isrc -outputdir "$OUT/obj" -o "$OUT/slimebench" \
    "${LINKDIRS[@]}" \
    src/Main.hs

echo "built $OUT/slimebench"
