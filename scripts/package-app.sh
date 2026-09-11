#!/bin/bash
# Assembles Squiggle.app from the SwiftPM release build.
#
# SwiftPM produces a bare Mach-O executable and has no concept of an
# application bundle, so the bundle is built by hand here. Everything below is
# the minimum macOS needs to treat the result as an app: the directory layout,
# an Info.plist, and a signature.
#
# The signature is ad-hoc (`-`). That is enough for a locally built app the
# user launches themselves, and enough for `SMAppService.mainApp` to register
# it (Task 14). It is NOT enough for distribution: a downloaded copy is
# quarantined, which the README's Gatekeeper note covers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Squiggle.app"
ICONSET="$ROOT/build/AppIcon.iconset"
ICON="$ROOT/Resources/AppIcon.icns"

cd "$ROOT"
swift build --build-system native -c release --product Squiggle

# Regenerated every time rather than trusted from the repo, so the icon cannot
# drift from the generator that defines it. The .icns is committed all the same,
# for anything that wants the artwork without running a build.
swift Tools/GenerateIcon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICON"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/Squiggle" "$APP/Contents/MacOS/Squiggle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
