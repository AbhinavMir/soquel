#!/usr/bin/env python3
"""Draws Support/icon/icon-1024.png: the Soquel folder on a blue squircle.

Vector rather than a resize of the artwork, because the icon has to survive
being shown at 16 points, where a downscaled wave is mud.

macOS draws its own backing plate behind an icon that is only a glyph on
transparency, which shrinks the glyph and rings it in grey. A full-bleed
squircle at Apple's own proportions — 824 of a 1024 canvas — is what every
third-party application ships and what the system expects.
"""
import math
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4                      # supersample; every coordinate below is in icon points
PLATE = 824                 # Apple's art area within the 1024 canvas
RADIUS = 185.4              # and its corner radius

BLUE_TOP = (0x5B, 0xA3, 0xE8)
BLUE_BOTTOM = (0x1B, 0x4A, 0x7A)
WAVES = [(0xBE, 0xDA, 0xF5), (0x7F, 0xB2, 0xEA), (0x3E, 0x7C, 0xC4), (0x1A, 0x4C, 0x86)]

w = SIZE * SS


# ---------------------------------------------------------------- plate
plate = Image.new("RGBA", (w, w), (0, 0, 0, 0))
mask = Image.new("L", (w, w), 0)
inset = (SIZE - PLATE) / 2 * SS
ImageDraw.Draw(mask).rounded_rectangle(
    [inset, inset, w - inset, w - inset], radius=RADIUS * SS, fill=255)

gradient = Image.new("RGB", (1, w))
gp = gradient.load()
for y in range(w):
    t = y / (w - 1)
    # eased so the light stays in the top third, as a lit surface does
    e = t ** 0.85
    gp[0, y] = tuple(int(BLUE_TOP[i] + (BLUE_BOTTOM[i] - BLUE_TOP[i]) * e) for i in range(3))
plate.paste(gradient.resize((w, w)), (0, 0), mask)

# A highlight across the top edge, so the plate reads as a surface not a swatch.
gloss = Image.new("L", (w, w), 0)
ImageDraw.Draw(gloss).ellipse(
    [w * 0.05, -w * 0.30, w * 0.95, w * 0.30], fill=52)
gloss = gloss.filter(ImageFilter.GaussianBlur(w * 0.05))
white = Image.new("RGBA", (w, w), (255, 255, 255, 255))
white.putalpha(Image.composite(gloss, Image.new("L", (w, w), 0), mask))
plate = Image.alpha_composite(plate, white)

# ---------------------------------------------------------------- folder
# Sized to the plate, not the canvas, and centred optically: a folder is
# top-heavy, so it sits a little below centre.
FW, FH = PLATE * 0.60, PLATE * 0.50
cx, cy = w / 2, w / 2 + PLATE * SS * 0.012
fw, fh = FW * SS, FH * SS
left, top = cx - fw / 2, cy - fh / 2
r = fw * 0.11
tab_w, tab_h = fw * 0.40, fh * 0.17

folder = Image.new("L", (w, w), 0)
fd = ImageDraw.Draw(folder)
# Back of the folder: the tab, a rounded rect tucked behind the body.
fd.rounded_rectangle([left, top, left + tab_w + r * 2, top + tab_h * 2 + r],
                     radius=r * 0.8, fill=255)
# Body.
fd.rounded_rectangle([left, top + tab_h, left + fw, top + fh], radius=r, fill=255)

art = Image.new("RGBA", (w, w), (0, 0, 0, 0))
ImageDraw.Draw(art).rectangle([0, 0, w, w], fill=(0xEC, 0xF4, 0xFD, 255))

# Waves filling the lower part of the folder, each a sine band.
band = Image.new("RGBA", (w, w), (0, 0, 0, 0))
bd = ImageDraw.Draw(band)
body_top, body_bottom = top + tab_h, top + fh
for i, colour in enumerate(WAVES):
    base = body_top + (body_bottom - body_top) * (0.42 + 0.145 * i)
    amp = fh * (0.085 - 0.012 * i)
    phase = 0.7 * i
    pts = [(left + fw * x / 120,
            base + math.sin(x / 120 * math.pi * 1.7 + phase) * amp)
           for x in range(121)]
    pts += [(left + fw, body_bottom + 10), (left, body_bottom + 10)]
    bd.polygon(pts, fill=colour + (255,))
art = Image.alpha_composite(art, band)

# The artwork exists only inside the folder shape.
art.putalpha(folder)

# A soft drop shadow under the folder, so it sits on the plate.
shadow = Image.new("RGBA", (w, w), (0, 0, 0, 0))
shadow.putalpha(folder.filter(ImageFilter.GaussianBlur(w * 0.012)))
shadow = Image.alpha_composite(Image.new("RGBA", (w, w), (0, 0, 0, 0)),
                               Image.new("RGBA", (w, w), (10, 40, 74, 90)))
shadow.putalpha(Image.eval(folder.filter(ImageFilter.GaussianBlur(w * 0.014)),
                           lambda v: int(v * 0.45)))
shadow = shadow.transform(
    (w, w), Image.AFFINE, (1, 0, 0, 0, 1, -w * 0.012), resample=Image.BILINEAR)

icon = Image.alpha_composite(plate, shadow)
icon = Image.alpha_composite(icon, art)
icon = icon.resize((SIZE, SIZE), Image.LANCZOS)
icon.save("Support/icon/icon-1024.png")
print("wrote Support/icon/icon-1024.png")
