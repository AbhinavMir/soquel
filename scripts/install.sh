#!/bin/bash
# Builds and installs Soquel to /Applications.
#
# Install to a stable path before granting Full Disk Access: macOS ties the
# grant to where the app lives, and build/ is replaced on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

osascript -e 'quit app "Soquel"' 2>/dev/null || true
sleep 1

rm -rf /Applications/Soquel.app
cp -R build/Soquel.app /Applications/Soquel.app
codesign --force -s - /Applications/Soquel.app

echo "Installed /Applications/Soquel.app"
echo
echo "To grant Full Disk Access (needed to list Desktop, Documents, Downloads"
echo "and external volumes), which cannot be scripted:"
echo "  1. ./scripts/full-disk-access.sh"
echo "  2. Drag Soquel.app into the list, then switch it on"
