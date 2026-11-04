#!/bin/zsh
# Builds build/JadyxDrop.app as a universal (Apple silicon + Intel) binary.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(<VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP=build/JadyxDrop.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos14.0 \
    Sources/main.swift -o build/obj/JadyxDrop-$arch
done
lipo -create build/obj/JadyxDrop-arm64 build/obj/JadyxDrop-x86_64 -output "$APP/Contents/MacOS/JadyxDrop"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$APP"
echo "built $PWD/$APP ($VERSION, build $BUILD)"
