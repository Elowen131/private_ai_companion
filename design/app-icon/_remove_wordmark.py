"""Remove the "AI COMPANION" wordmark from the chosen artwork.

Everything else -- the speech bubble, nodes, heart, hand, stars, dashed trail,
rounded card and its lavender gradient -- is left byte-for-byte untouched.

The wordmark occupies y=790..859 and the thin underline y=880..889. The rows
immediately above (740..789) and below (900..949) are clean card background, so
a per-column base gradient is interpolated between row 774 and row 901.

Only pixels that DIFFER from that base (the glyphs, side dashes, underline and
their antialiasing fringes) are replaced. Repainting the whole band would erase
the card's own subtle texture and leave a visible rectangular patch, so all
background pixels are kept byte-for-byte unchanged.

Usage: python design/app-icon/_remove_wordmark.py
"""
import os
import sys

DESIGN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DESIGN)
from _make_icons import decode_png, write_png, resize  # noqa: E402

SRC = os.path.join(DESIGN, "artwork-master-1024.png")
OUT = os.path.join(DESIGN, "artwork-master-1024-noword.png")
COMPARE = os.path.join(DESIGN, "_noword-compare.png")

X0, X1 = 80, 944        # inside the card, keeps the outer edge gradient
Y0, Y1 = 775, 900       # covers wordmark + side dashes + underline
TOP_REF, BOT_REF = 774, 901
CORE_X0, CORE_X1 = 170, 920   # wordmark-only area, used for clean-row checks


def get_px(pix, w, x, y):
    i = (y * w + x) * 3
    return pix[i], pix[i + 1], pix[i + 2]


def set_px(pix, w, x, y, c):
    i = (y * w + x) * 3
    pix[i], pix[i + 1], pix[i + 2] = c


def lum(c):
    return (c[0] * 299 + c[1] * 587 + c[2] * 114) // 1000


def dark_count(pix, w):
    """Non-background pixels in the wordmark-only area (threshold 200 catches
    the pale underline and side dashes, not just the dark glyphs)."""
    n = 0
    for y in range(Y0, Y1 + 1):
        for x in range(CORE_X0, CORE_X1 + 1):
            if lum(get_px(pix, w, x, y)) < 200:
                n += 1
    return n


def main():
    pix, w, h = decode_png(SRC)
    assert (w, h) == (1024, 1024)
    # the two reference rows must be free of artwork
    for ref in (TOP_REF, BOT_REF):
        assert all(lum(get_px(pix, w, x, ref)) >= 200 for x in range(CORE_X0, CORE_X1 + 1)), \
            "reference row %d is not clean in the wordmark area" % ref

    before = dark_count(pix, w)
    print("source wordmark-area pixels in band: %d" % before)

    span = BOT_REF - TOP_REF
    base = {}
    for x in range(X0, X1 + 1):
        a = get_px(pix, w, x, TOP_REF)
        b = get_px(pix, w, x, BOT_REF)
        base[x] = [tuple(int(a[k] * (1 - (y - TOP_REF) / span) + b[k] * ((y - TOP_REF) / span) + 0.5)
                         for k in range(3))
                   for y in range(Y0, Y1 + 1)]

    marked = set()
    for x in range(X0, X1 + 1):
        for y in range(Y0, Y1 + 1):
            c = get_px(pix, w, x, y)
            b = base[x][y - Y0]
            if max(abs(c[k] - b[k]) for k in range(3)) > 22:
                marked.add((x, y))
    glyph_px = len(marked)
    radius = 3
    for (x, y) in list(marked):
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                xx, yy = x + dx, y + dy
                if X0 <= xx <= X1 and Y0 <= yy <= Y1:
                    marked.add((xx, yy))
    for (x, y) in marked:
        set_px(pix, w, x, y, base[x][y - Y0])
    print("repainted %d glyph px (+3px fringe) -> %d px of %d in band (%.1f%%)"
          % (glyph_px, len(marked), (X1 - X0 + 1) * (Y1 - Y0 + 1),
             100.0 * len(marked) / ((X1 - X0 + 1) * (Y1 - Y0 + 1))))

    after = dark_count(pix, w)
    assert after == 0, "wordmark band still has %d dark pixels" % after
    write_png(OUT, pix, w, h)
    print("wrote %s  (wordmark-area pixels: %d -> %d)" % (OUT, before, after))

    # side-by-side before/after for visual QA
    original = decode_png(SRC)[0]
    n = 512
    left = resize(original, w, h, n)
    right = resize(pix, w, h, n)
    gap = 16
    canvas = bytearray(bytes((0xF4, 0xF1, 0xFA)) * ((2 * n + 3 * gap) * (n + 2 * gap)))
    cw = 2 * n + 3 * gap
    for yy in range(n):
        for side, src in ((0, left), (1, right)):
            xoff = gap + side * (n + gap)
            row = (yy + gap) * cw
            s = yy * n * 3
            d = (row + xoff) * 3
            canvas[d:d + n * 3] = src[s:s + n * 3]
    write_png(COMPARE, canvas, cw, n + 2 * gap)
    print("wrote %s (%dx%d)" % (COMPARE, cw, n + 2 * gap))


if __name__ == "__main__":
    main()
