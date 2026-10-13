"""Writes the "QR blocks" test fonts: a barcode font whose glyphs p0..p15 are
2x2 module patterns (bit 0 top left, 1 top right, 2 bottom left, 3 bottom
right; a module is 500 units, the advance 1000), mapped to the characters
A..P. Formats: TrueType (qrblocks.ttf), OpenType/CFF (qrblocks.otf), bare
CFF (qrblocks.cff, as /FontFile3 /Type1C) and Type 1 (qrblocks.pfa).
A glyph "o" (a ring with curves) is included as ordinary text.

Development tool only:  python -I generate.py   (needs fontTools)
"""
import os

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.ttGlyphPen import TTGlyphPen

DIR = os.path.dirname(os.path.abspath(__file__))
MODULE = 500
NAMES = [".notdef"] + ["p%d" % n for n in range(16)] + ["o"]
CMAP = {0x41 + n: "p%d" % n for n in range(16)}
CMAP[ord("o")] = "o"


def squares(n):
    """(x0, y0) of the dark modules of pattern n (y up, baseline 0)."""
    out = []
    for bit, (col, row) in enumerate([(0, 1), (1, 1), (0, 0), (1, 0)]):
        if n >> bit & 1:
            out.append((col * MODULE, row * MODULE))
    return out


def draw(pen, name):
    if name.startswith("p"):
        for x, y in squares(int(name[1:])):
            pen.moveTo((x, y))
            pen.lineTo((x, y + MODULE))
            pen.lineTo((x + MODULE, y + MODULE))
            pen.lineTo((x + MODULE, y))
            pen.closePath()
    elif name == "o":  # a ring: outer circle counter-clockwise, inner clockwise
        circle(pen, 500, 450, 400, True)
        circle(pen, 500, 450, 250, False)


def circle(pen, cx, cy, r, ccw):
    k = 0.5523 * r
    east, north, west, south = (cx + r, cy), (cx, cy + r), (cx - r, cy), (cx, cy - r)
    arcs = [  # counter-clockwise quarter arcs: (control 1, control 2, end)
        ((cx + r, cy + k), (cx + k, cy + r), north),
        ((cx - k, cy + r), (cx - r, cy + k), west),
        ((cx - r, cy - k), (cx - k, cy - r), south),
        ((cx + k, cy - r), (cx + r, cy - k), east),
    ]
    pen.moveTo(east)
    if ccw:
        for c1, c2, end in arcs:
            pen.curveTo(c1, c2, end)
    else:
        starts = [east, north, west, south]
        for (c1, c2, _end), start in reversed(list(zip(arcs, starts))):
            pen.curveTo(c2, c1, start)
    pen.closePath()


def truetype():
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(NAMES)
    fb.setupCharacterMap(CMAP)
    glyphs = {}
    for name in NAMES:
        pen = TTGlyphPen(None)
        if name != ".notdef":
            draw(Cu2QuPen(pen, 1.0, reverse_direction=False), name)
        glyphs[name] = pen.glyph()
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics({n: (1000, 0) for n in NAMES})
    fb.setupHorizontalHeader(ascent=1000, descent=0)
    fb.setupNameTable({"familyName": "QRBlocks", "styleName": "Regular"})
    fb.setupOS2()
    fb.setupPost()
    fb.save(os.path.join(DIR, "qrblocks.ttf"))


def opentype():
    fb = FontBuilder(1000, isTTF=False)
    fb.setupGlyphOrder(NAMES)
    fb.setupCharacterMap(CMAP)
    charstrings = {}
    for name in NAMES:
        pen = T2CharStringPen(1000, None)
        if name != ".notdef":
            draw(pen, name)
        charstrings[name] = pen.getCharString()
    fb.setupCFF("QRBlocks", {"FullName": "QRBlocks"}, charstrings, {})
    fb.setupHorizontalMetrics({n: (1000, 0) for n in NAMES})
    fb.setupHorizontalHeader(ascent=1000, descent=0)
    fb.setupNameTable({"familyName": "QRBlocks", "styleName": "Regular"})
    fb.setupOS2()
    fb.setupPost()
    fb.save(os.path.join(DIR, "qrblocks.otf"))
    with open(os.path.join(DIR, "qrblocks.cff"), "wb") as f:
        f.write(fb.font.getTableData("CFF "))


# --- Type 1 ------------------------------------------------------------------

def t1_number(v):
    v = int(v)
    if -107 <= v <= 107:
        return bytes([v + 139])
    if 108 <= v <= 1131:
        v -= 108
        return bytes([(v >> 8) + 247, v & 0xFF])
    if -1131 <= v <= -108:
        v = -v - 108
        return bytes([(v >> 8) + 251, v & 0xFF])
    return bytes([255]) + v.to_bytes(4, "big", signed=True)


def t1_charstring(name):
    out = t1_number(0) + t1_number(1000) + bytes([13])  # hsbw
    x = y = 0
    if name.startswith("p"):
        for sx, sy in squares(int(name[1:])):
            out += t1_number(sx - x) + t1_number(sy - y) + bytes([21])  # rmoveto
            out += t1_number(MODULE) + bytes([7])  # vlineto
            out += t1_number(MODULE) + bytes([6])  # hlineto
            out += t1_number(-MODULE) + bytes([7])  # vlineto
            out += bytes([9])  # closepath
            x, y = sx + MODULE, sy  # Type 1 closepath keeps the current point
    return out + bytes([14])  # endchar


def encrypt(data, r):
    out = bytearray()
    for b in data:
        c = b ^ (r >> 8)
        out.append(c)
        r = ((c + r) * 52845 + 22719) & 0xFFFF
    return bytes(out)


def type1():
    names = [n for n in NAMES if n != "o"]
    clear = (
        "%!PS-AdobeFont-1.0: QRBlocks 001.000\n"
        "11 dict begin\n/FontName /QRBlocks def\n/PaintType 0 def\n/FontType 1 def\n"
        "/FontMatrix [0.001 0 0 0.001 0 0] readonly def\n/FontBBox {0 0 1000 1000} readonly def\n"
        "/Encoding 256 array\n0 1 255 {1 index exch /.notdef put} for\n"
        + "".join("dup %d /p%d put\n" % (0x41 + n, n) for n in range(16))
        + "readonly def\ncurrentdict end\ncurrentfile eexec\n"
    ).encode("latin-1")
    private = b"dup /Private 8 dict dup begin\n/RD {string currentfile exch readstring pop} executeonly def\n"
    private += b"/ND {noaccess def} executeonly def\n/NP {noaccess put} executeonly def\n/lenIV 4 def\n"
    private += b"/Subrs 1 array\ndup 0 4 RD " + encrypt(b"\0\0\0\0" + bytes([11]), 4330) + b" NP\nND\n"
    private += b"2 index /CharStrings %d dict dup begin\n" % len(names)
    for name in names:
        cs = encrypt(b"\0\0\0\0" + t1_charstring(name), 4330)
        private += b"/%s %d RD " % (name.encode(), len(cs)) + cs + b" ND\n"
    private += b"end\nend\nreadonly put\nnoaccess put\ndup /FontName get exch definefont pop\nmark currentfile closefile\n"
    encrypted = encrypt(b"\0\0\0\0" + private, 55665).hex()
    lines = "\n".join(encrypted[i:i + 64] for i in range(0, len(encrypted), 64))
    trailer = ("\n" + ("0" * 64 + "\n") * 8 + "cleartomark\n").encode()
    with open(os.path.join(DIR, "qrblocks.pfa"), "wb") as f:
        f.write(clear + lines.encode() + trailer)
    print("qrblocks.pfa: clear-text part", len(clear), "bytes")


truetype()
opentype()
type1()
print("written to", DIR)
