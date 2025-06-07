#!/usr/bin/env bash
set -e

# Dependency version numbers
source ./versions.properties

if [ $# -lt 1 ]; then
  echo
  echo "Usage: $0 PLATFORM"
  echo "Build shared libraries for libvips and its dependencies"
  echo
  echo "Possible values for PLATFORM are:"
  echo "- linux-x64"
  echo "- linux-arm"
  echo "- linux-arm64"
  echo "- linux-musl-x64"
  echo "- linux-musl-arm64"
  echo "- win-x64"
  echo "- win-x64.net452"
  echo "- win-x86"
  echo "- win-x86.net452"
  echo "- win-arm64"
  echo "- osx-x64"
  echo "- osx-arm64"
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
      export FLAGS+=" -target arm64-apple-macos11"
      # macOS 11 Big Sur is the first version to support ARM-based macs
      export MACOSX_DEPLOYMENT_TARGET="11.0"
      # Set SDKROOT to the latest SDK available
      export SDKROOT=$(xcrun -sdk macosx --show-sdk-path)
    fi

    source $PWD/versions.properties
    source $PWD/build/posix.sh

    exit 0
  fi
done

# Is docker available?
if ! [ -x "$(command -v docker)" ]; then
  echo "Please install docker"
  exit 1
fi

# Update base images
for baseimage in alpine:3.15 amazonlinux:2 debian:bullseye; do
  docker pull $baseimage
done

# Windows (x64, x86 and arm64)
for flavour in win-x64 win-x64.net452 win-x86 win-x86.net452 win-arm64; do
  if [ $PLATFORM = "all" ] || [ $PLATFORM = $flavour ]; then
    echo "Building $flavour..."
    docker build -t vips-dev-win32 platforms/win32
    docker run --rm -e "PLATFORM=$flavour" -v $PWD:/packaging vips-dev-win32 sh -c "/packaging/build/win.sh"
  fi
done

# Linux (x64, ARMv7 and ARM64v8)
for flavour in linux-x64 linux-arm linux-arm64 linux-musl-x64 linux-musl-arm64; do
  if [ $PLATFORM = "all" ] || [ $PLATFORM = $flavour ]; then
    echo "Building $flavour..."
    docker build --cache-from vips-dev-$flavour --build-arg BUILDKIT_INLINE_CACHE=1 -t vips-dev-$flavour platforms/$flavour
    docker run --rm -v $PWD:/packaging vips-dev-$flavour sh -c "/packaging/build/posix.sh"
  fi
done
