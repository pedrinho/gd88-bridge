"""Offline self-test for gd88bridge (nothing is printed).

usage: python3 -I tools/selftest.py PATH/TO/gd88bridge TMPDIR

1. Raster decoding: a synthetic 2-page grayscale CUPS raster is converted with macOS's own CUPS
   filters (rastertopwg -> PWG raster, rastertourf -> Apple Raster); `gd88bridge --decode` must give
   back exactly the source pixels (over the width the filter keeps).
2. Trimming: a mostly blank A4 page must shrink by more than 80 %.
3. Vendor parity (only if the vendor GD-88 driver is installed): for a pure black/white page the
   threshold encoder must produce the vendor filter's output byte for byte.
"""
import os
import random
import struct
import subprocess
import sys

BRIDGE, TMP = sys.argv[1], sys.argv[2]
FILTERS = "/usr/libexec/cups/filter"
VENDOR = "/Library/Printers/XMDY/Filter/rastertoGD88"
VENDOR_PPD = "/Library/Printers/PPDs/Contents/Resources/GD-88.ppd"
W = 1678                                           # A4 width at 203 dpi, as CUPS renders it
failures = 0


def check(ok, text):
    global failures
    print(("  ok    " if ok else "  FAIL  ") + text)
    failures += 0 if ok else 1


def run(cmd, out, env=None):
    with open(out, "wb") as f:
        return subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE, env=env).returncode


def cups_raster(path, pages, ph, colorspace, pixel):
    """Uncompressed CUPS raster, little-endian like cupsfilter writes it ("3SaR"), 8 bits per pixel, 203 dpi.
    `ph` is the page height in points; the row count must match it (PWG filters check this)."""
    h = bytearray(1796)
    pw = 595
    height = int(ph * 203 / 72 + 0.5)
    # The same fields cupsfilter sets: CUPS's filters reject headers without e.g. cupsNumColors
    # (offset 420) or a cupsPageSizeName (offset 1732).
    for off, v in ((276, 203), (280, 203), (292, pw), (296, ph), (340, 1), (352, pw), (356, ph), (372, W),
                   (376, height), (384, 8), (388, 8), (392, W), (400, colorspace), (408, 8), (420, 1), (452, 1)):
        struct.pack_into("<I", h, off, v)
    for off, f in ((424, 1.0), (428, pw), (432, ph), (444, pw), (448, ph)):
        struct.pack_into("<f", h, off, float(f))
    h[1732:1738] = b"Custom"
    data = bytearray(b"3SaR")
    rng = random.Random(1)
    for p in range(pages):
        data += h
        for y in range(height):
            data += bytes(pixel(p, x, y, rng) for x in range(W))
    open(path, "wb").write(data)


def decode(path):
    out = path + ".gray"
    subprocess.run([BRIDGE, "--decode", path, out], check=True, stderr=subprocess.DEVNULL)
    return open(out, "rb").read()


print("1. raster decoding vs macOS CUPS filters")
src = os.path.join(TMP, "gray.ras")
cups_raster(src, 2, 110, 18, lambda p, x, y, r: 255 if y % 37 == 0 else (x * 3 + y * 5 + p * 77) % 256)
reference = decode(src)
for name, filt in (("PWG raster", "rastertopwg"), ("Apple Raster (URF)", "rastertourf")):
    out = os.path.join(TMP, filt + ".out")
    if run([os.path.join(FILTERS, filt), "1", "u", "t", "1", "", src], out) != 0 or os.path.getsize(out) == 0:
        check(False, f"{name}: CUPS filter {filt} failed")
        continue
    got = decode(out)
    rows = int(110 * 203 / 72 + 0.5)
    w = len(got) // (2 * rows)                      # the filter may drop a column (1677 px)
    same = all(reference[r * W:r * W + w] == got[r * w:(r + 1) * w] for r in range(2 * rows))
    check(same and len(got) == 2 * rows * w, f"{name}: {w} px wide, 2 pages decode to the exact source pixels")

print("2. trimming blank paper at the end of a job")
a4 = os.path.join(TMP, "a4.ras")
cups_raster(a4, 1, 842, 18, lambda p, x, y, r: 0 if (y < 60 and 100 < x < 1500) else 255)
subprocess.run([BRIDGE, "--encode", a4, a4 + ".full", "--no-trim"], check=True, stderr=subprocess.DEVNULL)
subprocess.run([BRIDGE, "--encode", a4, a4 + ".trim"], check=True, stderr=subprocess.DEVNULL)
full, trim = os.path.getsize(a4 + ".full"), os.path.getsize(a4 + ".trim")
check(trim < full * 0.2, f"A4 page with 7 mm of content: {full} -> {trim} bytes ({100 - 100 * trim // full}% less)")

print("3. byte-exact comparison with the vendor driver")
if os.path.exists(VENDOR) and os.path.exists(VENDOR_PPD):
    bw = os.path.join(TMP, "bw.ras")
    cups_raster(bw, 2, 110, 0, lambda p, x, y, r: (0 if (x // 7 + p) % 2 else 255) if y < 40 else
                (0 if r.random() < 0.3 else 255) if y < 120 else (0 if 200 < x < 900 else 255) if y < 200 else 255)
    rc = run([VENDOR, "1", "u", "t", "1", "", bw], bw + ".vendor", env={**os.environ, "PPD": VENDOR_PPD})
    subprocess.run([BRIDGE, "--encode", bw, bw + ".ours", "--quality", "3", "--no-trim"], check=True, stderr=subprocess.DEVNULL)
    a, b = open(bw + ".vendor", "rb").read(), open(bw + ".ours", "rb").read()
    check(rc == 0 and a == b, f"2 black/white pages: vendor {len(a)} bytes, gd88bridge {len(b)} bytes, identical")
else:
    print("  skip  vendor driver not installed")

sys.exit(1 if failures else 0)
