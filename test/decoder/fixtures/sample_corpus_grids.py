"""Development-only fixture generator: corpus_grids.jsonl.

Samples the module grid of every QR code that zxing-cpp finds in the ZXing
blackbox corpus (test/corpus/zxing, 0 degrees), using a single homography from
the four corners zxing-cpp reports and a global Otsu threshold - deliberately
crude, so some grids are damaged. The decoder tests check that every grid that
decodes yields exactly the corpus' expected text.

    python -I test/decoder/fixtures/sample_corpus_grids.py test/corpus/zxing > test/decoder/fixtures/corpus_grids.jsonl

Rows are stored as hex of the packed bits (MSB first, each row padded to a byte).
"""
import json, sys, glob
import numpy as np
import zxingcpp
from PIL import Image

def homography(src, dst):
    a = []
    for (x, y), (u, v) in zip(src, dst):
        a.append([x, y, 1, 0, 0, 0, -u * x, -u * y, -u])
        a.append([0, 0, 0, x, y, 1, -v * x, -v * y, -v])
    _, _, vt = np.linalg.svd(np.array(a, dtype=float))
    return vt[-1].reshape(3, 3)

def otsu(values):
    hist = np.bincount(values.astype(np.uint8).ravel(), minlength=256).astype(float)
    total = hist.sum(); sum_all = (np.arange(256) * hist).sum()
    best, thr, w0, s0 = -1, 128, 0, 0
    for t in range(256):
        w0 += hist[t]; s0 += t * hist[t]
        if w0 == 0 or w0 == total: continue
        m0 = s0 / w0; m1 = (sum_all - s0) / (total - w0)
        between = w0 * (total - w0) * (m0 - m1) ** 2
        if between > best: best, thr = between, t
    return thr

for path in sorted(glob.glob(sys.argv[1] + "/*/*.png")):
    img = Image.open(path).convert("L")
    arr = np.asarray(img, dtype=float)
    for r in zxingcpp.read_barcodes(img, formats=zxingcpp.BarcodeFormat.QRCode):
        extra = r.extra or {}
        try:
            version = int(extra.get("Version"))
        except (TypeError, ValueError):
            continue
        n = 17 + 4 * version
        p = r.position
        corners = [(p.top_left.x, p.top_left.y), (p.top_right.x, p.top_right.y),
                   (p.bottom_right.x, p.bottom_right.y), (p.bottom_left.x, p.bottom_left.y)]
        h = homography([(0, 0), (n, 0), (n, n), (0, n)], corners)
        vals = np.zeros((n, n))
        offs = [0.35, 0.5, 0.65]
        for j in range(n):
            for i in range(n):
                acc = 0
                for oy in offs:
                    for ox in offs:
                        q = h @ np.array([i + ox, j + oy, 1.0])
                        x, y = q[0] / q[2], q[1] / q[2]
                        xi = min(max(int(round(x)), 0), arr.shape[1] - 1)
                        yi = min(max(int(round(y)), 0), arr.shape[0] - 1)
                        acc += arr[yi, xi]
                vals[j, i] = acc / 9
        thr = otsu(vals)
        rows = ["".join("1" if v <= thr else "0" for v in row) for row in vals]
        hex_rows = ["%0*x" % ((n + 7) // 8 * 2, int(row + "0" * (-n % 8), 2)) for row in rows]
        print(json.dumps({"image": path.split("corpus/zxing/")[-1], "dimension": n, "rows": hex_rows}), flush=True)
