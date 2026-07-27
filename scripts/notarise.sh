#!/bin/bash
# Notarises build/Soquel.app and staples the ticket to the disk image.
#
# Notarising is what removes the Gatekeeper warning entirely: without it a
# Developer ID signature still shows "downloaded from the internet, are you
# sure", and without a stapled ticket the check needs the network on first
# launch.
#
# Credentials come from a keychain profile so no password is ever in a file or
# in the shell history. Create it once:
#
#   xcrun notarytool store-credentials soquel \
#       --apple-id abhinavmir@icloud.com \
#       --team-id P4ANTPX4G4 \
#       --password <app-specific-password>
#
# The app-specific password comes from appleid.apple.com, not the account
# password.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${SOQUEL_NOTARY_PROFILE:-soquel}"
APP=build/Soquel.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
DMG="build/Soquel-${VERSION}.dmg"

[ -d "$APP" ] || { echo "no $APP — run scripts/build-app.sh first" >&2; exit 1; }

# Refuse to submit something Apple will reject, with a clearer message than the
# one that comes back an unknown number of minutes later.
if ! codesign -dv "$APP" 2>&1 | grep -q 'Authority=Developer ID Application'; then
    echo "$APP is not signed with a Developer ID; notarisation would be rejected." >&2
    echo "Import the identity and run scripts/build-app.sh again." >&2
    exit 1
fi
if ! codesign -d --entitlements - "$APP" >/dev/null 2>&1; then
    echo "$APP has no entitlements — was it built by scripts/build-app.sh?" >&2
    exit 1
fi

[ -f "$DMG" ] || ./scripts/make-dmg.sh

echo "Submitting $DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Stapling puts the ticket inside the image, so a first launch works offline.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "Notarised and stapled: $DMG"
spctl -a -vvv -t install "$DMG" 2>&1 | head -3 || true
