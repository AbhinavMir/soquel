#!/bin/bash
# Packages build/Soquel.app into a distributable disk image.
#
# The image holds the application and a symlink to /Applications, which is the
# drag-to-install convention every macOS user already knows.
#
# The app is ad-hoc signed, so a first launch on someone else's Mac needs
# right-click → Open. Notarising it needs a paid Apple Developer account.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Soquel.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
DMG="build/Soquel-${VERSION}.dmg"

[ -d "$APP" ] || { echo "no $APP — run scripts/build-app.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)/Soquel"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# A short README rather than a background image with positioned icons: the
# window layout needs AppleScript against Finder, which fails on a machine
# where Finder is not scriptable, and the instruction is one sentence.
cat > "$STAGE/Read Me.txt" <<'NOTE'
Soquel

Drag Soquel to the Applications folder beside it.

The first launch needs a right-click on Soquel and then Open, because the
application is signed ad-hoc rather than notarised. macOS refuses a plain
double-click the first time and offers no Open button in the dialog. After
that first launch it opens normally.
NOTE

rm -f "$DMG"
hdiutil create -volname "Soquel" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$(dirname "$STAGE")"

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
