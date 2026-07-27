#!/bin/bash
# Builds Soquel.app into build/ from the SwiftPM release binary.
#
# Signing decides whether a permission the user grants survives an update.
# macOS ties a Full Disk Access grant to the application's designated
# requirement. Ad-hoc signing makes that requirement the exact code hash, which
# changes on every build, so every release asks for the permission again as
# though it were a different application. A Developer ID signature makes the
# requirement the team identifier, which does not change, so the grant is given
# once and kept.
#
# SOQUEL_IDENTITY overrides the identity; otherwise the first Developer ID
# Application identity in the keychain is used, and failing that the build is
# ad-hoc signed and says so.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Soquel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Soquel "$APP/Contents/MacOS/Soquel"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/Soquel.icns "$APP/Contents/Resources/Soquel.icns"

IDENTITY="${SOQUEL_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')}"

if [ -n "$IDENTITY" ]; then
    # --options runtime is the hardened runtime, which notarisation requires.
    # --timestamp gets a trusted timestamp, without which the signature stops
    # being accepted once the certificate expires.
    codesign --force --options runtime --timestamp \
             --entitlements Support/Soquel.entitlements \
             -s "$IDENTITY" "$APP"
    echo "Built $APP"
    echo "Signed by: $IDENTITY"
    codesign -dv "$APP" 2>&1 | grep -E 'TeamIdentifier|Authority=Developer' | head -2
    echo "Next: ./scripts/notarise.sh"
else
    codesign --force -s - "$APP"
    echo "Built $APP"
    echo
    echo "No Developer ID identity found, so this build is ad-hoc signed."
    echo "Its signature changes every build, so macOS asks for Full Disk Access"
    echo "again after each one. Import the Developer ID identity, or set"
    echo "SOQUEL_IDENTITY, to stop that."
fi
