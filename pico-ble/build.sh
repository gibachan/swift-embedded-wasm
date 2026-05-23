#!/bin/bash
set -e

export PICO_BOARD=pico_w
export PICO_SDK_PATH=~/pico/pico-sdk
export PICO_TOOLCHAIN_PATH=/opt/homebrew

SWIFT_TOOLCHAIN=~/Library/Developer/Toolchains/swift-6.3.1-RELEASE.xctoolchain/usr

if [ ! -d build ]; then
    cmake -B build -G Ninja . \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=On \
        -DCMAKE_Swift_COMPILER="$SWIFT_TOOLCHAIN/bin/swiftc"
fi

cmake --build build
