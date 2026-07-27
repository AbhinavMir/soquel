#!/bin/bash
# Opens the Full Disk Access pane and reveals the installed app.
#
# The grant itself cannot be automated: the TCC database is protected by System
# Integrity Protection precisely so that no program can grant itself access.
set -euo pipefail

APP=/Applications/Soquel.app
if [ ! -d "$APP" ]; then
  echo "Soquel is not installed. Run ./scripts/install.sh first." >&2
  exit 1
fi

open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
sleep 2
open -R "$APP"

cat <<'EOF'

Two steps, in the windows that just opened:
  1. Drag Soquel.app into the Full Disk Access list (or use + and pick it)
  2. Switch it on

Then quit and reopen Soquel. Check it worked by opening ~/Downloads: it should
list files instead of saying access may be blocked.
EOF
