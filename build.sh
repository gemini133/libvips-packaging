#!/usr/bin/env bash
set -e

if [ $# -lt 1 ]; then
  echo
  echo "Usage: $0 PLATFORM"
  echo
  exit 1
fi

PLATFORM="$1"

# macOS
# Note: we intentionally don't build these binaries inside a Docker container
for flavour in osx-x64 osx-arm64; do
  if [ $PLATFORM = $flavour ] && [ "$(uname)" == "Darwin" ]; then
    echo "Building $flavour..."

    # Use Clang provided by XCode
    export CC="clang"
    export CXX="clang++"

    export VERSION_VIPS
    export PLATFORM

    # Use pkg-config provided by Homebrew
    export PKG_CONFIG="$(brew --prefix)/bin/pkg-config --static"

    # Earliest supported version of macOS
    export MACOSX_DEPLOYMENT_TARGET="10.15"

    # Added -fno-stack-check to workaround a stack misalignment bug on macOS 10.15
    # See:
    # https://forums.developer.apple.com/thread/121887
    # https://trac.ffmpeg.org/ticket/8073#comment:12
    export FLAGS="-fno-stack-check"
    # Prevent use of API newer than the deployment target
    export FLAGS+=" -Werror=unguarded-availability-new"
    export MESON="--cross-file=$PWD/platforms/$PLATFORM/meson.ini"

    if [ $PLATFORM = "osx-arm64" ]; then
      # ARM64 builds work via cross compilation from an x86_64 machine
      export CHOST="aarch64-apple-darwin"
      export RUST_TARGET="aarch64-apple-darwin"
      export FLAGS+=" -target arm64-apple-macos15"
      # macOS 11 Big Sur is the first version to support ARM-based macs
      export MACOSX_DEPLOYMENT_TARGET="15.0"
      # Set SDKROOT to the latest SDK available
      export SDKROOT=$(xcrun -sdk macosx --show-sdk-path)
    fi

    . $PWD/build/osx.sh

    exit 0
  fi
done

# Is docker available?
if ! [ -x "$(command -v docker)" ]; then
  echo "Please install docker"
  exit 1
fi


# Update base images
for baseimage in amazonlinux:2; do
  docker pull $baseimage
done

# Linux (x64, ARMv7 and ARM64v8)
for flavour in linux-x64 linux-arm linux-arm64 linux-musl-x64 linux-musl-arm64; do
  if [ $PLATFORM = $flavour ]; then
    echo "Building $flavour..."
    docker build --cache-from vips-dev-$flavour --build-arg BUILDKIT_INLINE_CACHE=1 -t vips-dev-$flavour platforms/$flavour
    docker run --rm -v $PWD:/packaging vips-dev-$flavour sh -c "/packaging/build/lin.sh"
  fi
done