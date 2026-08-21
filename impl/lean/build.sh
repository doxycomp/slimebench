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

# LEAN_CC is deliberately NOT set here.
#
# It used to be forced to `cc`, and that quietly broke the link on any machine
# without a system libc++: lake then invokes plain `cc -lc++ -lc++abi`, while
# those libraries live inside the Lean toolchain. `leanc` -- lake's default --
# is the wrapper that knows where they are. The failure only surfaced once a
# .lake cache was cleared, because every previous "success" was a binary
# linked before the export existed.
#
# Setting LIBRARY_PATH to the toolchain's lib directory looks like the fix and
# is worse: it puts that directory ahead of the system one for *every*
# library, so the linker also picks up the toolchain's Scrt1.o and glibc
# startup files, which are built against glibc 2.26 and fail against 2.39 with
# "undefined reference to __libc_csu_init".
#
# An explicitly exported LEAN_CC from the environment is still honoured, for
# anyone who does have a reason to override the driver.
if [ -n "$LEANC_ARGS" ]; then
  lake build slimebench -- --moreLeancArgs="$LEANC_ARGS" || exit 1
else
  lake build slimebench || exit 1
fi

mkdir -p "build/$PROFILE"
cp -f .lake/build/bin/slimebench "build/$PROFILE/slimebench"
echo "built build/$PROFILE/slimebench"
