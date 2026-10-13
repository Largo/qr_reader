"""Reference encoder: zxing-cpp's QR writer (zint backend) as an independent symbol source.

Usage: python -I bench/reference/zxcpp_write.py < requests.jsonl

Each input line is a JSON object {"text": str, "ec_level": "L"|"M"|"Q"|"H"}; each output
line is {"rows": ["0101...", ...]} with one string per module row (1 = dark, no quiet
zone), or {"error": "..."} when the writer rejects the request. zint chooses the version
(smallest that fits), the segmentation and the mask (ISO/IEC 18004:2015 penalty rules).
Needs `pip install zxing-cpp numpy` (dev only; see DESIGN.md for the venv path).
"""
import json, sys
import numpy as np
import zxingcpp

for line in sys.stdin:
    if not line.strip():
        continue
    req = json.loads(line)
    try:
        barcode = zxingcpp.create_barcode(req["text"], zxingcpp.BarcodeFormat.QRCode, ec_level=req.get("ec_level", "M"))
        modules = np.array(zxingcpp.write_barcode_to_image(barcode, scale=1, add_quiet_zones=False))
        out = {"rows": ["".join("1" if v < 128 else "0" for v in row) for row in modules]}
    except Exception as e:  # report and keep going
        out = {"error": "%s: %s" % (type(e).__name__, e)}
    print(json.dumps(out), flush=True)
