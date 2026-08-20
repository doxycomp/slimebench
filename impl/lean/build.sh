#!/usr/bin/env bash
# slimebench Lean build driver.
#
# Lake has no notion of optimisation profiles the way cargo and the Makefiles
# here do -- Lean compiles through C and the interesting axis is what it hands
# the C compiler. So the profiles below are `leanc` optimisation levels, set
# through `moreLeancArgs`, which is the only knob that changes the generated
# machine code.
#
#   ./build.sh default
#   ./build.sh o3-native
#
# Output is build/<profile>/slimebench, mirroring the other targets so
# bench/targets.toml can treat them all the same way.

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
[ -d "$HOME/.elan/bin" ] && export PATH="$HOME/.elan/bin:$PATH"

PROFILE="${1:-default}"
case "$PROFILE" in
  default)   LEANC_ARGS="" ;;
  o3-native) LEANC_ARGS="-O3 -march=native" ;;
  *) echo "unknown profile '$PROFILE'" >&2; exit 2 ;;
esac

if ! command -v lake >/dev/null 2>&1; then
  echo "error: lake not found (install via elan: https://lean-lang.org)" >&2
  exit 1
fi

# Separate build directories per profile, so switching does not silently reuse
# objects compiled with different flags.
export LEAN_CC="${LEAN_CC:-cc}"
if [ -n "$LEANC_ARGS" ]; then
  lake build slimebench -- --moreLeancArgs="$LEANC_ARGS" || exit 1
else
  lake build slimebench || exit 1
fi

mkdir -p "build/$PROFILE"
cp -f .lake/build/bin/slimebench "build/$PROFILE/slimebench"
echo "built build/$PROFILE/slimebench"
