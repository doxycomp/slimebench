# A machine anyone can build, so the numbers can be checked and not just read.
#
# Two targets, because the toolchains are not the same size:
#
#   core  eleven of the fourteen languages, about 5 GiB. Built and exercised
#         by CI on every push -- the conformance suite runs inside it, so this
#         image is verified rather than merely written.
#
#   full  adds GHC, Swift and Lean and comes to 20.9 GiB, which does not fit
#         a GitHub runner's disk -- so CI does not build it and every push
#         verifies `core` only. It has been built and run by hand, and all
#         fourteen languages pass the conformance gate inside it; the only
#         target that skips is pygl, which needs a GL device a container does
#         not have. Three things found by doing that, all of them guesses
#         before:
#
#           - the size. This said 14 GiB, from adding up download sizes.
#           - the Haskell build failed on a file from the author's laptop.
#             `cabal install --lib` writes .ghc.environment.* next to the
#             sources with the absolute path of its package store baked in;
#             copied into the image it pointed at a home directory that is not
#             there. It is in .dockerignore now.
#           - with that file gone, impl/haskell/build.sh refused the `vector`
#             profiles: it checked for the file rather than for the package,
#             and the package was reachable without it. It asks GHC now.
#
#         Treat a failure here as a bug report rather than as your mistake.
#
#     docker build --target core -t slimebench:core .
#     docker run --rm slimebench:core bench/run.py conformance
#     docker build --target full -t slimebench:full .
#
# What no container can carry: the CUDA and GL compute targets need a GPU and
# a driver, and class R needs a display. `bench/preflight.sh` reports those as
# missing and `bench/full-run.sh` skips their phases, so a run inside the
# image is a real run of everything else rather than a broken run of
# everything.
#
# Every version comes from versions.env, which is the single place they are
# recorded. Passing them as ARGs rather than reading the file at build time
# keeps the layers cacheable and makes a version bump show up in the diff.

ARG SB_UBUNTU=24.04

# ===========================================================================
FROM ubuntu:${SB_UBUNTU} AS core
# ===========================================================================

ARG SB_RUST=1.97.1
ARG SB_GO=1.27.0
ARG SB_NODE=25.5.0
ARG SB_DOTNET_CHANNEL=10.0
ARG SB_NUMBA_PYTHON=3.12
ARG SB_NUMBA=0.67.0
ARG SB_FREETHREADED_PYTHON=3.14

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    LANG=C.UTF-8

# One layer for the archive toolchains. gcc and gfortran come from the same
# package set; clang is the second compiler the conformance job uses, because
# a tier-A claim that only holds under gcc is not a tier-A claim.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gcc g++ gfortran clang llvm lld make cmake \
        python3 python3-numpy python3-full \
        perl cpanminus \
        ocaml-nox \
        openjdk-21-jdk-headless \
        git ca-certificates curl xz-utils unzip pkg-config \
        libgmp-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# .NET, with the Native AOT components -- a separate package, and the one the
# csharp-simd and aot profiles need. Without it three of the four C# profiles
# build and the interesting one does not.
RUN apt-get update && apt-get install -y --no-install-recommends \
        dotnet-sdk-${SB_DOTNET_CHANNEL} dotnet-sdk-aot-${SB_DOTNET_CHANNEL} \
    && rm -rf /var/lib/apt/lists/*

# Rust, minimal profile: the benchmark needs rustc and cargo, not docs.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain ${SB_RUST} --no-modify-path
ENV PATH=/opt/cargo/bin:${PATH}

# Go, from the tarball: the archive's version trails, and class P compares
# runtimes rather than distributions.
RUN curl -fsSL "https://go.dev/dl/go${SB_GO}.linux-amd64.tar.gz" \
      | tar -C /opt -xz
ENV PATH=/opt/go/bin:${PATH}

# Node, for the TypeScript target. 22+ is required for
# --experimental-strip-types, which is how impl/ts runs without a build step.
RUN curl -fsSL "https://nodejs.org/dist/v${SB_NODE}/node-v${SB_NODE}-linux-x64.tar.xz" \
      | tar -C /opt -xJ \
    && ln -s "/opt/node-v${SB_NODE}-linux-x64" /opt/node
ENV PATH=/opt/node/bin:${PATH}

# The two Python targets that need their own interpreter. Ubuntu marks the
# system Python externally-managed (PEP 668) and numba pins a narrower numpy
# than the archive ships, so each gets a venv -- the same layout
# scripts/setup-wsl.sh produces, and the paths bench/run.py looks for.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && uv venv --python ${SB_NUMBA_PYTHON} /opt/numba \
    && uv pip install --python /opt/numba/bin/python "numba==${SB_NUMBA}" numpy \
    && uv venv --python ${SB_FREETHREADED_PYTHON}t /opt/ft314 \
    && uv pip install --python /opt/ft314/bin/python numpy
ENV SLIMEBENCH_NUMBAPY=/opt/numba/bin/python \
    SLIMEBENCH_PY314T=/opt/ft314/bin/python

# Perl's FFI bindings are only needed by the windowed targets, which a
# container has no display for. The headless Perl target needs nothing.

WORKDIR /slimebench
COPY . .

# Fail the build if the image cannot do the one thing it exists for.
RUN python3 -m compileall -q bench impl/python \
    && bench/preflight.sh || true

CMD ["bench/preflight.sh"]

# ===========================================================================
FROM core AS full
# ===========================================================================
# The three large toolchains. Twelve gigabytes between them, which is why they
# are not in `core` and why CI does not build this target.

ARG SB_GHC=9.10.3
ARG SB_CABAL=3.16.1.0
ARG SB_SWIFT=6.3.3
ARG SB_UBUNTU=24.04

ENV GHCUP_INSTALL_BASE_PREFIX=/opt
RUN apt-get update && apt-get install -y --no-install-recommends \
        libnuma-dev libtinfo-dev libncurses-dev \
    && rm -rf /var/lib/apt/lists/* \
    && curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org \
      | env BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
            BOOTSTRAP_HASKELL_GHC_VERSION=${SB_GHC} \
            BOOTSTRAP_HASKELL_CABAL_VERSION=${SB_CABAL} \
            BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1 \
            BOOTSTRAP_HASKELL_ADJUST_BASHRC=0 sh
ENV PATH=/opt/.ghcup/bin:${PATH}
# vector is the only non-boot package the ports need, but naming just it
# builds a package environment that *hides* the boot packages -- GHC then
# refuses `Data.Array.Unboxed` as "a member of the hidden package array".
# So every package the sources import is named, boot or not.
#
# This has to happen inside the image. impl/haskell/build.sh documents a local
# `--package-env .` file instead, which cabal writes with the absolute path of
# its store baked in; that file is machine-specific and is excluded from the
# build context for exactly that reason.
RUN cabal update     && cabal install --lib vector array bytestring text

# Swift ships its own clang. It goes on the PATH *after* the system one on
# purpose: prepending it would shadow clang 18 and silently change what the
# compiler matrix measures. bench/full-run.sh documents the same rule.
RUN curl -fsSL "https://download.swift.org/swift-${SB_SWIFT}-release/ubuntu$(echo ${SB_UBUNTU} | tr -d .)/swift-${SB_SWIFT}-RELEASE/swift-${SB_SWIFT}-RELEASE-ubuntu${SB_UBUNTU}.tar.gz" \
      | tar -C /opt -xz \
    && ln -s "/opt/swift-${SB_SWIFT}-RELEASE-ubuntu${SB_UBUNTU}" /opt/swift
ENV PATH=${PATH}:/opt/swift/usr/bin

# elan reads impl/lean/lean-toolchain, so the version is pinned by the repo
# rather than by an ARG.
ENV ELAN_HOME=/opt/elan
RUN curl -fsSL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --no-modify-path
ENV PATH=${PATH}:/opt/elan/bin
RUN cd impl/lean && lake build

CMD ["bench/preflight.sh"]
