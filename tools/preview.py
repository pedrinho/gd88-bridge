"""Render GD-88 printer bytes (GS v 0 strips) as a PGM image.  usage: preview.py IN.bin OUT.pgm [SCALE]
import sys

data = open(sys.argv[1], "rb").read()
rows, width, i = [], 0, 0
while True:
    j = data.find(b"\x1d\x76\x30", i)
    if j < 0:
        break
    w = data[j + 4] | data[j + 5] << 8
    h = data[j + 6] | data[j + 7] << 8
    block = data[j + 8:j + 8 + w * h]
    width = w
    for r in range(h):
        rows.append(block[r * w:(r + 1) * w])
    i = j + 8 + w * h
scale = int(sys.argv[3]) if len(sys.argv) > 3 else 2
W, H = width * 8 // scale, len(rows) // scale
out = bytearray()
for y in range(H):
    for x in range(W):
        ink = 0
        for dy in range(scale):
            row = rows[y * scale + dy]
            for dx in range(scale):
                xx = x * scale + dx
                ink += (row[xx >> 3] >> (7 - (xx & 7))) & 1
        out.append(255 - ink * 255 // (scale * scale))
open(sys.argv[2], "wb").write(b"P5\n%d %d\n255\n" % (W, H) + bytes(out))
print(f"{width * 8}x{len(rows)} dots -> {W}x{H} preview")
