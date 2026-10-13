"""zxing-cpp baseline for the scan corpus (bench/scans/run.rb --reference).

Usage: python -I bench/scans/zxcpp.py < cases.jsonl

Each input line is {"id": ..., "path": ...}; each output line is
{"id", "ms", "pages", "results": [{"text", "page", "corners"}], "error"}.
"ms" is zxing-cpp's decode time summed over all pages (image loading
excluded). Multi-page TIFFs are read frame by frame; PDF pages are taken
as the embedded raster images, extracted losslessly with poppler's
`pdfimages -png -p` (Pillow cannot open PDF). Images are converted to 8-bit
luminance like bench/reference/zxcpp.py does. TextMode Plain, otherwise
zxing-cpp's defaults (try_rotate, try_downscale, try_invert).

Needs `pip install zxing-cpp pillow` and poppler-utils (dev only).
"""
import glob, json, os, re, subprocess, sys, tempfile, time
import zxingcpp
from PIL import Image, ImageSequence


def luminance(img):
    if img.mode in ("I;16", "I;16B", "I;16L", "I;16N", "I"):
        return img.convert("I").point(lambda v: v * (1 / 257)).convert("L")
    if img.mode in ("RGBA", "LA", "PA", "RGBa", "La") or "transparency" in img.info:
        rgba = img.convert("RGBA")
        img = Image.alpha_composite(Image.new("RGBA", rgba.size, (255, 255, 255, 255)), rgba)
    return img.convert("L")


def pages(path):
    """Yields (page index, luminance image)."""
    if path.lower().endswith(".pdf"):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["pdfimages", "-png", "-p", path, os.path.join(tmp, "img")], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for name in sorted(glob.glob(os.path.join(tmp, "img-*.png"))):
                page = int(re.search(r"img-(\d+)-\d+\.png$", name).group(1)) - 1
                with Image.open(name) as img:
                    img.load()
                    yield page, luminance(img)
        return
    with Image.open(path) as img:
        multi = getattr(img, "n_frames", 1) > 1
        # (The iterator seeks one Image object: convert each frame before moving on.)
        for i, frame in enumerate(ImageSequence.Iterator(img)):
            frame.load()
            yield (i if multi else None), luminance(frame.copy())


for line in sys.stdin:
    if not line.strip():
        continue
    case = json.loads(line)
    out = {"id": case["id"], "ms": 0.0, "pages": 0, "results": []}
    try:
        for page, img in pages(case["path"]):
            out["pages"] += 1
            start = time.perf_counter()
            barcodes = zxingcpp.read_barcodes(img, formats=zxingcpp.BarcodeFormat.QRCode,
                                              text_mode=zxingcpp.TextMode.Plain)
            out["ms"] += (time.perf_counter() - start) * 1000
            for r in barcodes:
                p = r.position
                out["results"].append({
                    "text": r.text, "page": page,
                    "corners": [[p.top_left.x, p.top_left.y], [p.top_right.x, p.top_right.y],
                                [p.bottom_right.x, p.bottom_right.y], [p.bottom_left.x, p.bottom_left.y]],
                })
        out["ms"] = round(out["ms"], 3)
    except Exception as e:  # report and keep going
        out["error"] = "%s: %s" % (type(e).__name__, e)
    print(json.dumps(out, ensure_ascii=False), flush=True)
