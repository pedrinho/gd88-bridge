"""Write a small test PDF (e.g. a 210 x 39 mm strip) for short test prints.

usage: python3 tools/mkstrip.py OUT WIDTH_PT HEIGHT_PT PAGES TEXT [--bars]
Each page gets one line of large text (with the page number) and, with --bars,
a few solid black bars for byte-exact comparisons.
"""
import sys

out, W, H, pages, text = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
bars = "--bars" in sys.argv


def esc(s):
    return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


objs = []  # 1-based object list; filled below
kids = []
font_obj = 3
objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
objs.append(None)  # Pages, filled later
objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>")
for p in range(pages):
    ops = [f"BT /F1 26 Tf 36 {H - 50:.1f} Td ({esc(text)} - page {p + 1}) Tj ET"]
    if bars:
        ops.append("0 g")
        for i in range(4):
            ops.append(f"{36 + i * 120} {H - 90:.1f} 80 20 re f")
    stream = "\n".join(ops).encode()
    content_num = len(objs) + 1
    objs.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
    page_num = len(objs) + 1
    objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {W:g} {H:g}] "
                f"/Resources << /Font << /F1 {font_obj} 0 R >> >> /Contents {content_num} 0 R >>".encode())
    kids.append(f"{page_num} 0 R")
objs[1] = f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {pages} >>".encode()

pdf = bytearray(b"%PDF-1.4\n")
offsets = []
for i, body in enumerate(objs, 1):
    offsets.append(len(pdf))
    pdf += b"%d 0 obj\n" % i + body + b"\nendobj\n"
xref = len(pdf)
pdf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
for off in offsets:
    pdf += b"%010d 00000 n \n" % off
pdf += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(out, "wb").write(pdf)
print(f"wrote {out}: {pages} page(s) {W:g}x{H:g} pt")
