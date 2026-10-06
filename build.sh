#!/bin/bash
# Builds Lumi.app (universal: Apple Silicon + Intel) into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Lumi.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling…"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" Sources/main.swift -o "build/Lumi-$arch"
done
lipo -create build/Lumi-arm64 build/Lumi-x86_64 -output "$APP/Contents/MacOS/Lumi"
rm build/Lumi-arm64 build/Lumi-x86_64

cp Info.plist "$APP/Contents/"
cp -R web "$APP/Contents/Resources/web"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/"

echo "→ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "→ Zipping for sharing…"
(cd build && ditto -c -k --keepParent Lumi.app Lumi-macOS.zip)

echo "✓ Done: $APP and build/Lumi-macOS.zip"
