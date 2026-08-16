#!/usr/bin/env bash
# slimebench Rust build driver.
#
# Cargo has no way to attach RUSTFLAGS to a named profile, and the bounds-check
# variant is a feature rather than a profile, so the profile axis of the
# benchmark matrix is expanded here instead of in Cargo.toml.
#
#   ./build.sh release
#   ./build.sh release-native-unchecked
#
# Output is always build/<profile>/slimebench, mirroring the C and C++ layout
# so bench/targets.toml can treat all three the same way.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

PROFILE="${1:-release}"

cargo_profile=release
features=()
rustflags=""

case "$PROFILE" in
  debug)                     cargo_profile=dev ;;
  release)                   ;;
  release-unchecked)         features=(unchecked) ;;
  release-native)            rustflags="-C target-cpu=native" ;;
  release-native-unchecked)  rustflags="-C target-cpu=native"; features=(unchecked) ;;
  release-lto)               cargo_profile=release-lto ;;
  release-native-lto)        cargo_profile=release-lto; rustflags="-C target-cpu=native" ;;
  release-native-lto-unchecked)
                             cargo_profile=release-lto; rustflags="-C target-cpu=native"
                             features=(unchecked) ;;
  *) echo "unknown profile '$PROFILE'" >&2; exit 2 ;;
esac

# Separate target dirs: changing RUSTFLAGS or features invalidates the cache,
# and sharing one dir would make every matrix entry a full rebuild.
target_dir="target/$PROFILE"

args=(build --profile "$cargo_profile" --target-dir "$target_dir")
if [ ${#features[@]} -gt 0 ]; then
  args+=(--features "$(IFS=,; echo "${features[*]}")")
fi

if [ -n "$rustflags" ]; then
  RUSTFLAGS="$rustflags" cargo "${args[@]}"
else
  cargo "${args[@]}"
fi

# cargo puts dev builds under debug/, everything else under the profile name.
case "$cargo_profile" in
  dev) built="$target_dir/debug/slimebench" ;;
  *)   built="$target_dir/$cargo_profile/slimebench" ;;
esac

mkdir -p "build/$PROFILE"
cp -f "$built" "build/$PROFILE/slimebench"
echo "built build/$PROFILE/slimebench"
