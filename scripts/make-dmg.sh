#!/bin/bash
# Packages build/Soquel.app into a distributable disk image.
#
# The window is laid out rather than left to Finder's defaults: a background
# with an arrow, the application on the left, a symlink to Applications on the
# right, and no toolbar or sidebar. Dragging one onto the other is the whole
# instruction, and a plain unstyled window does not say that.
#
# The layout is applied by scripting Finder, which needs the automation
# permission and can be refused. A refusal is not fatal: the image is still
# built and still installs, it just opens as a plain list.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Soquel.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
DMG="build/Soquel-${VERSION}.dmg"
VOLUME="Soquel ${VERSION}"

[ -d "$APP" ] || { echo "no $APP — run scripts/build-app.sh first" >&2; exit 1; }
[ -f Support/dmg/background.png ] || python3 scripts/make-dmg-background.py

STAGE="$(mktemp -d)/Soquel"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Support/dmg/background.png "$STAGE/.background/background.png"
cp Support/dmg/background@2x.png "$STAGE/.background/background@2x.png"
# The image gets the application's own icon, so it is recognisable in the
# sidebar and on the desktop while it is mounted.
cp Support/Soquel.icns "$STAGE/.VolumeIcon.icns"

# Read-write first: the layout is written into the volume's .DS_Store, which
# cannot be done to a compressed image.
RW="$(mktemp -d)/rw.dmg"
rm -f "$DMG"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov \
    -format UDRW -fs HFS+ -quiet "$RW"

MOUNT="/Volumes/$VOLUME"
hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true
hdiutil attach "$RW" -readwrite -noverify -noautoopen -quiet
SetFile -a C "$MOUNT" 2>/dev/null || true   # honour .VolumeIcon.icns

osascript <<APPLESCRIPT >/dev/null 2>&1 || echo "note: Finder would not lay the window out; the image still works"
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 660 by 420 of usable area, allowing for the title bar.
        set the bounds of container window to {200, 140, 860, 582}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 112
        set background picture of options to file ".background:background.png"
        set position of item "Soquel.app" of container window to {170, 190}
        set position of item "Applications" of container window to {490, 190}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" -force -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -rf "$(dirname "$RW")" "$(dirname "$STAGE")"

# The image is signed too, not only the application inside it: Gatekeeper
# checks what was actually downloaded.
IDENTITY="${SOQUEL_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp -s "$IDENTITY" "$DMG"
    echo "Signed by: $IDENTITY"
fi

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
