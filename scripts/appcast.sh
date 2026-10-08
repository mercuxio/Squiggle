#!/usr/bin/env bash
# Adds the packaged zip for the current version to appcast.xml, signed with the EdDSA key in the
# login Keychain (created once by Sparkle's `generate_keys`, and shared with Sniffcast). Run after
# package-app.sh and after the zip exists, then commit and push appcast.xml: installed copies read
# it from the main branch on GitHub, not from the release page.
#
# The signature covers the zip, so this has to run on the exact file that gets uploaded. Sign a
# rebuilt zip and every installed copy refuses the update.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PLIST="build/Squiggle.app/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
MINOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST" 2>/dev/null || echo 14.0)
ZIP="build/Squiggle-$VERSION.zip"
if [ ! -f "$ZIP" ]; then
  echo "$ZIP not found — build it with ditto -c -k --keepParent first" >&2
  exit 1
fi
# sign_update prints the two attributes an enclosure needs: sparkle:edSignature="…" length="…"
SIGN=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$ZIP")
URL="https://github.com/mercuxio/Squiggle/releases/download/v$VERSION/Squiggle-$VERSION.zip"
NOTES="https://github.com/mercuxio/Squiggle/releases/tag/v$VERSION"
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

ITEM="    <item>
      <title>Squiggle $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$NOTES</sparkle:releaseNotesLink>
      <enclosure url=\"$URL\" type=\"application/octet-stream\" $SIGN/>
    </item>"

if [ ! -f appcast.xml ]; then
  cat > appcast.xml <<X
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Squiggle</title>
  </channel>
</rss>
X
fi
grep -q "<sparkle:shortVersionString>$VERSION<" appcast.xml && { echo "appcast.xml already lists $VERSION"; exit 0; }
python3 - "$ITEM" <<'P'
import sys
item=sys.argv[1]; s=open('appcast.xml').read()
s=s.replace("<title>Squiggle</title>\n","<title>Squiggle</title>\n"+item+"\n",1)  # newest first
open('appcast.xml','w').write(s)
P
echo "Added $VERSION to appcast.xml"
