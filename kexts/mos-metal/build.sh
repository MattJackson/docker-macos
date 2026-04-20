#!/bin/bash
# Build mos-metal.kext — Phase -1.A/-1.B scaffold.
# Template derived from kexts/QEMUDisplayPatcher/build.sh.
# No mos-patcher dep at this phase (Phase -1.A.4 revisits).
set -e
cd "$(dirname "$0")"

KERN_SDK="${KERN_SDK:-../deps/MacKernelSDK}"
MP_HEADERS="${MP_HEADERS:-../../../mos15-patcher/include}"
OUT="build/mos-metal.kext/Contents/MacOS/mos-metal"

rm -rf build/mos-metal.kext
mkdir -p "$(dirname "$OUT")"
cp Info.plist build/mos-metal.kext/Contents/Info.plist

CXX="xcrun -sdk macosx clang++"
CC="xcrun -sdk macosx clang"

CXXFLAGS=(
    -target x86_64-apple-macos10.15 -arch x86_64 -std=c++17
    -fno-rtti -fno-exceptions -fno-builtin -fno-common -fno-stack-protector
    -mkernel -nostdlib -nostdinc -nostdinc++
    -DKERNEL -DKERNEL_PRIVATE
    -I"$KERN_SDK/Headers"
    -I"$MP_HEADERS"
    -Isrc -w
)
CFLAGS=(
    -target x86_64-apple-macos10.15 -arch x86_64
    -fno-builtin -fno-common -fno-stack-protector -mkernel -nostdlib -nostdinc
    -DKERNEL -DKERNEL_PRIVATE -I"$KERN_SDK/Headers" -w
)

echo "=== compile ==="
$CC  "${CFLAGS[@]}"  -c src/kmod_info.c -o build/kmod_info.o
$CXX "${CXXFLAGS[@]}" -c src/patcher.cpp -o build/patcher.o

echo "=== link ==="
$CXX -target x86_64-apple-macos10.15 -arch x86_64 -nostdlib \
    -Xlinker -kext -Xlinker -no_data_const -Xlinker -no_source_version \
    -L"$KERN_SDK/Library/x86_64" \
    build/kmod_info.o build/patcher.o -lkmod \
    -o "$OUT"

echo "=== done ==="
file "$OUT"
nm "$OUT" | grep -E "mos_metal_start|mos_metal_stop|kmod_info" | head -5
plutil -lint build/mos-metal.kext/Contents/Info.plist
