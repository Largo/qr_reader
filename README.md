# qr_reader

A fast, accurate QR code reader in pure Ruby. No native extensions, no
ImageMagick, no zbar — just Ruby (and its standard library). Reads photos and
scanned documents: PNG, JPEG, GIF, BMP, PNM, TIFF (including CCITT G3/G4 fax
compression) and the images inside scanned PDFs.

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
```

## Installation

```bash
bundle add qr_reader
```

Requires Ruby 3.2 or newer. Enable YJIT for the best speed
(`RUBY_YJIT_ENABLE=1`, `ruby --yjit`, or `RubyVM::YJIT.enable` at boot) — it
makes reading 3–10x faster.

## Usage

| method | returns |
|---|---|
| `QrReader.decode(input)` | text of the first code, or `nil` |
| `QrReader.decode!(input)` | text of the first code, or raises `QrReader::NotFoundError` |
| `QrReader.decode_all(input)` | texts of all codes (all pages) |
| `QrReader.read(input)` | first code as a `QrReader::Result`, or `nil` |
| `QrReader.read_all(input)` | all codes as `QrReader::Result`s |
| `QrReader.scan(input) { \|result\| }` | yields codes as they are found; an `Enumerator` without a block |

`input` can be a file path (`String` or `Pathname`), an `IO`, a binary
`String` with the encoded image, a `QrReader::Image`, or any object with
`width`, `height` and `pixels` (e.g. a `ChunkyPNG::Image`). Raw pixel buffers
can be wrapped with `QrReader::Image.from_pixels(width, height, bytes, :rgba)`
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

Errors: `QrReader::ImageError` (unreadable image data),
`QrReader::UnsupportedImageError` (e.g. WebP, HEIC, encrypted PDF),
`Errno::ENOENT` for missing files.

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
  300/600 DPI, 1-bit fax-style images, multi-page TIFF and PDF, Swiss QR-bills
  (the cross in the middle is just damage the error correction repairs).
- Multiple codes per image (`decode_all` / `read_all`).

Vector-drawn QR codes in digitally created PDFs are not rendered — only raster
images embedded in the PDF are scanned. JBIG2 and JPEG 2000 images in PDFs are
skipped.

## Accuracy and speed

On the ZXing blackbox QR corpus (179 real-world photos, each also rotated by
90°, 180° and 270°) qr_reader decodes **688 of 716** cases, more than
zxing-cpp (664) and ZXing Java (~619), and every case zxing-cpp decodes.

Benchmarks: `bundle exec ruby bench/reading.rb` (time and memory per reading),
`bench/corpus.rb` (ZXing corpus), `bench/synthetic.rb` (distortion stress
test).

## Development

```bash
bundle install
bundle exec rake corpus:fetch   # ZXing test images (Apache-2.0), used by some tests
bundle exec rake test
```

### Releasing

Releases are published from GitHub Actions with RubyGems
[trusted publishing](https://guides.rubygems.org/trusted-publishing/) — no API
key is stored anywhere. Bump `QrReader::VERSION`, update `CHANGELOG.md`, then:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## License

MIT. The ZXing test images fetched by `rake corpus:fetch` are Apache-2.0 and
are not part of the gem.
