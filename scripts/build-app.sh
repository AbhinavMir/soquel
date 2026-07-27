#!/bin/bash
# Builds Soquel.app into build/ from the SwiftPM release binary.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Soquel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Soquel "$APP/Contents/MacOS/Soquel"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/Soquel.icns "$APP/Contents/Resources/Soquel.icns"
codesign --force -s - "$APP"
echo "Built $APP"
