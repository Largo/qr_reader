# qr_reader — design and component contracts

Pure-Ruby QR code reader gem. **Goals, in order:** correct, accurate on real photos,
fast. "Pure Ruby" means: no native extensions of our own and no external tools
at runtime; Ruby stdlib (including `zlib`) is fine. Supported Ruby: >= 3.2
(development machine runs Ruby 4.0.6; YJIT is available via `--yjit` /
`RUBY_YJIT_ENABLE=1`).

Accuracy benchmark: the ZXing blackbox QR corpus in `test/corpus/zxing/qrcode-{1..6}`
(179 images, each with an expected `.txt`, UTF-8). Each image is also tested
rotated by 90/180/270 degrees (716 cases).

| decoder | cases passed (0°) | all 4 rotations |
|---|---|---|
| ZXing Java (required in their own tests) | 157 / 179 | ~619 / 716 |
| zxing-cpp 2.x (Python wheel) | 166 / 179 | ~664 / 716 |

Our target is at least ZXing Java and as close to zxing-cpp as we can get, while
staying fast.

Reference tools (development only, never runtime deps):

* zxing-cpp + Pillow venv:
  `/tmp/claude-1000/-home-andi-workspace/024a2597-ef40-4f4c-a25b-3210b1b14972/scratchpad/venv/bin/python`
  (run Python with `-I`). `bench/reference/zxcpp.py [--rotate DEG] IMAGE...`
  prints zxing-cpp's text, corner positions, EC level and orientation as JSON lines.
  Pillow can also decode JPEG luminance exactly as libjpeg does
  (`im.draft('YCbCr', size)`, then the Y band).
* ImageMagick 7 (`magick`) for generating test images (JPEG variants, BMP, GIF, PNM...).
* `rqrcode_core` gem (dev dependency) is an independent QR *encoder*:
  `QrTestHelper.rqr_matrix(text, level: :m, size: nil, mode: nil)` returns a `BitMatrix`.

Run tests with `bundle exec ruby -Itest test/path/test_x.rb` or `bundle exec rake test`.

## Directory layout and ownership

Files are owned by exactly one component so that components can be built in
parallel. Do not edit files you don't own; if you need a change in a shared
file, describe it in your final report instead.

| owner | files |
|---|---|
| core (integrator) | `lib/qr_reader.rb`, `lib/qr_reader/{version,errors,image,bit_matrix,result,symbol_version,format_information}.rb`, `lib/qr_reader/reader.rb`, `test/test_helper.rb`, `test/test_core_types.rb`, `DESIGN.md`, `Rakefile`, gemspec |
| formats | `lib/qr_reader/formats.rb`, `lib/qr_reader/formats/{png,gif,bmp,pnm}.rb`, `test/formats/test_{png,gif,bmp,pnm,formats}.rb`, `test/fixtures/images/**` |
| jpeg | `lib/qr_reader/formats/jpeg.rb`, `test/formats/test_jpeg.rb`, `test/fixtures/jpeg/**`, `bench/jpeg_bench.rb` |
| decoder | `lib/qr_reader/decoder.rb`, `lib/qr_reader/decoder/**`, `test/decoder/**` |
| detector | `lib/qr_reader/detector.rb`, `lib/qr_reader/detector/**`, `lib/qr_reader/binarizer.rb`, `test/detector/**` |
| testkit | `test/support/**` (except `test_helper.rb`), `test/test_encoder.rb`, `bench/**` (except `bench/jpeg_bench.rb`, `bench/reference/zxcpp.py` may be extended) |

Each component has one entry file (`formats.rb`, `decoder.rb`, `detector.rb`)
already required from `lib/qr_reader.rb`; the entry file `require_relative`s its
own sub-files. Stubs exist for all entry files — replace them.

## Core types (already implemented — use, don't modify)

* `QrReader::Image` — 8-bit grayscale. `width`, `height`, `data` (binary String,
  `width*height` bytes, row-major, 0 = black … 255 = white), `[](x, y)`, `row(y)`,
  `invert`, `rotate(deg)`, `rotate90/180/270`, `mirror`, `crop`, `downscale(factor)`.
  Constructors: `Image.new(w, h, gray_bytes)`, `Image.from_pixels(w, h, bytes, format)`
  with format `:gray, :gray_alpha, :rgb, :rgba, :bgr, :bgra, :argb, :abgr`
  (alpha composited over white), `Image.luma(r, g, b)` (Rec.601, 10-bit fixed point —
  use the same weights everywhere).
* `QrReader::BitMatrix` — `width`, `height`, `bits` (binary String, one byte per
  cell, `"\x01"` dark / `"\x00"` light), `get(x,y)` → 0/1, `dark?(x,y)`, `set`,
  `unset`, `flip`, `row(y)`, `transpose`, `invert`, `dup`, `to_s`,
  `BitMatrix.from_rows`. Runs of equal cells can be found at C speed with
  `bits.index("\x01", pos)` / `bits.index("\x00", pos)` — use that in scanners.
* `QrReader::SymbolVersion` — `SymbolVersion[n]` (1..40), `.for_dimension(d)`,
  `#dimension`, `#alignment_centers` (e.g. `[6, 22, 38]`), `#ec_blocks(:L|:M|:Q|:H)`
  → `EcBlocks(ec_codewords_per_block, groups=[[count, data_codewords], ...])`,
  `#total_codewords`, `#version_info_bits`, `.decode_version_info(bits18)` (nearest
  within Hamming distance 3, else nil). Tables are verified against rqrcode_core.
* `QrReader::FormatInformation` — `.decode(bits1, bits2 = bits1)` → instance with
  `ec_level` (:L/:M/:Q/:H) and `mask` (0..7), nearest within distance 3, else nil.
  `.encode(data5)` → masked 15-bit word.
* `QrReader::Result` (Data) — `text, bytes, version, ec_level, mask, points, mirrored,
  errors_corrected, eci, fnc1, structured_append, symbology_identifier, segments`;
  `QrReader::Segment(mode, text, eci)`, `QrReader::StructuredAppend(index, count, parity)`.
* Errors: `QrReader::Error`, `ImageError` (corrupt/unknown image), `UnsupportedImageError`
  (recognised but unsupported, e.g. WebP), `NotFoundError`.

## Public API (core; implemented during integration)

```ruby
QrReader.decode(input, **opts)      # => String or nil (first code)
QrReader.decode!(input, **opts)     # => String, raises NotFoundError
QrReader.read(input, **opts)        # => Result or nil
QrReader.decode_all(input, **opts)  # => Array<Result>
```

`input`: file path (String/Pathname), IO, binary String of an encoded image
(detected by magic bytes), `QrReader::Image`, or any object responding to
`width`, `height` and `pixels` (ChunkyPNG-style RGBA integers).
Options: `try_harder:` (default true: spend more time only when the fast path
finds nothing), `inverted:` (`:auto`/true/false, light-on-dark codes).

## Component contracts

### formats

```ruby
QrReader::Formats.decode(bytes, scale: 1)   # => Image; sniffs magic bytes
QrReader::Formats.format_of(bytes)          # => :png, :jpeg, :gif, :bmp, :pnm or nil
QrReader::Formats::PNG.decode(bytes)        # => Image
QrReader::Formats::GIF.decode(bytes)        # first frame, transparency over white
QrReader::Formats::BMP.decode(bytes)
QrReader::Formats::PNM.decode(bytes)        # P1..P7
QrReader::Formats::JPEG.decode(bytes, scale: 1)  # owned by jpeg (see below)
QrReader::Formats::JPEG.dimensions(bytes)   # => [w, h] from the header only
```

`scale` is only honoured by JPEG (others ignore it). Unknown data raises
`ImageError`; recognised but unsupported formats (WebP, TIFF, HEIC/AVIF) raise
`UnsupportedImageError` with a helpful message. Corrupt or truncated input must
raise `ImageError` (never hang, never raise NoMethodError/TypeError etc.).

PNG must support all colour types, bit depths 1/2/4/8/16, palettes with tRNS,
alpha (composited over white), Adam7 interlacing. BMP: 1/4/8/16/24/32 bpp,
BI_RGB/BI_BITFIELDS/RLE4/RLE8, bottom-up and top-down, core/info/V4/V5 headers.
GIF: LZW, global/local palettes, transparency, interlace. PNM: P1–P6 incl.
16-bit maxval, comments; P7 PAM.

### jpeg

Luminance-only JPEG decoder. Baseline (SOF0), extended Huffman 8-bit (SOF1) and
progressive (SOF2); any sampling factors; restart intervals; 1, 3 and 4 components
(Adobe APP14 transform: YCbCr / RGB / CMYK / YCCK). Arithmetic coding, lossless
and 12-bit may raise `UnsupportedImageError`.

Key ideas for speed: only the Y component needs an IDCT for YCbCr images (Y *is*
the luminance); chroma blocks of interleaved scans must still be entropy-decoded
but can be discarded; progressive scans that only contain chroma can be skipped by
jumping to the next marker. `scale:` 2, 4, 8 decodes at reduced size with reduced
IDCTs (4x4, 2x2, DC only) — output size `ceil(w/scale) x ceil(h/scale)`, like
libjpeg. Truncated data: decode what is there, fill the rest with mid-gray.
EXIF orientation is ignored (QR decoding is rotation-invariant).

### decoder

```ruby
QrReader::Decoder.decode(bit_matrix, try_mirrored: true)
# => QrReader::Result (points: nil) or nil when undecodable
QrReader::Decoder.diagnose(bit_matrix)
# => Hash with at least :status (:ok, :format_info, :version_info, :reed_solomon,
#    :bitstream), useful for debugging the detector
```

Input is the sampled N×N module grid (N = 21..177, 1 = dark) *without* quiet zone.
Must implement ISO/IEC 18004:2015 Model 2 fully: format info (both copies),
version info (both copies; for v >= 7 fall back to the dimension-derived version
if unreadable), function pattern masking, all 8 data masks, codeword placement,
block de-interleaving, Reed-Solomon over GF(256)/0x11D with up to ⌊ec/2⌋ errors
per block (verify after correction, never return wrong data), bit stream modes:
numeric, alphanumeric, byte, kanji, ECI, structured append, FNC1 (first and second
position, with `%` → GS handling in alphanumeric), Hanzi/GB2312 (mode 1101, used
by the corpus), terminator/short padding. Mirrored symbols (transpose) are tried
when the normal read fails. Character sets: ECI designators → Ruby encodings
(ISO-8859-x, Shift_JIS, Windows-125x, UTF-8, UTF-16BE, US-ASCII, Big5, GB18030,
EUC-KR, binary); without ECI, byte segments are guessed like ZXing's
`StringUtils.guessEncoding` (UTF-8 if valid & multibyte, else Shift_JIS by
heuristics, else ISO-8859-1). `Result#text` is always valid UTF-8.
Symbology identifier: `]Q1` normal, `]Q2` with ECI, `]Q3`/`]Q4` FNC1 first,
`]Q5`/`]Q6` FNC1 second.

### detector

```ruby
QrReader::Binarizer.hybrid(image)            # => BitMatrix (local thresholds, ZXing HybridBinarizer-like)
QrReader::Binarizer.global_histogram(image)  # => BitMatrix
detector = QrReader::Detector.new(bit_matrix, image: image)  # image optional (for luminance-aware refinements)
detector.each_candidate(try_harder: false, multi: false) { |candidate| ... }  # lazy; Enumerator without block
QrReader::Detector.detect_pure(bit_matrix)   # => candidate or nil (fast path for clean, axis-aligned codes)
```

A candidate (`QrReader::Detector::Candidate`) exposes:

* `bits` — sampled N×N `BitMatrix` (1 = dark), ready for `Decoder.decode`
* `points` — `[[x, y], ...]` symbol corners in image coordinates: TL, TR, BR, BL
* `finder_patterns` — centres (debugging)
* `alternatives` — Enumerator of further `BitMatrix` samplings worth trying when
  `bits` does not decode (other dimension estimates, other alignment choices,
  piecewise vs global transform, ...), cheapest/most likely first.

Candidates should be yielded most-likely first so that the reader can stop at
the first successful decode. With `multi: true`, all plausible (non-overlapping)
symbols should be produced.

### testkit

* `test/support/qr_encoder.rb`: `QrTestEncoder` — independent full encoder
  (all versions/levels/masks, numeric/alnum/byte/kanji/hanzi segments, ECI, FNC1,
  structured append, deliberate codeword corruption) returning a BitMatrix.
* `test/support/distort.rb`: image distortions (lighting gradients, perspective,
  cylinder curvature, noise, blur, contrast, JPEG round trips through `magick`).
* `bench/corpus.rb`: ZXing corpus runner (rotations, timing, JSON output,
  comparison with a previous run and with the zxing-cpp baseline).
* `bench/synthetic.rb`: deterministic synthetic stress grid.
* `bench/speed.rb`: per-stage timings (image decode, binarize, detect, decode).

## Coding guidelines (performance matters — this is pure Ruby)

* Hot loops: `while` with integer indices and local variables; no blocks,
  `each`/`map`/`times`, `send`, or `method_missing` inside per-pixel/per-bit loops.
* Pixel/bit buffers are binary Strings (`"\0".b * n`) accessed with
  `getbyte`/`setbyte`; or Arrays of Integers where values exceed a byte.
* Prefer C-implemented bulk operations where they replace a Ruby loop:
  `String#index`, `#count`, `#tr`, `#byteslice`, `#unpack`/`#pack`, `#sum`,
  `Array#fill`, `Zlib`. (Remember `tr` treats `-`, `^` and `\\` specially —
  see `Image::TR_ESCAPE`.)
* Integer arithmetic in hot paths; avoid allocating Floats/Arrays per pixel.
  Keep Integers below 2**62 (fixnum range).
* Precompute and cache per-version tables (function pattern masks, codeword
  placement order, GF log/exp tables) in frozen constants or lazily memoized.
* Code must be fast both with and without YJIT; measure both
  (`ruby --yjit` vs plain `ruby`).
* `# frozen_string_literal: true` in every file; no global state mutation; no
  monkey patching; no `Thread`s; no warnings under `ruby -w`.
* Never let garbage input cause anything other than `QrReader::Error`
  subclasses (image loading) or a nil result (decoding/detection).
