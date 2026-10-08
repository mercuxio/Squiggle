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
#
# Sparkle is the one dependency that ships inside the bundle, and SwiftPM has
# no way to put it there: a binary framework can be embedded in an app target
# by Xcode, but not in a SwiftPM executable product. So the framework is
# copied, the executable is given an rpath that finds it, and both are signed
# here by hand — the three things Xcode would have done.
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

# Sparkle. `cp -R` and not `ditto`, to keep the framework's version symlinks
# as symlinks: a framework whose Versions/Current is a copy rather than a link
# fails codesign's structural check.
#
# The xcframework slice is the universal one, so this is the same binary a
# release build links against whichever configuration produced it.
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE" ]; then
  echo "Sparkle.framework not found at $SPARKLE — run swift build first" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"

# SwiftPM links Sparkle with an `@loader_path` rpath, which in the build
# directory means "beside the executable". In a bundle the executable is in
# Contents/MacOS and the framework is in Contents/Frameworks, so the loader
# needs the hop between them spelled out or the app dies on launch with
# "Library not loaded: @rpath/Sparkle.framework".
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/Squiggle"

# Nested code first, outer bundle second — the order codesign requires, and
# the reason this is not one `--deep` pass over the whole app. `--deep` on the
# framework is right, though: it carries its own nested code, an Updater.app
# and two XPC services, and the rpath edit above invalidated nothing of it but
# everything has to carry a signature made by the same identity.
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP"
