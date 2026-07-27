#!/usr/bin/env python3
"""Draws the disk image window background.

The window is 660x420. The application sits at x=170 and the Applications
symlink at x=490, both centred on y=190 from the top, so the arrow between them
is drawn at that height and the instructions sit below.

Written at twice the size and saved as both, because a Retina display picks the
@2x file and a blurry background is the first thing anyone sees of the
application.
"""
from PIL import Image, ImageDraw, ImageFont

W, H = 660, 420
S = 2                       # supersample and @2x in one
w, h = W * S, H * S

INK = (28, 42, 56)
MUTED = (108, 124, 138)
ACCENT = (47, 111, 196)


def font(size, bold=False):
    face = "/System/Library/Fonts/SFNS.ttf"
    for path in ([" /System/Library/Fonts/SFNSDisplay.ttf".strip(), face]
                 if bold else [face]):
        try:
            f = ImageFont.truetype(path, size * S)
            if bold:
                try:
                    f.set_variation_by_name("Bold")
                except Exception:
                    pass
            return f
        except Exception:
            continue
    return ImageFont.load_default()


def centred(d, text, y, f, fill):
    left, top, right, bottom = d.textbbox((0, 0), text, font=f)
    d.text(((w - (right - left)) / 2 - left, y * S), text, font=f, fill=fill)


img = Image.new("RGB", (w, h), (255, 255, 255))
d = ImageDraw.Draw(img)

# A very soft wash, so the window is not a flat white box.
for y in range(h):
    t = y / (h - 1)
    v = int(252 - 10 * t)
    d.line([(0, y), (w, y)], fill=(v, v + 1, v + 3))

centred(d, "Soquel", 44, font(30, bold=True), INK)
centred(d, "Drag the application into your Applications folder", 88, font(13), MUTED)

# The arrow, between the two icons and clear of both.
y = 190 * S
x0, x1 = 262 * S, 398 * S
d.line([(x0, y), (x1 - 16 * S, y)], fill=ACCENT, width=3 * S)
d.polygon([(x1, y), (x1 - 18 * S, y - 11 * S), (x1 - 18 * S, y + 11 * S)], fill=ACCENT)

# No labels under the icons: Finder draws those itself, and a second set
# underneath them reads as a mistake.

# The application is signed but not notarised, so the first launch is refused
# until it is opened from the context menu. Saying so here is the difference
# between a person trying it and a person assuming it is broken.
centred(d, "First time you open it: right-click Soquel, then choose Open", 334,
        font(12, bold=True), INK)
centred(d, "macOS only asks once.", 356, font(11), MUTED)

img.resize((W, H), Image.LANCZOS).save("Support/dmg/background.png")
img.save("Support/dmg/background@2x.png")
print("wrote Support/dmg/background.png and @2x")
