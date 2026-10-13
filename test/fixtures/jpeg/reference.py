# Writes the luminance libjpeg (via Pillow) produces for a JPEG, computed the
# same way QrReader::Formats::JPEG defines it:
#   gray  -> the samples
#   YCbCr -> the Y channel (no colour conversion)
#   RGB   -> Rec.601 luma, (306 R + 601 G + 117 B + 512) >> 10
#   CMYK / YCCK (Adobe, inverted) -> luma of R = C' K' / 255 etc.
# where C', K' are the values libjpeg outputs (255 = no ink); with "plain"
# (JPEG.decode cmyk: :plain) the libjpeg values are ink: C' = 255 - value.
#
# Usage: python -I reference.py IN.jpg SCALE OUT.gray [plain]
# Prints "WIDTH HEIGHT COLORSPACE". Development tool only (fixture generation).
import re
import struct
import subprocess
import sys

from PIL import Image


def color_space(data):
    """libjpeg's jpeg_color_space guess (jdapimin.c default_decompress_parms)."""
    jfif = False
    adobe = None
    ids = None
    pos = 2
    while pos + 4 <= len(data):
        if data[pos] != 0xFF:
            pos += 1
            continue
        marker = data[pos + 1]
        if marker == 0xFF:
            pos += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            pos += 2
            continue
        length = struct.unpack(">H", data[pos + 2:pos + 4])[0]
        seg = data[pos + 4:pos + 2 + length]
        if marker == 0xE0 and len(seg) >= 14 and seg[:5] == b"JFIF\0":
            jfif = True
        elif marker == 0xEE and len(seg) >= 12 and seg[:5] == b"Adobe":
            adobe = seg[11]
        elif marker in (0xC0, 0xC1, 0xC2):
            n = seg[5]
            ids = [seg[6 + 3 * i] for i in range(n)]
        elif marker == 0xDA:
            break
        pos += 2 + length
    n = len(ids)
    if n == 1:
        return "gray"
    if n == 3:
        if jfif:
            return "ycbcr"
        if adobe is not None:
            return "rgb" if adobe == 0 else "ycbcr"
        return "rgb" if ids == [82, 71, 66] else "ycbcr"
    if n == 4:
        return "cmyk" if adobe is None or adobe == 0 else "ycck"
    raise SystemExit("unsupported component count %d" % n)


def luma(r, g, b):
    return (306 * r + 601 * g + 117 * b + 0x200) >> 10


def djpeg_gray(path, scale):
    """Y via libjpeg-turbo's djpeg, for scales Pillow's draft() cannot request."""
    pgm = subprocess.run(["djpeg", "-scale", "1/%d" % scale, "-grayscale", path],
                         check=True, capture_output=True).stdout
    m = re.match(rb"P5\s+(\d+)\s+(\d+)\s+255\s", pgm)
    w, h = int(m.group(1)), int(m.group(2))
    data = pgm[m.end():]
    assert len(data) == w * h
    return w, h, data


def main():
    path, scale, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    plain = sys.argv[4:] == ["plain"]
    data = open(path, "rb").read()
    cs = color_space(data)
    im = Image.open(path)
    w, h = im.size
    size = (w // scale, h // scale) if scale > 1 else None
    if size and min(size) == 0:
        assert cs in ("gray", "ycbcr")
        ow, oh, result = djpeg_gray(path, scale)
        with open(out, "wb") as f:
            f.write(result)
        print(ow, oh, cs)
        return
    if cs == "gray":
        im.draft("L", size)
        result = im.tobytes()
    elif cs == "ycbcr":
        im.draft("YCbCr", size)
        im.load()
        assert im.mode == "YCbCr", im.mode
        result = im.getchannel(0).tobytes()
    elif cs == "rgb":
        im.draft("RGB", size)
        im.load()
        r, g, b = (c.tobytes() for c in im.split())
        result = bytes(luma(r[i], g[i], b[i]) for i in range(len(r)))
    else:
        im.draft("CMYK", size)
        im.load()
        # Pillow inverts CMYK JPEG samples ("CMYK;I"); undo that (plain:
        # the inverted values are the C', K' wanted).
        c, m, y, k = (list(ch.tobytes()) if plain else [255 - v for v in ch.tobytes()] for ch in im.split())
        result = bytes(
            luma((c[i] * k[i] + 127) // 255, (m[i] * k[i] + 127) // 255, (y[i] * k[i] + 127) // 255)
            for i in range(len(c))
        )
    assert len(result) == im.size[0] * im.size[1]
    with open(out, "wb") as f:
        f.write(result)
    print(im.size[0], im.size[1], cs)


main()
