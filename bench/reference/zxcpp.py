"""Reference decoder: prints zxing-cpp results as JSON lines, one per input image.

Usage: python -I bench/reference/zxcpp.py [--rotate DEG] IMAGE...
Needs `pip install zxing-cpp pillow` (dev only; see DESIGN.md for the venv path).
"""
import json, sys
import zxingcpp
from PIL import Image

args = sys.argv[1:]
rot = 0
if args[:1] == ["--rotate"]:
    rot = int(args[1]); args = args[2:]
for path in args:
    img = Image.open(path).convert("L")
    if rot:
        img = img.rotate(rot, expand=True)
    out = []
    for r in zxingcpp.read_barcodes(img, formats=zxingcpp.BarcodeFormat.QRCode):
        p = r.position
        out.append({
            "text": r.text,
            "bytes_hex": bytes(r.bytes).hex(),
            "corners": [[p.top_left.x, p.top_left.y], [p.top_right.x, p.top_right.y],
                        [p.bottom_right.x, p.bottom_right.y], [p.bottom_left.x, p.bottom_left.y]],
            "version": getattr(r, "version", None),
            "ec_level": getattr(r, "ec_level", None),
            "orientation": r.orientation,
            "mirrored": getattr(r, "is_mirrored", None),
            "symbology_identifier": getattr(r, "symbology_identifier", None),
        })
    print(json.dumps({"image": path, "rotate": rot, "results": out}, ensure_ascii=False))
