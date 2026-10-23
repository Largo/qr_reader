# qr_reader

A fast, accurate QR code reader in pure Ruby. No native extensions, no
ImageMagick, no zbar — just Ruby (and its standard library). Reads photos and
scanned documents: PNG, JPEG, JPEG 2000, GIF, BMP, PNM, TIFF (including CCITT
G3/G4 fax compression) and PDFs (embedded images, vector-drawn codes and
barcode fonts).

```ruby
require "qr_reader"

QrReader.decode("ticket.jpg")          # => "https://example.com/t/8F2K" (or nil)
QrReader.decode_all("invoice.pdf")     # => ["SPC\n0200\n1\nCH44...", ...]

code = QrReader.read("label.png")
code.text            # => "https://example.com"
code.version         # => 3
code.ec_level        # => :m
code.points          # => [[x, y], ...] corners: top-left, top-right, bottom-right, bottom-left

QrReader.scan("scans.tiff") do |code|  # lazily, page by page
  puts "page #{code.page}: #{code.text}"
end

QrReader.decode(params[:file].tempfile)  # an upload: any IO works
QrReader.decode(StringIO.new(bytes))     # image bytes you already hold
```

## Installation

```bash
bundle add qr_reader
```

Requires Ruby 3.2 or newer and nothing else: no C compiler, no ImageMagick,
no native libraries — it also runs on Rubies without C extensions. Enable YJIT
for the best speed (`RUBY_YJIT_ENABLE=1`, `ruby --yjit`, or
`RubyVM::YJIT.enable` at boot).

It runs on every major Ruby implementation. The full test suite passes on MRI
(CRuby) 3.2, 3.3, 3.4 and 4.0, JRuby 10 and TruffleRuby 25, and ruby.wasm
(Ruby 4.0) decodes PNGs and PDFs.

For reading QR-bills (Swiss QR codes on invoices) specifically, see
[swiss_qr](https://github.com/Largo/swiss_qr), which parses and validates the
payload and uses this gem to read the images and PDFs.

### Optional: native kernels (qr_reader-native)

The hot loops (image decoding, binarization, pattern scanning) are written as
plain-Ruby "kernels" that the [Spinel](https://github.com/matz/spinel) AOT
compiler can turn into C. The separate gem `qr_reader-native` contains exactly
those kernels compiled; with it installed, qr_reader uses them automatically:

```ruby
gem "qr_reader"
gem "qr_reader-native"   # optional, needs a C compiler at install time
```

`QrReader.native?` tells whether they are in use. It mainly pays off on Rubies
running without YJIT (see "Accuracy and speed"); results are identical, and
without the gem — or with `QR_READER_NATIVE=0` — the same code runs as Ruby.

## Usage

The `decode` methods return the text of a code; the `read` methods return a
`QrReader::Result` with the text plus metadata (version, position, page, ...).

| method | returns |
|---|---|
| `QrReader.decode(input)` | text of the first code, or `nil` |
| `QrReader.decode!(input)` | text of the first code, or raises `QrReader::NotFoundError` |
| `QrReader.decode_all(input)` | texts of all codes (all pages) |
| `QrReader.read(input)` | first code as a `QrReader::Result`, or `nil` |
| `QrReader.read!(input)` | first code as a `QrReader::Result`, or raises `QrReader::NotFoundError` |
| `QrReader.read_all(input)` | all codes as `QrReader::Result`s |
| `QrReader.scan(input) { \|result\| }` | yields codes as they are found; an `Enumerator` without a block |

`input` can be a file path (`String` or `Pathname`), an `IO` with the encoded
image (a `File`, an upload's `Tempfile`, `StringIO.new(bytes)`), a
`QrReader::Image`, or any object with `width`, `height` and `pixels` (e.g. a
`ChunkyPNG::Image`). As with `File.read` or `PDF::Reader.new`, a `String` is
always a path and never image data: image bytes go in as an IO. A `String`
that looks like image data raises `ArgumentError` instead of being guessed at,
so bytes from a client can never be taken for a path on the server. Raw pixel
buffers can be wrapped with `QrReader::Image.from_pixels(width, height, bytes, :rgba)`
(also `:rgb`, `:bgr`, `:bgra`, `:gray`, ...).

Options (for every method, and `QrReader::Reader.new` for reuse):

- `try_harder: true` — when the fast strategies find nothing, keep trying
  slower ones. `false` gives up early (faster on images without a code).
- `inverted: :auto` — also look for light-on-dark codes; `true` only those,
  `false` never.

A `QrReader::Result` is an immutable `Data` object:

| attribute | |
|---|---|
| `text` | decoded content as a UTF-8 `String` (`to_s` returns it too) |
| `raw_bytes` | the payload bytes before character-set decoding (binary `String`) |
| `version`, `ec_level`, `mask` | symbol version (1–40), error correction level (`:l`, `:m`, `:q`, `:h`), mask |
| `points` | corners in image pixels: top-left, top-right, bottom-right, bottom-left |
| `page` | page/image index for multi-page TIFF and PDF input, else `nil` |
| `mirrored?`, `errors_corrected` | read mirrored? / number of repaired codewords |
| `eci`, `segments`, `structured_append`, `fnc1`, `symbology_identifier` | encoding details |

Errors: `QrReader::ImageError` (unreadable image data, corrupt PDF),
`QrReader::UnsupportedImageError` (e.g. WebP, HEIC, encrypted PDF, a PDF
whose images all fail to decode), `Errno::ENOENT` for missing files, `ArgumentError` for image bytes passed
as a `String` (use `StringIO.new(bytes)`). A PDF that draws nothing that could
be a code (a text-only page) is not an error: it just has no codes.

### Command line

```bash
qr_reader photo.jpg                 # prints the text of the first code
qr_reader --all --json scan.pdf     # every code, with metadata, as JSON lines
```

### Large images

There is no need to shrink photos or page scans before reading them: large
images are searched through a resolution pyramid (coarse levels first) and
large JPEGs are first decoded at reduced size, so a big code is found quickly
while a small code on a 300/600 DPI scan is still read at full resolution.
Shrinking beforehand can make small codes unreadable — a 12 mm code on a
300 DPI A4 scan is lost when the page is reduced to 1000 px.

What does help with big inputs:

- Run with YJIT (see above).
- Pass `try_harder: false` when most images contain a code and you prefer a
  quick "no" over a thorough search (images without a code are the slowest
  case, since every strategy runs to the end).
- If you already use ImageMagick or libvips, letting it *decode* big PNG/TIFF
  files can be faster than the pure-Ruby decoders. Keep at least ~2500 px on
  the long side for scans:

  ```ruby
  require "open3"

  def read_with_imagemagick(path)
    out, = Open3.capture2("magick", path, "-resize", "2500x2500>", "-colorspace", "Gray", "-depth", "8",
                          "-format", "%w %h\n", "-write", "info:-", "gray:-", binmode: true)
    header, pixels = out.split("\n", 2)
    width, height = header.split.map(&:to_i)
    QrReader.read(QrReader::Image.new(width, height, pixels))
  end
  ```

## What it handles

- QR Code Model 2, versions 1–40, all error correction levels and masks;
  numeric, alphanumeric, byte, Kanji and Hanzi (GB2312) segments, ECI
  character sets, structured append, FNC1 (GS1); mirrored symbols;
  light-on-dark codes.
- Photos: perspective, rotation, uneven lighting, blur, noise, JPEG artifacts.
- Scans: small codes on large pages (searched through a resolution pyramid),
  150–600 DPI, fax pages (CCITT G3/G4, non-square 204x98 dpi pixels),
  B&W/dithered scanner modes, multi-page TIFF and PDF, Swiss QR-bills (the
  cross in the middle is just damage the error correction repairs).
- JPEG 2000 (JP2 files and raw codestreams, all of Part 1: tiles, layers,
  precincts, every progression order and code-block style, 5/3 and 9/7
  wavelets); large images are first decoded at reduced resolution.
- Scanned PDFs: images compressed with JPEG (also CMYK/YCCK), JPEG 2000, CCITT
  fax, JBIG2 (generic regions), Flate, LZW, run-length; xref and object
  streams; PDFs encrypted
  with an empty user password; page images that printer drivers cut into
  (overlapping) strips.
- Digitally created PDFs: QR codes drawn as vector graphics (rectangles or
  other straight-edged paths per module or run of modules, round dots or
  rounded modules, filled or stroked, also light on a coloured background)
  and codes set as text in a barcode font (embedded TrueType, OpenType, CFF,
  Type 1 or Type 3 fonts, simple or composite).
- Multiple codes per image (`decode_all` / `read_all`).

PDF pages are not rendered as a whole: qr_reader reads the raster images a page
draws, and renders only groups of small shapes (paths and barcode-font glyphs)
that look like a vector-drawn code. Codes drawn as shadings or patterns, in
fonts that are not embedded, or with glyphs that have curves are not found.
JPEG 2000 decoding is the slowest format (a 2900 x 3900 colour page takes about
15 s without YJIT; single-tile images above 32 megapixels are decoded at half
resolution).
Images larger than 67 megapixels (JPEG) or 134 megapixels (other formats) are
rejected rather than risking huge memory use.

## Accuracy and speed

On the ZXing blackbox QR corpus (179 real-world photos, each also rotated by
90°, 180° and 270°) qr_reader decodes **688 of 716** cases, more than
zxing-cpp (664) and ZXing Java (~619), and every case zxing-cpp decodes.

On a corpus of 259 simulated scanned documents (`rake scans:generate`; A4
letters, invoices, Swiss QR-bills, receipts, labels, fax pages; 150–600 DPI;
skew, blur, noise, dot gain, fading, dithering, JPEG/TIFF/PDF output) it reads
**233 of 259** — all 109 "common" office-scanner cases, 91 of 97 "hard" and 33
of 53 "extreme" ones — against 226 for zxing-cpp, and never returns a wrong
text. A scanned page takes about 0.7 s on average (YJIT).

Time per reading (warm, one process; i7-10750H, Ruby 4.0), with and without
YJIT, and with the optional qr_reader-native kernels:

| input | YJIT | YJIT + native | no YJIT | no YJIT + native | peak RAM |
|---|---|---|---|---|---|
| small photo (ZXing corpus PNG) | 23 ms | 21 ms | 29 ms | 14 ms | 2 MB |
| 12 MP phone photo (JPEG) | 506 ms | 491 ms | 2.2 s | 1.8 s | 24 MB |
| A4 300 dpi scan (JPEG) | 199 ms | 165 ms | 712 ms | 555 ms | 13 MB |
| A4 300 dpi scan (PDF with JPEG) | 202 ms | 180 ms | 676 ms | 541 ms | 14 MB |
| A4 300 dpi scan (1-bit TIFF G4) | 121 ms | 97 ms | 444 ms | 72 ms | 28 MB |
| A4 300 dpi scan (gray PNG) | 567 ms | 545 ms | 2.6 s | 857 ms | 63 MB |
| A4 page without a code | 953 ms | 507 ms | 3.9 s | 853 ms | 63 MB |
| 12 MP photo without a code | 1.9 s | 1.1 s | 7.7 s | 2.3 s | 89 MB |

Images without a code are the slowest case: every strategy runs to the end
(`try_harder: false` stops early). The library itself needs about 10 MB.

Benchmarks: `bundle exec ruby bench/reading.rb` (time and memory per reading),
`bench/corpus.rb` (ZXing corpus), `bench/scans/run.rb` (scanned documents),
`bench/synthetic.rb` (distortion stress test).

## Development

```bash
bundle install
bundle exec rake corpus:fetch   # ZXing test images (Apache-2.0), used by some tests
bundle exec rake test
```

### Native kernels

Hot loops live in `lib/qr_reader/kernels/` and must stay within the Ruby
subset Spinel compiles (see DESIGN.md, "Kernels"). After changing them,
regenerate the qr_reader-native sources with a Spinel checkout:

```bash
SPINEL_HOME=~/workspace/spinel bundle exec rake native:generate
bundle exec rake native:compile native:test
```

CI fails when the generated sources are out of date. Only code counts:
comments, blank lines and spacing in the kernel files can change without
regenerating.

### Releasing

Releases are published from GitHub Actions with RubyGems
[trusted publishing](https://guides.rubygems.org/trusted-publishing/) — no API
key is stored anywhere — and each gem carries a Sigstore attestation, so
RubyGems.org shows which repository, workflow and commit built it. One tag releases both gems, qr_reader and
qr_reader-native, at the same version. Bump `QrReader::VERSION`, update
`CHANGELOG.md`, then:

```bash
git tag v0.0.1
git push origin v0.0.1
```

## License

MIT. The ZXing test images fetched by `rake corpus:fetch` are Apache-2.0 and
are not part of the gem.
