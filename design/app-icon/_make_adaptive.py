"""Build Android 8+ (API 26+) adaptive icon layers from the user's artwork.

Source of truth: design/app-icon/artwork-master-1024.png -- the exact artwork the
user chose. No element is redrawn, cropped out or recoloured.

Geometry (why 56dp):
  * An adaptive icon is a 108dp x 108dp canvas. Launchers apply their own mask
    (circle / rounded square / squircle) over a ~72dp viewport. The guaranteed
    safe zone is the centred 66dp circle: radius 33dp.
  * The "AI COMPANION" wordmark was removed at the user's request, so the
    farthest remaining content is the outer edge of the graphic, about
    0.42 * card_size -> 23.5dp < 33dp. Measured on the generated composite the
    farthest dark pixel is 21.2dp, leaving 11.8dp for OEM parallax scaling.
  * 56dp was originally chosen to keep the wordmark inside the safe circle;
    it is kept after wordmark removal so the change stays minimal (the extra
    headroom is harmless). Raise CARD_DP if a larger graphic is wanted.
  * The card is therefore 56/108 = 51.9% of the canvas and ~78% of the visible
    72dp viewport: still a full-size looking icon, not a tiny stamp.

Layers:
  * foreground = complete artwork on transparent RGBA, with a 6px rounded-rect
    edge feather so the card melts into the background instead of showing a
    hard "rounded card inside a round mask" seam.
  * background = one solid pale-lavender colour sampled from the artwork.

Usage:
  python design/app-icon/_make_adaptive.py            # generate + install
  python design/app-icon/_make_adaptive.py --revert  # remove installed layers
"""
import math
import os
import shutil
import struct
import sys
import zlib

DESIGN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(DESIGN, "..", ".."))
sys.path.insert(0, DESIGN)
from _make_icons import decode_png, resize, chunk  # noqa: E402

SRC = os.environ.get("ICON_SOURCE", os.path.join(DESIGN, "artwork-master-1024.png"))
OUT = os.path.join(DESIGN, "_adaptive")
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")

CANVAS_DP = 108
CARD_DP = 56
SAFE_DP = 66
BASE = 432                                   # xxxhdpi = 108dp * 4
CARD = round(BASE * CARD_DP / CANVAS_DP)    # 224 px
OFF = (BASE - CARD) // 2                    # 104 px
CORNER_R = CARD * 0.20
FEATHER = 12.0
BG = (0xF4, 0xF1, 0xFA)                     # sampled from the artwork
BG_HEX = "#%02X%02X%02X" % BG

DENSITIES = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

COLOR_XML = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Adaptive launcher icon background, sampled from design/app-icon/artwork-master-1024.png -->
    <color name="ic_launcher_background">%s</color>
</resources>
""" % BG_HEX

ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- Android 8+ (API 26+). API < 26 keeps using the legacy mipmap-*/ic_launcher.png files. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""


def box_half_c(pix, w, h, c):
    nw, nh = w // 2, h // 2
    out = bytearray(nw * nh * c)
    for y in range(nh):
        r0 = (2 * y) * w * c
        r1 = (2 * y + 1) * w * c
        for x in range(nw):
            a = r0 + 2 * x * c
            b = r1 + 2 * x * c
            o = (y * nw + x) * c
            for k in range(c):
                out[o + k] = (pix[a + k] + pix[a + c + k] + pix[b + k] + pix[b + c + k] + 2) >> 2
    return out, nw, nh


def bilinear_c(pix, w, h, n, c):
    out = bytearray(n * n * c)
    for y in range(n):
        sy = max(0.0, (y + 0.5) * h / n - 0.5)
        y0 = int(sy)
        y1 = min(h - 1, y0 + 1)
        fy = sy - y0
        for x in range(n):
            sx = max(0.0, (x + 0.5) * w / n - 0.5)
            x0 = int(sx)
            x1 = min(w - 1, x0 + 1)
            fx = sx - x0
            p00 = (y0 * w + x0) * c
            p01 = (y0 * w + x1) * c
            p10 = (y1 * w + x0) * c
            p11 = (y1 * w + x1) * c
            o = (y * n + x) * c
            for k in range(c):
                top = pix[p00 + k] * (1 - fx) + pix[p01 + k] * fx
                bot = pix[p10 + k] * (1 - fx) + pix[p11 + k] * fx
                v = top * (1 - fy) + bot * fy
                out[o + k] = min(255, int(v + 0.5))
    return out


def resize_c(pix, w, h, n, c):
    cw, ch, cur = w, h, pix
    while cw // 2 >= n and ch // 2 >= n:
        cur, cw, ch = box_half_c(cur, cw, ch, c)
    if cw == n and ch == n:
        return cur
    return bilinear_c(cur, cw, ch, n, c)


def write_png_rgba(path, pix, w, h):
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)
        raw += pix[y * stride:(y + 1) * stride]
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def write_png_rgb(path, pix, w, h):
    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)
        raw += pix[y * stride:(y + 1) * stride]
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def build_foreground():
    src, w, h = decode_png(SRC)
    assert (w, h) == (1024, 1024), "unexpected source size %dx%d" % (w, h)
    card_rgb = resize(src, w, h, CARD)
    fg = bytearray(BASE * BASE * 4)  # zero = fully transparent
    half = CARD / 2.0
    for cy in range(CARD):
        for cx in range(CARD):
            dx = abs(cx + 0.5 - half)
            dy = abs(cy + 0.5 - half)
            qx = dx - (half - CORNER_R)
            qy = dy - (half - CORNER_R)
            d = math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - CORNER_R
            alpha = max(0.0, min(1.0, -d / FEATHER))
            if alpha <= 0:
                continue
            s = (cy * CARD + cx) * 3
            o = ((cy + OFF) * BASE + (cx + OFF)) * 4
            fg[o] = card_rgb[s]
            fg[o + 1] = card_rgb[s + 1]
            fg[o + 2] = card_rgb[s + 2]
            fg[o + 3] = int(alpha * 255 + 0.5)
    return fg


def composite(fg):
    out = bytearray(BASE * BASE * 3)
    for i in range(BASE * BASE):
        a = fg[i * 4 + 3] / 255.0
        for k in range(3):
            out[i * 3 + k] = int(BG[k] * (1 - a) + fg[i * 4 + k] * a + 0.5)
    return out


def with_safe_zone(comp):
    """Overlay the 66dp safe-zone circle as a dashed guide (QA only)."""
    out = bytearray(comp)
    radius = BASE * SAFE_DP / CANVAS_DP / 2.0   # 132 px
    cx = cy = BASE / 2.0
    steps = 720
    for s in range(steps):
        if (s // 9) % 2:            # dashed
            continue
        t = 2 * math.pi * s / steps
        x = int(cx + radius * math.cos(t) + 0.5)
        y = int(cy + radius * math.sin(t) + 0.5)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                xx, yy = x + dx, y + dy
                if 0 <= xx < BASE and 0 <= yy < BASE:
                    o = (yy * BASE + xx) * 3
                    out[o], out[o + 1], out[o + 2] = 0x8B, 0x6F, 0xE8
    return out


def content_radius(comp):
    """Max radius of any dark (information-bearing) pixel, in canvas px."""
    c = BASE / 2.0
    max_r, count = 0.0, 0
    for y in range(BASE):
        for x in range(BASE):
            o = (y * BASE + x) * 3
            lum = (comp[o] * 299 + comp[o + 1] * 587 + comp[o + 2] * 114) // 1000
            if lum < 170:
                r = math.hypot(x + 0.5 - c, y + 0.5 - c)
                max_r = max(max_r, r)
                count += 1
    return max_r, count


def build_mask_preview(comp):
    """Show the same canvas under 4 real launcher masks (72dp viewport)."""
    v = round(BASE * 72.0 / CANVAS_DP)      # 288 px
    off = (BASE - v) // 2                   # 72 px
    half = v / 2.0
    desktop = (0xE7, 0xE4, 0xEF)
    gap = 16
    width = 4 * v + 5 * gap
    height = v + 2 * gap
    out = bytearray(bytes(desktop) * (width * height))
    masks = ("square", "circle", "rounded", "squircle")
    for slot, name in enumerate(masks):
        left = gap + slot * (v + gap)
        for yy in range(v):
            dy = abs(yy + 0.5 - half)
            for xx in range(v):
                dx = abs(xx + 0.5 - half)
                if name == "square":
                    inside = True
                elif name == "circle":
                    inside = math.hypot(dx, dy) <= half
                elif name == "rounded":
                    r = v * 0.22
                    qx, qy = dx - (half - r), dy - (half - r)
                    d = math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r
                    inside = d <= 0
                else:
                    inside = (dx / half) ** 4 + (dy / half) ** 4 <= 1.0
                if not inside:
                    continue
                s = ((yy + off) * BASE + (xx + off)) * 3
                d0 = ((yy + gap) * width + (left + xx)) * 3
                out[d0:d0 + 3] = comp[s:s + 3]
    return out, width, height


def alpha_stats(pix, n):
    opaque = sum(1 for i in range(n * n) if pix[i * 4 + 3] > 250)
    any_alpha = sum(1 for i in range(n * n) if pix[i * 4 + 3] > 0)
    corner = pix[3]                     # top-left pixel alpha
    center = pix[((n // 2) * n + n // 2) * 4 + 3]
    return opaque, any_alpha, corner, center


def foreground_targets():
    return [(os.path.join(RES, folder, "ic_launcher_foreground.png"), n)
            for folder, n in DENSITIES.items()]


def revert():
    removed = []
    for path, _ in foreground_targets():
        if os.path.isfile(path):
            os.remove(path)
            removed.append(path)
    xml = os.path.join(RES, "mipmap-anydpi-v26", "ic_launcher.xml")
    if os.path.isfile(xml):
        os.remove(xml)
        removed.append(xml)
        try:
            os.rmdir(os.path.dirname(xml))
        except OSError:
            pass
    colors = os.path.join(RES, "values", "colors.xml")
    if os.path.isfile(colors) and open(colors, encoding="utf-8").read() == COLOR_XML:
        os.remove(colors)
        removed.append(colors)
    print("reverted %d files:" % len(removed))
    for p in removed:
        print("  -", os.path.relpath(p, ROOT))
    print("legacy mipmap-*/ic_launcher.png untouched; API < 26 behaviour unchanged.")


def main():
    if "--revert" in sys.argv:
        revert()
        return
    os.makedirs(OUT, exist_ok=True)
    fg = build_foreground()
    opaque, any_alpha, corner, center = alpha_stats(fg, BASE)
    assert opaque > BASE * BASE * 0.15, "foreground looks empty"
    assert corner == 0, "foreground corner must be transparent"
    assert center > 250, "foreground centre must be opaque"
    print("foreground master: %dx%d  card=%dpx (%.1f%% of canvas)  opaque=%.1f%%  cornerAlpha=%d"
          % (BASE, BASE, CARD, 100.0 * CARD / BASE, 100.0 * opaque / (BASE * BASE), corner))

    write_png_rgba(os.path.join(OUT, "foreground-432.png"), fg, BASE, BASE)
    comp = composite(fg)
    write_png_rgb(os.path.join(OUT, "adaptive-composite.png"), comp, BASE, BASE)
    write_png_rgb(os.path.join(OUT, "adaptive-safezone.png"), with_safe_zone(comp), BASE, BASE)
    max_r, dark_px = content_radius(comp)
    safe_px = BASE * SAFE_DP / CANVAS_DP / 2.0
    assert max_r <= safe_px, \
        "artwork reaches %.1fpx but safe zone is only %.1fpx" % (max_r, safe_px)
    print("content check: %d dark px, farthest %.1fpx = %.1fdp (safe zone %.1fdp, margin %.1fdp)"
          % (dark_px, max_r, max_r / BASE * CANVAS_DP,
             SAFE_DP / 2, (safe_px - max_r) / BASE * CANVAS_DP))
    mask_pix, mw, mh = build_mask_preview(comp)
    write_png_rgb(os.path.join(OUT, "adaptive-masks.png"), mask_pix, mw, mh)
    print("mask preview: %dx%d (square / circle / rounded / squircle)" % (mw, mh))

    print("\nlayers per density (108dp canvas):")
    for folder, n in DENSITIES.items():
        pix = fg if n == BASE else resize_c(fg, BASE, BASE, n, 4)
        path = os.path.join(OUT, "ic_launcher_foreground-%d.png" % n)
        write_png_rgba(path, pix, n, n)
        op, aa, c0, c1 = alpha_stats(pix, n)
        assert c0 == 0 and c1 > 250, "bad alpha at %dpx" % n
        assert 0.10 < op / (n * n) < 0.40, "suspicious opaque ratio at %dpx" % n
        print("  %-16s %3d x %-3d  alpha>0 %5.1f%%  opaque %5.1f%%" %
              (folder, n, n, 100.0 * aa / (n * n), 100.0 * op / (n * n)))

    print("\ninstalling:")
    for path, n in foreground_targets():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        shutil.copy2(os.path.join(OUT, "ic_launcher_foreground-%d.png" % n), path)
        print("  ", os.path.relpath(path, ROOT))

    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w", encoding="utf-8", newline="\n") as f:
        f.write(ADAPTIVE_XML)
    print("  ", os.path.relpath(os.path.join(anydpi, "ic_launcher.xml"), ROOT))

    colors = os.path.join(RES, "values", "colors.xml")
    if os.path.isfile(colors):
        text = open(colors, encoding="utf-8").read()
        assert "ic_launcher_background" in text, \
            "values/colors.xml exists but lacks ic_launcher_background -- merge manually"
        print("  values/colors.xml already defines ic_launcher_background (kept)")
    else:
        with open(colors, "w", encoding="utf-8", newline="\n") as f:
            f.write(COLOR_XML)
        print("  ", os.path.relpath(colors, ROOT))

    print("\nbackground: %s   safe zone: %.1fdp circle, farthest artwork pixel %.1fdp" %
          (BG_HEX, SAFE_DP, max_r / BASE * CANVAS_DP))
    print("preview layers:", OUT)


if __name__ == "__main__":
    main()
