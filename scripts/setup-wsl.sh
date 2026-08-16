#!/usr/bin/env bash
# Install the toolchains slimebench needs on Ubuntu/WSL2.
#
# Idempotent: re-running only installs what is missing. Nothing here is
# required for the C and TypeScript targets -- those work with the base
# gcc/node install. Everything else corresponds to a phase of
# docs/BUILDPLAN.md, so install as you go rather than all at once.
#
#   scripts/setup-wsl.sh base       gcc, clang, make, cmake, ninja, hyperfine
#   scripts/setup-wsl.sh render     SDL2 + raylib
#   scripts/setup-wsl.sh rust
#   scripts/setup-wsl.sh haskell
#   scripts/setup-wsl.sh scripting  perl SDL/raylib bindings, python numpy
#   scripts/setup-wsl.sh gpu        Vulkan/OpenGL compute prerequisites
#   scripts/setup-wsl.sh all

set -euo pipefail

RAYLIB_VERSION=5.5

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  local missing=()
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    echo "  already installed: $*"
    return
  fi
  echo "  installing: ${missing[*]}"
  sudo apt-get install -y "${missing[@]}"
}

need_apt_update() {
  # Refresh at most once per run, and only if the lists are older than a day.
  if [ -z "${_APT_UPDATED:-}" ]; then
    if [ ! -d /var/lib/apt/lists ] || \
       [ -z "$(find /var/lib/apt/lists -maxdepth 1 -mtime -1 -name '*Packages*' 2>/dev/null)" ]; then
      sudo apt-get update
    fi
    _APT_UPDATED=1
  fi
}

setup_base() {
  log "base toolchain"
  need_apt_update
  apt_install build-essential clang lld cmake ninja-build pkg-config git \
              linux-tools-common time
  if ! have hyperfine; then
    echo "  installing hyperfine from GitHub release (not in Ubuntu 24.04 repos)"
    local tmp deb
    tmp=$(mktemp -d)
    deb="$tmp/hyperfine.deb"
    curl -fsSL -o "$deb" \
      https://github.com/sharkdp/hyperfine/releases/download/v1.19.0/hyperfine_1.19.0_amd64.deb
    sudo dpkg -i "$deb"
    rm -rf "$tmp"
  else
    echo "  already installed: hyperfine"
  fi
  warn "perf is not shipped for the WSL2 kernel; use hyperfine and the built-in"
  warn "per-phase timers instead. For perf you would need a custom WSL kernel."
}

setup_render() {
  log "rendering backends"
  need_apt_update
  apt_install libsdl2-dev libsdl2-image-dev

  if pkg-config --exists raylib; then
    echo "  already installed: raylib $(pkg-config --modversion raylib)"
    return
  fi
  # raylib is not packaged for Ubuntu 24.04; build the release tag from source.
  echo "  building raylib ${RAYLIB_VERSION} from source"
  apt_install libasound2-dev libx11-dev libxrandr-dev libxi-dev libgl1-mesa-dev \
              libglu1-mesa-dev libxcursor-dev libxinerama-dev libwayland-dev \
              libxkbcommon-dev
  local src=~/.cache/slimebench/raylib
  rm -rf "$src"
  git clone --depth 1 --branch "$RAYLIB_VERSION" https://github.com/raysan5/raylib "$src"
  cmake -S "$src" -B "$src/build" -G Ninja \
        -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build "$src/build"
  sudo cmake --install "$src/build"
  sudo ldconfig
}

setup_rust() {
  log "rust"
  if have rustc; then
    echo "  already installed: $(rustc --version)"
  else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    echo "  add to your shell rc:  . \"\$HOME/.cargo/env\""
  fi
}

setup_haskell() {
  log "haskell"
  if have ghc; then
    echo "  already installed: $(ghc --version)"
  else
    # GHCup rather than apt: Ubuntu's ghc lags several releases behind.
    curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | \
      BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_INSTALL_HLS=0 sh
    echo "  add to your shell rc:  . \"\$HOME/.ghcup/env\""
  fi
}

setup_scripting() {
  log "scripting languages"
  need_apt_update
  apt_install perl cpanminus python3-full python3-pip python3-numpy \
              libsdl2-dev
  echo "  perl SDL2 bindings (FFI, needs libsdl2-dev):"
  sudo cpanm --notest FFI::Platypus SDL2::FFI || \
    warn "SDL2::FFI failed -- the Perl headless target does not need it"
}

setup_gpu() {
  log "gpu compute"
  need_apt_update
  apt_install mesa-vulkan-drivers vulkan-tools libvulkan-dev \
              glslang-tools spirv-tools libgl1-mesa-dri
  if [ -e /dev/dxg ]; then
    echo "  /dev/dxg present -- WSLg GPU passthrough is active"
    vulkaninfo --summary 2>/dev/null | head -20 || true
  else
    warn "/dev/dxg missing -- no GPU passthrough in this WSL instance"
  fi
}

main() {
  local what="${1:-all}"
  case "$what" in
    base)      setup_base ;;
    render)    setup_render ;;
    rust)      setup_rust ;;
    haskell)   setup_haskell ;;
    scripting) setup_scripting ;;
    gpu)       setup_gpu ;;
    all)       setup_base; setup_render; setup_rust; setup_haskell
               setup_scripting; setup_gpu ;;
    *)         echo "usage: $0 {base|render|rust|haskell|scripting|gpu|all}" >&2
               exit 2 ;;
  esac
  log "done"
}

main "$@"
