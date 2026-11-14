#!/bin/bash
# Builds Kext/VoltBarMSR.cpp into <out>/VoltBarMSR.kext.  Usage: Kext/build-kext.sh <outdir>
set -euo pipefail
OUT="${1:-$(dirname "$0")/../build}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path --sdk macosx)
KH="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
CLANG_RT=$(dirname "$(xcrun --find clang)")/../lib/clang
CC_KEXT=$(ls "$CLANG_RT"/*/lib/darwin/libclang_rt.cc_kext.a | head -1)
OBJ="$OUT/kext-obj"
KEXT="$OUT/VoltBarMSR.kext"

rm -rf "$OBJ" "$KEXT"
mkdir -p "$OBJ" "$KEXT/Contents/MacOS"

COMMON=(-target x86_64-apple-macos13.0 -isysroot "$SDK" -I"$KH" -mkernel -nostdinc
        -DKERNEL -DKERNEL_PRIVATE=0 -DAPPLE -DNeXT -O2 -Wall -Werror -fno-common -fno-builtin -fno-stack-protector)
# -nostdinc drops the SDK include paths; add the kernel ones back.
COMMON+=(-isystem "$KH")

xcrun clang   "${COMMON[@]}" -std=c11 -c kmod_info.c -o "$OBJ/kmod_info.o"
xcrun clang++ "${COMMON[@]}" -std=gnu++17 -fapple-kext -fno-rtti -fno-exceptions -c VoltBarMSR.cpp -o "$OBJ/VoltBarMSR.o"
xcrun clang++ -target x86_64-apple-macos13.0 -isysroot "$SDK" -mkernel -fapple-kext -nostdlib \
    -Xlinker -kext -L"$SDK/usr/lib" -lkmodc++ -lkmod "$CC_KEXT" \
    "$OBJ/kmod_info.o" "$OBJ/VoltBarMSR.o" -o "$KEXT/Contents/MacOS/VoltBarMSR"

cp Info.plist "$KEXT/Contents/Info.plist"
chmod -R u+rwX,go+rX-w "$KEXT"
codesign --force --sign - "$KEXT"
rm -rf "$OBJ"
echo "kext: $KEXT"
