#!/bin/bash
set -e
cd "$(dirname "$0")"

KERN_SDK="../deps/MacKernelSDK"
LILU_SDK="../deps/Lilu-1.7.2-DEBUG/Lilu.kext/Contents/Resources"
OUT="build/QEMUDisplayPatcher.kext/Contents/MacOS/QEMUDisplayPatcher"

CXX="xcrun -sdk macosx clang++"
CXXFLAGS=(
    -target x86_64-apple-macos10.15 -arch x86_64 -std=c++17
    -fno-rtti -fno-exceptions -fno-builtin -fno-common -fno-stack-protector
    -mkernel -nostdlib -nostdinc -nostdinc++
    -DKERNEL -DKERNEL_PRIVATE
    -DPRODUCT_NAME=QEMUDisplayPatcher
    -DMODULE_VERSION=1.0.0
    -DLILU_KEXTPATCH_SUPPORT
    -I"$KERN_SDK/Headers"
    -I"$LILU_SDK/Headers"
    -I"$LILU_SDK"
    -Isrc -w
)

CC="xcrun -sdk macosx clang"
CFLAGS=(
    -target x86_64-apple-macos10.15 -arch x86_64
    -fno-builtin -fno-common -fno-stack-protector -mkernel -nostdlib -nostdinc
    -DKERNEL -DKERNEL_PRIVATE -I"$KERN_SDK/Headers" -w
)

echo "=== kmod_info.o ==="
$CC "${CFLAGS[@]}" -c src/kmod_info.c -o build/kmod_info.o

echo "=== plugin_start.o ==="
$CXX "${CXXFLAGS[@]}" -c "$LILU_SDK/Library/plugin_start.cpp" -o build/plugin_start.o

echo "=== kern_start.o ==="
$CXX "${CXXFLAGS[@]}" -c src/kern_start.cpp -o build/kern_start.o

echo "=== kern_patcher.o ==="
$CXX "${CXXFLAGS[@]}" -c src/kern_patcher.cpp -o build/kern_patcher.o

echo "=== Link ==="
mkdir -p build/QEMUDisplayPatcher.kext/Contents/MacOS
cp Info.plist build/QEMUDisplayPatcher.kext/Contents/Info.plist
$CXX -target x86_64-apple-macos10.15 -arch x86_64 -nostdlib \
    -Xlinker -kext -Xlinker -no_data_const -Xlinker -no_source_version \
    -L"$KERN_SDK/Library/x86_64" \
    build/kern_start.o build/kern_patcher.o build/plugin_start.o build/kmod_info.o -lkmod \
    -o "$OUT"

echo "=== Done ==="
file "$OUT"
nm "$OUT" | grep "kern_st\|pluginStart\|kmod_info\|patchedEnable"
