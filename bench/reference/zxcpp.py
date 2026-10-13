"""Reference decoder: prints zxing-cpp results as JSON lines, one per input image.

Usage: python -I bench/reference/zxcpp.py [options] IMAGE...

  --rotate DEG      rotate counter-clockwise by DEG (PIL semantics, any angle, canvas expanded)
  --rotate-cw DEG   rotate clockwise by a multiple of 90 degrees, exactly like
                    QrReader::Image#rotate (lossless transpose)
  --text-mode MODE  zxing-cpp TextMode: HRI (default), Plain, ECI, Escaped, Hex, HexECI
  --pure            the images contain nothing but an axis-aligned symbol (is_pure)

Each output line: {"image", "rotate", "rotate_cw", "ms", "results": [{"text", "bytes_hex",
"corners" (TL, TR, BR, BL), "version", "mask", "ec_level", "orientation", "mirrored",
"symbology_identifier", "content_type"}]}. "ms" is the zxing-cpp decode time only.
An image that cannot be loaded gives {"image", "error", "results": []} instead.

Images are converted to 8-bit luminance like QrReader does: alpha is composited over
white and 16-bit samples are scaled (PIL's plain convert("L") would drop the alpha
and clip 16-bit values).
Needs `pip install zxing-cpp pillow` (dev only; see DESIGN.md for the venv path).
"""
import json, sys, time
import zxingcpp
from PIL import Image

CW_TRANSPOSE = {90: Image.Transpose.ROTATE_270, 180: Image.Transpose.ROTATE_180, 270: Image.Transpose.ROTATE_90}

args = sys.argv[1:]
rot = 0
rot_cw = 0
text_mode = "HRI"
pure = False
while args and args[0].startswith("--"):
    opt = args.pop(0)
    if opt == "--rotate":
        rot = int(args.pop(0))
    elif opt == "--rotate-cw":
        rot_cw = int(args.pop(0)) % 360
        if rot_cw not in (0, 90, 180, 270):
            sys.exit("--rotate-cw needs a multiple of 90")
    elif opt == "--text-mode":
        text_mode = args.pop(0)
    elif opt == "--pure":
        pure = True
    else:
        sys.exit("unknown option " + opt)
mode = getattr(zxingcpp.TextMode, text_mode)


def load_luminance(path):
    img = Image.open(path)
    img.load()
    if img.mode in ("I;16", "I;16B", "I;16L", "I;16N", "I"):
        img = img.convert("I").point(lambda v: v * (1 / 257)).convert("L")
    elif img.mode in ("RGBA", "LA", "PA", "RGBa", "La") or "transparency" in img.info:
        rgba = img.convert("RGBA")
        img = Image.alpha_composite(Image.new("RGBA", rgba.size, (255, 255, 255, 255)), rgba)
    return img.convert("L")


def as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


for path in args:
    try:
        img = load_luminance(path)
    except Exception as e:  # unreadable image: report it and keep going
        print(json.dumps({"image": path, "rotate": rot, "rotate_cw": rot_cw, "ms": None, "results": [],
                          "error": "%s: %s" % (type(e).__name__, e)}), flush=True)
        continue
    if rot:
        img = img.rotate(rot, expand=True)
    if rot_cw:
        img = img.transpose(CW_TRANSPOSE[rot_cw])
    start = time.perf_counter()
    barcodes = zxingcpp.read_barcodes(img, formats=zxingcpp.BarcodeFormat.QRCode, text_mode=mode, is_pure=pure)
    ms = (time.perf_counter() - start) * 1000
    out = []
    for r in barcodes:
        p = r.position
        extra = getattr(r, "extra", None) or {}
        if isinstance(extra, str):
            extra = json.loads(extra or "{}")
        out.append({
            "text": r.text,
            "bytes_hex": bytes(r.bytes).hex(),
            "corners": [[p.top_left.x, p.top_left.y], [p.top_right.x, p.top_right.y],
                        [p.bottom_right.x, p.bottom_right.y], [p.bottom_left.x, p.bottom_left.y]],
            "version": as_int(extra.get("Version", getattr(r, "version", None))),
            "mask": as_int(extra.get("DataMask")),
            "ec_level": getattr(r, "ec_level", None),
            "orientation": r.orientation,
            "mirrored": getattr(r, "is_mirrored", None),
            "symbology_identifier": getattr(r, "symbology_identifier", None),
            "content_type": str(getattr(r, "content_type", "")).split(".")[-1] or None,
        })
    print(json.dumps({"image": path, "rotate": rot, "rotate_cw": rot_cw, "ms": round(ms, 3), "results": out},
                     ensure_ascii=False), flush=True)
