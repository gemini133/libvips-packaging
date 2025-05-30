#!/usr/bin/env bash
#!/usr/bin/env bash
set -e

PLATFORM="$1"

DARWIN=true
DEPS=$PWD/deps
TARGET=$PWD/target
PACKAGE=$PWD
ROOT=$PWD/platforms/$PLATFORM
VIPS_CPP_DEP=libvips-cpp.42.dylib

mkdir -p ${DEPS}
mkdir -p ${TARGET}

export LDFLAGS+=" -Wl,-dead_strip"
export CARGO_HOME="${DEPS}/cargo"
export RUSTUP_HOME="${DEPS}/rustup"
mkdir -p $CARGO_HOME
mkdir -p $RUSTUP_HOME
export PATH="${CARGO_HOME}/bin:${PATH}"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --no-modify-path --profile minimal --default-host aarch64-apple-darwin --default-toolchain stable -t aarch64-apple-darwin
cargo install cargo-c --locked
rustup default stable
rustup show