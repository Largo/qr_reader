"""Generates the JPEG 2000 test fixtures and manifest.json (development only).

    python -I test/fixtures/jpeg2000/generate.py

Needs Pillow (which bundles OpenJPEG) and the OpenJPEG command line tools
opj_compress / opj_decompress (on PATH, or in the directory named by the
OPJ_BIN environment variable), which can set options Pillow cannot (code-block
styles, POC, ROI, SOP/EPH, tile-parts, sub-sampling, signed and odd bit
depths). A few files are assembled by hand from encoder output: packed packet
headers (PPM/PPT), a palette JP2, reordered / missing tiles, a truncated file
and JP2 boxes with CMYK / sYCC colour.

Expected outputs (luminance as QrReader computes it: Image.luma of 8-bit RGB,
samples of other precisions scaled by v * 255 / (2**p - 1), rounded) are
derived from the source images for lossless files (exact) and from
OpenJPEG's decode for lossy ones (compared with a tolerance). The test reads
only the files and manifest.json, never this script.
"""
import hashlib
import io
import json
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OPJ_BIN = os.environ.get("OPJ_BIN", "")
EXE = ".exe" if os.name == "nt" else ""
TMP = tempfile.mkdtemp(prefix="j2k_fixtures_")
MANIFEST = []


def tool(name):
    return os.path.join(OPJ_BIN, name + EXE) if OPJ_BIN else name + EXE


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{args[0]} failed: {result.stdout}\n{result.stderr}")


def sha(data):
    return hashlib.sha256(bytes(data)).hexdigest()


def luma(r, g, b):
    return (306 * r + 601 * g + 117 * b + 512) >> 10


def scale(v, prec):
    maxv = (1 << prec) - 1
    return v if prec == 8 else (v * 255 + (maxv >> 1)) // maxv


def cmyk_luma(c, m, y, k):
    kk = 255 - k
    return luma(((255 - c) * kk + 127) // 255, ((255 - m) * kk + 127) // 255, ((255 - y) * kk + 127) // 255)


# --- source images ----------------------------------------------------------

def plane(w, h, seed, maxv=255):
    """A deterministic test plane: gradient, QR-like modules, a disc, noise."""
    rnd = random.Random(seed)
    modules = [[rnd.random() < 0.5 for _ in range(w // 3 + 2)] for _ in range(h // 3 + 2)]
    out = []
    for y in range(h):
        for x in range(w):
            v = (x * 160 // max(w - 1, 1) + y * 60 // max(h - 1, 1)) * maxv // 255
            if 4 <= x < w // 2 and 3 <= y < h - 3 and modules[y // 3][x // 3]:
                v = maxv // 10
            if (x - 3 * w // 4) ** 2 + (y - h // 2) ** 2 < (h // 4) ** 2:
                v = maxv - v // 3
            v += rnd.randint(-maxv // 40, maxv // 40)
            out.append(min(max(v, 0), maxv))
    return out


def gray_image(w, h, seed=1):
    return Image.frombytes("L", (w, h), bytes(plane(w, h, seed)))


def rgb_image(w, h, seed=1):
    planes = [plane(w, h, seed + i) for i in range(3)]
    return Image.frombytes("RGB", (w, h), bytes(v for px in zip(*planes) for v in px))


def image_luma(im):
    if im.mode == "L":
        return im.tobytes()
    if im.mode in ("LA",):
        return im.tobytes()[0::2]
    if im.mode == "RGBA":
        data = im.tobytes()
        return bytes(luma(data[i], data[i + 1], data[i + 2]) for i in range(0, len(data), 4))
    data = im.convert("RGB").tobytes()
    return bytes(luma(data[i], data[i + 1], data[i + 2]) for i in range(0, len(data), 3))


def save_pnm(im, name):
    path = os.path.join(TMP, name + (".pgm" if im.mode == "L" else ".ppm"))
    im.save(path)
    return path


def write_pgx(path, values, w, h, prec, signed):
    with open(path, "wb") as f:
        f.write(f"PG ML {'-' if signed else '+'} {prec} {w} {h}\n".encode())
        size = 1 if prec <= 8 else 2
        for v in values:
            f.write(v.to_bytes(size, "big", signed=signed))


# --- helpers ----------------------------------------------------------------

WRITTEN = {}


def add(name, data, width, height, luma_bytes=None, tolerance=0, reference=None, **extra):
    """Writes fixture +name+ (unless the same bytes are already a fixture)
    and its manifest entry."""
    file = WRITTEN.get(data)
    if file is None:
        file = WRITTEN[data] = name
        with open(os.path.join(HERE, name), "wb") as f:
            f.write(data)
    entry = {"name": os.path.splitext(name)[0], "file": file, "width": width, "height": height,
             "tolerance": tolerance}
    if luma_bytes is not None:
        assert len(luma_bytes) == width * height, name
        entry["luma"] = sha(luma_bytes)
    if reference is not None:
        ref_name = os.path.splitext(name)[0] + ".ref.pgm"
        Image.frombytes("L", (width, height), bytes(reference)).save(os.path.join(HERE, ref_name))
        entry["reference"] = ref_name
    entry.update(extra)
    MANIFEST.append(entry)


def pillow_luma(data, reduce=0):
    """OpenJPEG's decode (Pillow; opj_decompress for reduced resolutions)."""
    if reduce:
        im = opj_decode(data, reduce)
        return im, image_luma(im)
    im = Image.open(io.BytesIO(data))
    im.load()
    return im, image_luma(im)


def opj_decode(data, reduce):
    """opj_decompress -r +reduce+ of a gray or RGB image."""
    ext = ".j2k" if data[:2] == bytes([0xFF, 0x4F]) else ".jp2"
    src = os.path.join(TMP, "red" + ext)
    with open(src, "wb") as f:
        f.write(data)
    mode = Image.open(io.BytesIO(data)).mode
    out = os.path.join(TMP, "red" + (".pgm" if mode in ("L", "I;16") else ".ppm"))
    run(tool("opj_decompress"), "-i", src, "-o", out, "-r", reduce)
    with Image.open(out) as im:
        im.load()
        im = im.copy()
    return im


def opj_encode(src, name, *options, ext=".j2k"):
    out = os.path.join(TMP, name + ext)
    run(tool("opj_compress"), "-i", src, "-o", out, *options)
    with open(out, "rb") as f:
        return f.read()


def boxes(data):
    """Top-level JP2 boxes as [(type, payload)]."""
    pos = 0
    out = []
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if length == 0:
            length = len(data) - pos
        out.append((kind, data[pos + 8:pos + length]))
        pos += length
    return out


def box(kind, payload):
    return struct.pack(">I4s", 8 + len(payload), kind) + payload


def jp2_wrap(codestream, width, height, ncomp, bpc, colr, extra=b""):
    ihdr = struct.pack(">IIHBBBB", height, width, ncomp, bpc, 7, 0, 0)
    jp2h = box(b"ihdr", ihdr) + box(b"colr", colr) + extra
    return (box(b"jP  ", b"\r\n\x87\n") + box(b"ftyp", b"jp2 \x00\x00\x00\x00jp2 ") +
            box(b"jp2h", jp2h) + box(b"jp2c", codestream))


def enum_colr(cs):
    return struct.pack(">BBBI", 1, 0, 0, cs)


def segments(cs):
    """Main header end and the tile-parts [(start, end, tile index)] of a codestream."""
    pos = 2
    while True:
        marker, length = struct.unpack(">HH", cs[pos:pos + 4])
        if marker == 0xFF90:
            break
        pos += 2 + length
    main_end = pos
    parts = []
    while pos + 12 <= len(cs) and cs[pos:pos + 2] == b"\xff\x90":
        _, _, isot, psot = struct.unpack(">HHHI", cs[pos:pos + 10])
        end = len(cs) - 2 if psot == 0 else pos + psot
        parts.append((pos, end, isot))
        pos = end
    return main_end, parts


# --- fixtures ---------------------------------------------------------------

def pillow_fixtures():
    im = gray_image(129, 67)
    buf = io.BytesIO()
    im.save(buf, "JPEG2000", num_resolutions=5)
    add("gray_53.jp2", buf.getvalue(), 129, 67, image_luma(im))

    rgb = rgb_image(129, 67)
    buf = io.BytesIO()
    rgb.save(buf, "JPEG2000", num_resolutions=5, mct=1)
    add("rgb_53_rct.jp2", buf.getvalue(), 129, 67, image_luma(rgb),
        components=[sha(rgb.getchannel(i).tobytes()) for i in range(3)], color="rgb")
    _, ref = pillow_luma(buf.getvalue(), 1)
    # Lossless 5/3 at reduced resolution is integer arithmetic: exact.
    add("rgb_53_rct_r1.jp2", buf.getvalue(), 65, 34, ref, reduce=1)

    buf = io.BytesIO()
    rgb.save(buf, "JPEG2000", irreversible=True, mct=1, quality_mode="rates", quality_layers=[12])
    _, ref = pillow_luma(buf.getvalue())
    add("rgb_97_ict.jp2", buf.getvalue(), 129, 67, tolerance=2, reference=ref)
    _, ref = pillow_luma(buf.getvalue(), 2)
    add("rgb_97_ict_r2.jp2", buf.getvalue(), 33, 17, tolerance=2, reference=ref, reduce=2)

    im = gray_image(97, 75, 5)
    buf = io.BytesIO()
    im.save(buf, "JPEG2000", irreversible=True, quality_mode="rates", quality_layers=[60, 20, 6])
    _, ref = pillow_luma(buf.getvalue())
    add("gray_97_layers.jp2", buf.getvalue(), 97, 75, tolerance=2, reference=ref)

    im = gray_image(64, 48, 7)
    buf = io.BytesIO()
    im.save(buf, "JPEG2000", no_jp2=True)
    add("gray_raw.j2k", buf.getvalue(), 64, 48, image_luma(im))

    values = plane(64, 48, 9, 65535)
    im16 = Image.frombytes("I;16", (64, 48), b"".join(v.to_bytes(2, "little") for v in values))
    buf = io.BytesIO()
    im16.save(buf, "JPEG2000")
    add("gray16.jp2", buf.getvalue(), 64, 48, bytes(scale(v, 16) for v in values))

    rgba = rgb_image(64, 48, 11)
    rgba.putalpha(Image.frombytes("L", (64, 48), bytes(plane(64, 48, 12))))
    buf = io.BytesIO()
    rgba.save(buf, "JPEG2000")
    add("rgba.jp2", buf.getvalue(), 64, 48, image_luma(rgba))

    la = Image.merge("LA", [gray_image(64, 48, 13), gray_image(64, 48, 14)])
    buf = io.BytesIO()
    la.save(buf, "JPEG2000")
    add("gray_alpha.jp2", buf.getvalue(), 64, 48, image_luma(la))

    rgb = rgb_image(100, 70, 15)
    buf = io.BytesIO()
    rgb.save(buf, "JPEG2000", offset=(7, 5), tile_offset=(3, 2), tile_size=(32, 32), mct=1,
             num_resolutions=4)
    add("rgb_tiles_offset.jp2", buf.getvalue(), 100, 70, image_luma(rgb))


def opj_fixtures():
    rgb = rgb_image(67, 53, 21)
    src = save_pnm(rgb, "prog")
    for order in ("LRCP", "RLCP", "RPCL", "PCRL", "CPRL"):
        data = opj_encode(src, "prog_" + order, "-p", order, "-c", "[16,16],[8,8]", "-b", "8,8", "-n", "4",
                          "-r", "6,1")
        add(f"prog_{order.lower()}.j2k", data, 67, 53, image_luma(rgb))
    # Reduced decodes of a precinct/RPCL file: OpenJPEG's integer synthesis
    # at lower resolution, compared per component (luminance computed here).
    data = opj_encode(src, "prog_rpcl_r", "-p", "RPCL", "-c", "[16,16],[8,8]", "-b", "8,8", "-n", "4")
    for reduce in (1, 2):
        im, ref = pillow_luma(data, reduce)
        add(f"prog_rpcl_r{reduce}.j2k", data, im.size[0], im.size[1], ref, reduce=reduce)

    gray = gray_image(61, 45, 23)
    src = save_pnm(gray, "tiles_odd")
    data = opj_encode(src, "tiles_odd", "-t", "16,12", "-T", "3,1", "-d", "5,3", "-n", "3")
    add("tiles_odd_offset.j2k", data, 61, 45, image_luma(gray))

    gray = gray_image(64, 48, 25)
    src = save_pnm(gray, "cblk")
    add("cblk_4x4.j2k", opj_encode(src, "cblk4", "-b", "4,4", "-n", "3"), 64, 48, image_luma(gray))
    add("cblk_16x64.j2k", opj_encode(src, "cblk16", "-b", "16,64", "-n", "2"), 64, 48, image_luma(gray))
    add("res1.j2k", opj_encode(src, "res1", "-n", "1"), 64, 48, image_luma(gray))
    add("sop_eph.j2k", opj_encode(src, "sop", "-SOP", "-EPH", "-r", "8,1"), 64, 48, image_luma(gray))
    add("tileparts.j2k", opj_encode(src, "tp", "-t", "32,32", "-TP", "R", "-n", "3"), 64, 48, image_luma(gray))
    add("roi.j2k", opj_encode(src, "roi", "-ROI", "c=0,U=4"), 64, 48, image_luma(gray))
    add("poc.j2k", opj_encode(src, "poc", "-n", "4", "-r", "4,1", "-POC", "T0=0,0,1,3,1,RLCP/T0=0,0,2,4,1,LRCP"),
        64, 48, image_luma(gray))
    for mode in (1, 2, 4, 8, 16, 32, 63):
        add(f"mode{mode}.j2k", opj_encode(src, f"mode{mode}", "-M", mode, "-r", "5,1", "-b", "16,16"), 64, 48,
            image_luma(gray))

    big = gray_image(129, 67, 27)
    add("res7.j2k", opj_encode(save_pnm(big, "res7"), "res7", "-n", "7"), 129, 67, image_luma(big))

    rgb = rgb_image(80, 60, 29)
    data = opj_encode(save_pnm(rgb, "m63"), "m63", "-I", "-M", "63", "-r", "10", "-b", "32,32")
    _, ref = pillow_luma(data)
    add("mode63_97.j2k", data, 80, 60, tolerance=2, reference=ref)

    rgb = rgb_image(160, 120, 31)
    data = opj_encode(save_pnm(rgb, "lossy"), "lossy", "-I", "-r", "20", "-n", "5")
    _, ref = pillow_luma(data)
    add("rgb_97_160.j2k", data, 160, 120, tolerance=2, reference=ref)

    # Signed and odd precisions (PGX input).
    values = [v - 128 for v in plane(64, 48, 33)]
    # (opj_compress reads PGX below 8 bits as 8-bit: raw input instead.)
    path = os.path.join(TMP, "signed.raw")
    with open(path, "wb") as f:
        f.write(bytes(v & 0xFF for v in values))
    add("signed8.j2k", opj_encode(path, "signed", "-F", "64,48,1,8,s"), 64, 48, bytes(v + 128 for v in values))
    values = plane(64, 48, 35, 4095)
    path = os.path.join(TMP, "p12.pgx")
    write_pgx(path, values, 64, 48, 12, False)
    add("gray12.j2k", opj_encode(path, "p12"), 64, 48, bytes(scale(v, 12) for v in values))
    values = [1 if v > 127 else 0 for v in plane(64, 48, 37)]
    path = os.path.join(TMP, "p1.raw")
    with open(path, "wb") as f:
        f.write(bytes(values))
    add("bilevel1.j2k", opj_encode(path, "p1", "-F", "64,48,1,1,u", "-n", "3"), 64, 48,
        bytes(255 * v for v in values))


def subsampled_fixtures():
    w, h = 64, 48
    y = plane(w, h, 41)
    cb = plane(w // 2, h // 2, 42)
    cr = plane(w // 2, h // 2, 43)
    path = os.path.join(TMP, "ycc.raw")
    with open(path, "wb") as f:
        f.write(bytes(y + cb + cr))
    for name, offset in (("ycc420.jp2", None), ("ycc420_offset.jp2", "1,1")):
        options = ["-F", f"{w},{h},3,8,u@1x1:2x2:2x2", "-mct", "0", "-n", "3", "-c", "[16,16]"]
        if offset:
            options += ["-d", offset]
        data = opj_encode(path, name, *options, ext=".jp2")
        chroma = []
        for p in (cb, cr):
            # Pixel x of the image grid shows chroma sample floor(x / 2) -
            # ceil(x0 / 2) (clamped), x being absolute on the grid.
            x0 = 1 if offset else 0
            up = []
            for yy in range(h):
                cy = min(max((yy + x0) // 2 - (x0 + 1) // 2, 0), h // 2 - 1)
                for xx in range(w):
                    cx = min(max((xx + x0) // 2 - (x0 + 1) // 2, 0), w // 2 - 1)
                    up.append(p[cy * (w // 2) + cx])
            chroma.append(sha(bytes(up)))
        add(name, data, w, h, bytes(y), components=[sha(bytes(y))] + chroma, color="ycc")
        if not offset:
            # Component 0 is coded independently (no MCT): a Y-only file with
            # the same options decodes to the same reduced plane.
            y_im = Image.frombytes("L", (w, h), bytes(y))
            y_cs = opj_encode(save_pnm(y_im, "yonly"), "yonly", "-n", "3", "-c", "[16,16]")
            ref = opj_decode(y_cs, 1)
            add("ycc420_r1.jp2", data, ref.size[0], ref.size[1], ref.tobytes(), reduce=1)

    # CMYK: four planes, colr patched to enumerated CMYK (12).
    planes = [plane(w, h, 50 + i) for i in range(4)]
    path = os.path.join(TMP, "cmyk.raw")
    with open(path, "wb") as f:
        f.write(bytes(sum(planes, [])))
    cs = opj_encode(path, "cmyk", "-F", f"{w},{h},4,8,u", "-mct", "0")
    expected = bytes(cmyk_luma(*px) for px in zip(*planes))
    add("cmyk.jp2", jp2_wrap(cs, w, h, 4, 7, enum_colr(12)), w, h, expected, color="cmyk")


def palette_fixture():
    w, h = 64, 48
    colours = [(255, 255, 255), (0, 0, 0), (200, 30, 40), (20, 160, 60), (30, 60, 200), (250, 220, 10)]
    rnd = random.Random(61)
    index = [rnd.randrange(len(colours)) if (x // 4 + y // 4) % 3 else 0 for y in range(h) for x in range(w)]
    im = Image.frombytes("L", (w, h), bytes(index))
    buf = io.BytesIO()
    im.save(buf, "JPEG2000", no_jp2=True)
    pclr = struct.pack(">HB", len(colours), 3) + bytes([7, 7, 7]) + b"".join(bytes(c) for c in colours)
    cmap = b"".join(struct.pack(">HBB", 0, 1, col) for col in range(3))
    data = jp2_wrap(buf.getvalue(), w, h, 1, 7, enum_colr(16), box(b"pclr", pclr) + box(b"cmap", cmap))
    expected = bytes(luma(*colours[i]) for i in index)
    _, ref = pillow_luma(data)
    assert ref == expected, "Pillow disagrees with the palette fixture"
    planes = [bytes(colours[i][c] for i in index) for c in range(3)]
    add("palette.jp2", data, w, h, expected, components=[sha(p) for p in planes], color="rgb",
        palette_applied=True)


def assembled_fixtures():
    gray = gray_image(64, 64, 71)
    src = save_pnm(gray, "tiled")
    cs = opj_encode(src, "tiled", "-t", "64,16", "-n", "3")
    expected = image_luma(gray)
    main_end, parts = segments(cs)

    # Tiles in reverse order.
    body = b"".join(cs[a:b] for a, b, _ in reversed(parts))
    add("tiles_reversed.j2k", cs[:main_end] + body + b"\xff\xd9", 64, 64, expected)

    # Tile 1 missing: its rows stay mid-gray.
    body = b"".join(cs[a:b] for a, b, t in parts if t != 1)
    missing = bytearray(expected)
    missing[16 * 64:32 * 64] = bytes([128]) * (16 * 64)
    add("tile_missing.j2k", cs[:main_end] + body + b"\xff\xd9", 64, 64, bytes(missing))

    # Truncated in the middle of tile 2: tiles 0 and 1 decode exactly.
    a, b, _ = parts[2]
    cut = a + (b - a) // 2
    add("truncated.j2k", cs[:cut], 64, 64, top_rows=32, top_luma=sha(expected[:32 * 64]))

    # Junk after EOC.
    add("trailing_junk.j2k", cs + b"\x00junk\xff\xd9" * 3, 64, 64, expected)

    # Packed packet headers: split SOP/EPH packets into header and body.
    gray = gray_image(48, 40, 73)
    cs = opj_encode(save_pnm(gray, "pp"), "pp", "-SOP", "-EPH", "-r", "6,1", "-n", "3", "-t", "48,40")
    main_end, parts = segments(cs)
    (start, end, _), = parts
    sod = cs.index(b"\xff\x93", start) + 2
    data = cs[sod:end]
    headers = b""
    bodies = b""
    for packet in data.split(b"\xff\x91")[1:]:
        packet = b"\xff\x91" + packet
        eph = packet.index(b"\xff\x92") + 2
        headers += packet[6:eph]
        bodies += packet[:6] + packet[eph:]
    expected = image_luma(gray)
    # PPT: in the tile-part header (split over two markers to test Zppt).
    half = len(headers) // 2
    ppt = (struct.pack(">HHB", 0xFF61, 3 + half, 0) + headers[:half] +
           struct.pack(">HHB", 0xFF61, 3 + len(headers) - half, 1) + headers[half:])
    tile_header = cs[start + 12:sod - 2]
    tile = ppt + tile_header + b"\xff\x93" + bodies
    sot = struct.pack(">HHHIBB", 0xFF90, 10, 0, 12 + len(tile), 0, 1)
    ppt_cs = cs[:main_end] + sot + tile + b"\xff\xd9"
    _, ref = pillow_luma(ppt_cs)
    assert ref == expected, "OpenJPEG disagrees with the PPT fixture"
    add("ppt.j2k", ppt_cs, 48, 40, expected)
    # PPM: Nppm + headers of the one tile-part, in the main header.
    ppm_data = struct.pack(">I", len(headers)) + headers
    ppm = struct.pack(">HHB", 0xFF60, 3 + len(ppm_data), 0) + ppm_data
    tile = tile_header + b"\xff\x93" + bodies
    sot = struct.pack(">HHHIBB", 0xFF90, 10, 0, 12 + len(tile), 0, 1)
    ppm_cs = cs[:main_end] + ppm + sot + tile + b"\xff\xd9"
    _, ref = pillow_luma(ppm_cs)
    assert ref == expected, "OpenJPEG disagrees with the PPM fixture"
    add("ppm.j2k", ppm_cs, 48, 40, expected)


def main():
    for name in os.listdir(HERE):
        if name.endswith((".jp2", ".j2k", ".ref.pgm")):
            os.remove(os.path.join(HERE, name))
    try:
        pillow_fixtures()
        opj_fixtures()
        subsampled_fixtures()
        palette_fixture()
        assembled_fixtures()
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    with open(os.path.join(HERE, "manifest.json"), "w") as f:
        json.dump(MANIFEST, f, indent=1)
        f.write("\n")
    total = sum(os.path.getsize(os.path.join(HERE, n)) for n in os.listdir(HERE))
    print(f"{len(MANIFEST)} fixtures, {total} bytes")


if __name__ == "__main__":
    sys.exit(main())
