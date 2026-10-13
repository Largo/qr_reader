"""Development-only fixture generator: zxing_cpp_symbols.jsonl.

Encodes assorted contents with zxing-cpp's writer (libzint backend, an encoder
independent of rqrcode_core and of the test builder), takes the module grid
from a 1-pixel-per-module rendering, and records zxing-cpp's own decoding of
an enlarged rendering as the reference.

    python -I test/decoder/fixtures/generate_zxing_cpp_symbols.py > test/decoder/fixtures/zxing_cpp_symbols.jsonl

Needs `pip install zxing-cpp pillow numpy` (see DESIGN.md for the venv path).
"""
import json
import sys

import numpy
import zxingcpp
from PIL import Image

CASES = [
    ("Hello, World!", {}),
    ("https://github.com/zxing-cpp/zxing-cpp?q=1&r=%20", {"ec_level": "L"}),
    ("0123456789" * 20, {"ec_level": "M"}),
    ("ALPHANUMERIC $%*+-./: 123", {"ec_level": "Q"}),
    ("漢字テスト", {}),
    ("今度のバージョンでは文章の暗号化ができます。", {"ec_level": "M"}),
    ("Google モバイル\r\nhttp://google.jp", {"ec_level": "L"}),
    ("ﾃﾞｻﾞｲﾝQR\r\nhttp://d-qr.net/ex/", {"ec_level": "M"}),
    ("Grüße aus Zürich – 10 €", {}),
    ("Ünïcödé façade naïve", {"ec_level": "H"}),
    ("Привет, мир", {}),
    ("Γειά σου Κόσμε", {}),
    ("中文测试，二维码", {}),
    ("한국어 텍스트", {}),
    ("emoji 😀 🚀", {}),
    ("mixed ASCII 123456789012 and 漢字 and ｶﾀｶﾅ", {"ec_level": "Q"}),
    (b"\x00\x01\x02\xfe\xff binary \x80\x81", {}),
    (bytes(range(256)), {"ec_level": "L"}),
    ("(01)09521234543213(3103)000123", {"gs1": True}),
    ("(01)04912345123459(10)ABC%DEF", {"gs1": True, "ec_level": "Q"}),
    ("A" * 300, {"ec_level": "H"}),
    ("The quick brown fox jumps over the lazy dog. " * 40, {"ec_level": "L"}),
    ("x", {"version": 7, "ec_level": "H"}),
    ("v40", {"version": 40, "ec_level": "Q"}),
]

for mask in range(8):
    CASES.append(("mask %d" % mask, {"data_mask": mask, "ec_level": "LMQH"[mask % 4]}))

for content, options in CASES:
    barcode = zxingcpp.create_barcode(content, zxingcpp.BarcodeFormat.QRCode, **options)
    grid = numpy.array(barcode.to_image(scale=1, add_quiet_zones=False))
    rows = ["".join("1" if v < 128 else "0" for v in row) for row in grid]
    big = Image.fromarray(numpy.array(barcode.to_image(scale=4, add_quiet_zones=True)))
    result = zxingcpp.read_barcode(big, formats=zxingcpp.BarcodeFormat.QRCode, text_mode=zxingcpp.TextMode.Plain)
    if result is None:
        sys.exit("zxing-cpp could not read back %r" % (content,))
    extra = result.extra or {}
    print(json.dumps({
        "rows": rows,
        "text": result.text,
        "bytes_hex": bytes(result.bytes).hex(),
        "symbology_identifier": result.symbology_identifier,
        "version": int(extra.get("Version")),
        "ec_level": result.ec_level,
        "mask": int(extra.get("DataMask")),
        "content_type": str(result.content_type).split(".")[-1],
    }, ensure_ascii=False))
