#!/usr/bin/env bash
# Build the raylib by-value shim as a shared object, for the Perl frontend.
#
# The Haskell frontend compiles raylib_shim.c straight into its binary (see
# impl/haskell/build.sh); Perl loads it with FFI::Platypus, so it needs a .so.
# One source, two consumers -- see the file's header for why it exists at all.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

CC=${CC:-gcc}
# pkg-config returns several flags in one string and the splitting is the
# point, so the unquoted expansion below is deliberate.
# shellcheck disable=SC2046
$CC -O2 -fPIC -shared -o libraylib_shim.so raylib_shim.c \
    $(pkg-config --cflags raylib 2>/dev/null || echo -I/usr/local/include) \
    -L/usr/local/lib -lraylib -lm
echo "built $(pwd)/libraylib_shim.so"
