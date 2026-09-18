#!/bin/bash
# Regenerates the app icon: Tools/GenerateIcon.swift writes the Icon Composer
# bundle Resources/AppIcon.icon, and actool compiles it into Resources/Assets.car
# (the icon macOS 26 and later use) and Resources/AppIcon.icns (the fallback).
#
# actool ships with Xcode, not the Command Line Tools, so this is the one
# script that needs Xcode. Its outputs are committed, which keeps
# package-app.sh working on a Command Line Tools-only machine. Run it after
# changing the generator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
OUT="$(mktemp -d)"
trap 'rm -r "$OUT"' EXIT

cd "$ROOT"
swift Tools/GenerateIcon.swift Resources/AppIcon.icon
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$OUT" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$OUT/partial.plist" > /dev/null
cp "$OUT/Assets.car" "$OUT/AppIcon.icns" Resources/
echo "Wrote Resources/AppIcon.icon, Resources/Assets.car, Resources/AppIcon.icns"
