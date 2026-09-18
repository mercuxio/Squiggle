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

cd "$ROOT"
swift build --build-system native -c release --product Squiggle

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/Squiggle" "$APP/Contents/MacOS/Squiggle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# The icon comes prebuilt from scripts/make-icon.sh, which needs Xcode's actool.
# Assets.car is what macOS 26 and later draw; AppIcon.icns is the fallback.
cp "$ROOT/Resources/Assets.car" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
