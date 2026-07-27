#!/bin/bash
# Builds Support/Soquel.icns. The artwork is drawn by scripts/make-icon.py.
#
# A blue squircle with the folder in white on top of it.
#
# Two earlier attempts failed for the same reason in opposite directions. The
# folder alone, floating on transparency, gets a grey backing plate drawn
# behind it by macOS, which shrinks it. The folder masked into a squircle puts
# its tab notch through the top edge, which reads as a bite out of the shape
# rather than as a folder. Separating the two — plate underneath, glyph on top
# — survives down to 16 points, where the wave detail would be mud anyway.
set -euo pipefail

cd "$(dirname "$0")/.."
SOURCE="Support/icon/soquel-logo.png"
MASTER="Support/icon/icon-1024.png"
OUTPUT="Support/Soquel.icns"

command -v magick >/dev/null || { echo "needs ImageMagick: brew install imagemagick" >&2; exit 1; }
[ -f "$SOURCE" ] || { echo "missing $SOURCE" >&2; exit 1; }

SIZE=1024
# Matched to the system icons rather than guessed. Notes and Finder cover about
# 62% of their canvas and never touch its edge; macOS scales that up into its
# own plate. An icon that fills the canvas instead gets scaled down inside the
# mask, and the plate shows around it as a grey ring.
INSET=102
BOX=$((SIZE - 2 * INSET))
GLYPH=0            # unused: the system draws the plate, this is only the glyph

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The folder, lifted off its white background, and nothing else.
#
# macOS 26 draws its own plate behind a third-party icon whatever that icon
# does — four different insets and a full-bleed squircle all ended up inside a
# grey ring. Finder and Notes escape it because they are system applications,
# not because of anything in their icns. So the plate is the background, and
# this supplies only the thing that sits on it, sized to the same proportion of
# the canvas the system icons use.
magick "$SOURCE" -fuzz 3% -transparent white -trim +repage "$WORK/art.png"
magick "$WORK/art.png" -resize "${BOX}x${BOX}" -background none -gravity center \
       -extent "${SIZE}x${SIZE}" "$MASTER"

STAGE="$WORK/Soquel.iconset"
mkdir -p "$STAGE"

# The ten entries iconutil expects, as "size name" pairs.
while read -r size name; do
    [ -z "$size" ] && continue
    magick "$MASTER" -resize "${size}x${size}" "$STAGE/${name}.png"
done <<'SIZES'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SIZES

iconutil -c icns "$STAGE" -o "$OUTPUT"
echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
