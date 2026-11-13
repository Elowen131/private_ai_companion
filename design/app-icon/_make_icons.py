"""Build launcher icons from the user-provided artwork.

Source of truth: design/app-icon/artwork-master-1024.png (the only browser render
verified to contain the complete artwork). Set the ICON_SOURCE environment variable
to an absolute path to build from a different master, e.g. the wordmark-free
artwork-master-1024-noword.png. All other sizes are derived by Python resampling
so pixel dimensions are exact and no viewport-dependent cropping can occur.
Existing launcher icons are backed up once, before being overwritten; reruns do
NOT overwrite that backup (it holds the original Flutter-logo icons).
"""
import os
import shutil
import struct
import zlib

ROOT = r"C:\Users\11827\WorkBuddy\2026-11-02-21-54-00\private_ai_companion"
DESIGN = os.path.join(ROOT, "design", "app-icon")
SRC = os.environ.get("ICON_SOURCE", os.path.join(DESIGN, "artwork-master-1024.png"))
FINAL = os.path.join(DESIGN, "_final")
BACKUP = os.path.join(DESIGN, "_backup-original-icons")

ANDROID = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

IOS = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}


def decode_png(path):
    data = open(path, "rb").read()
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", chunk[:10])
            assert depth == 8 and color == 2, "expect 8-bit RGB PNG"
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = w * 3
    pixels = bytearray(w * h * 3)
    prev = bytearray(stride)
    i = 0
    for y in range(h):
        ft = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        if ft == 1:
            for x in range(3, stride):
                line[x] = (line[x] + line[x - 3]) & 255
        elif ft == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif ft == 3:
            for x in range(stride):
                a = line[x - 3] if x >= 3 else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif ft == 4:
            for x in range(stride):
                a = line[x - 3] if x >= 3 else 0
                b = prev[x]
                c = prev[x - 3] if x >= 3 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 255
        else:
            assert ft == 0, "unsupported PNG filter %d" % ft
        pixels[y * stride:(y + 1) * stride] = line
        prev = line
    return pixels, w, h


def box_half(pix, w, h):
    nw, nh = w // 2, h // 2
    out = bytearray(nw * nh * 3)
    for y in range(nh):
        row0 = (2 * y) * w * 3
        row1 = (2 * y + 1) * w * 3
        for x in range(nw):
            a = row0 + 2 * x * 3
            b = row1 + 2 * x * 3
            o = (y * nw + x) * 3
            for c in range(3):
                out[o + c] = (pix[a + c] + pix[a + 3 + c] + pix[b + c] + pix[b + 3 + c] + 2) >> 2
    return out, nw, nh


def bilinear(pix, w, h, n):
    out = bytearray(n * n * 3)
    for y in range(n):
        sy = (y + 0.5) * h / n - 0.5
        if sy < 0:
            sy = 0.0
        y0 = int(sy)
        y1 = min(h - 1, y0 + 1)
        fy = sy - y0
        for x in range(n):
            sx = (x + 0.5) * w / n - 0.5
            if sx < 0:
                sx = 0.0
            x0 = int(sx)
            x1 = min(w - 1, x0 + 1)
            fx = sx - x0
            p00 = (y0 * w + x0) * 3
            p01 = (y0 * w + x1) * 3
            p10 = (y1 * w + x0) * 3
            p11 = (y1 * w + x1) * 3
            o = (y * n + x) * 3
            for c in range(3):
                top = pix[p00 + c] * (1 - fx) + pix[p01 + c] * fx
                bot = pix[p10 + c] * (1 - fx) + pix[p11 + c] * fx
                v = top * (1 - fy) + bot * fy
                out[o + c] = int(v + 0.5) if v < 255 else 255
    return out


def resize(pix, w, h, n):
    cw, ch, cur = w, h, pix
    while cw // 2 >= n and ch // 2 >= n:
        cur, cw, ch = box_half(cur, cw, ch)
    if cw == n and ch == n:
        return cur
    return bilinear(cur, cw, ch, n)


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def write_png(path, pix, w, h):
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


def nonwhite_ratio(path):
    pix, w, h = decode_png(path)
    count = 0
    for p in range(0, w * h * 3, 3):
        if max(255 - pix[p], 255 - pix[p + 1], 255 - pix[p + 2]) > 12:
            count += 1
    return count / (w * h)


def main():
    os.makedirs(FINAL, exist_ok=True)
    os.makedirs(BACKUP, exist_ok=True)
    base, w, h = decode_png(SRC)
    print("source: %s (%dx%d, nonwhite %.1f%%)" % (SRC, w, h, nonwhite_ratio(SRC) * 100))

    sizes = sorted(set(list(ANDROID.values()) + list(IOS.values())))
    cache = {}
    for n in sizes:
        path = os.path.join(FINAL, "%d.png" % n)
        pixels = base if n == w else resize(base, w, h, n)
        write_png(path, pixels, n, n)
        ratio = nonwhite_ratio(path)
        cache[n] = path
        assert ratio > 0.20, "size %d looks blank (nonwhite %.1f%%)" % (n, ratio * 100)
        print("  %4d x %-4d  nonwhite %5.1f%%  %6d bytes" % (n, n, ratio * 100, os.path.getsize(path)))

    targets = []
    for folder, n in ANDROID.items():
        targets.append((os.path.join(ROOT, "android", "app", "src", "main", "res", folder, "ic_launcher.png"), n, "android-" + folder))
    for name, n in IOS.items():
        targets.append((os.path.join(ROOT, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset", name), n, "ios-" + name))

    for target, n, backup_name in targets:
        assert os.path.isfile(target), "missing expected target: %s" % target
        bak = os.path.join(BACKUP, backup_name)
        if not os.path.isfile(bak):          # never overwrite the original Flutter-logo backup
            shutil.copy2(target, bak)
        shutil.copy2(cache[n], target)

    shutil.copy2(cache[1024], os.path.join(DESIGN, "final-icon-1024.png"))
    print("\ninstalled %d icon files (%d Android, %d iOS)" % (len(targets), len(ANDROID), len(IOS)))
    print("backup: %s" % BACKUP)
    print("preview: %s" % os.path.join(DESIGN, "final-icon-1024.png"))


if __name__ == "__main__":
    main()
