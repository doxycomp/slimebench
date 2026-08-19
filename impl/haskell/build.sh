#!/usr/bin/env bash
# slimebench Haskell build driver.
#
#   ./build.sh o1
#   ./build.sh o2
#   ./build.sh o2-llvm
#   ./build.sh o2-llvm-vector    idiomatic style, src/MainVector.hs
#
# Output is build/<profile>/slimebench, mirroring the C/C++/Rust layout so
# bench/targets.toml can treat all of them the same way.
#
# ghc is invoked directly rather than through cabal: the low-level target needs
# nothing outside base + array + bytestring, and this keeps the optimisation
# profile a plain command-line flag instead of a package-description edit.
#
# The `-vector` profiles build the idiomatic implementation instead, which does
# need the `vector` package. It is picked up through the local package
# environment file that `scripts/setup-wsl.sh haskell` creates with
#   cabal install --lib vector --package-env .
# so the two styles still share one build driver and one output layout.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
[ -f "$HOME/.ghcup/env" ] && . "$HOME/.ghcup/env"

PROFILE="${1:-o2}"

MAIN=src/Main.hs
case "$PROFILE" in
  o0)             OPT=(-O0) ;;
  o1)             OPT=(-O1) ;;
  o2)             OPT=(-O2) ;;
  o2-llvm)        OPT=(-O2 -fllvm) ;;
  o2-vector)      OPT=(-O2);         MAIN=src/MainVector.hs ;;
  o2-llvm-vector) OPT=(-O2 -fllvm);  MAIN=src/MainVector.hs ;;
  *) echo "unknown profile '$PROFILE'" >&2; exit 2 ;;
esac

if [ "$MAIN" = src/MainVector.hs ] && ! ls .ghc.environment.* >/dev/null 2>&1; then
  echo "error: the idiomatic target needs the 'vector' package." >&2
  echo "       run: cabal install --lib vector --package-env ." >&2
  echo "       (from $PWD; or scripts/setup-wsl.sh haskell)" >&2
  exit 3
fi

# Ubuntu installs LLVM's tools under /usr/lib/llvm-<v>/bin and only symlinks a
# subset into /usr/bin -- opt and llc are not among them. GHC needs both on
# PATH for -fllvm, so find the newest versioned directory and prepend it.
if [[ "$PROFILE" == *llvm* ]] && ! command -v opt >/dev/null 2>&1; then
  for d in $(ls -d /usr/lib/llvm-*/bin 2>/dev/null | sort -V -r); do
    if [ -x "$d/opt" ] && [ -x "$d/llc" ]; then
      export PATH="$d:$PATH"
      echo "note: using LLVM from $d" >&2
      break
    fi
  done
fi
if [[ "$PROFILE" == *llvm* ]] && ! command -v opt >/dev/null 2>&1; then
  echo "error: -fllvm needs LLVM's opt and llc (apt install llvm)" >&2
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

# -threaded for class P. -rtsopts lets the binary accept +RTS -N, and the
# default stays -N1 so class S is never accidentally measured on a
# multi-capability runtime.
ghc "${OPT[@]}" \
    -threaded -rtsopts "-with-rtsopts=-N1" \
    -Wall -Wno-unused-imports \
    -isrc -outputdir "$OUT/obj" -o "$OUT/slimebench" \
    "${LINKDIRS[@]}" \
    "$MAIN"

echo "built $OUT/slimebench"
