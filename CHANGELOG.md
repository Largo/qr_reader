# Changelog

## [Unreleased]

- `QrReader.read!`: like `read`, but raises `NotFoundError` when no code is
  found (the `Result` counterpart of `decode!`).
- **Breaking:** a `String` input is always a file path, never image data;
  pass image bytes as an IO (`QrReader.decode(StringIO.new(bytes))`, or the
  upload's `Tempfile` directly), like `File.read` and `PDF::Reader.new`.
  Before, Strings were sniffed: bytes that spelled the path of an existing
  file (e.g. an uploaded "image" containing `/etc/...` or the path of a
  server-side image with a QR code) were read from disk, and the error for
  unrecognised data echoed the file's first bytes. A `String` that looks like
  image data now raises `ArgumentError` with that hint.
- PDF: a document that draws no image and no code-like vector group (e.g. a
  text-only invoice page) has no codes: `decode_all` returns `[]` and
  `decode` `nil` instead of raising `UnsupportedImageError` "PDF contains no
  raster images". PDFs whose images all fail to decode still raise.
- PDF: data behind a `%PDF-` header without a page tree raises `ImageError`
  "corrupt PDF (no pages found)" instead of "PDF contains no raster images".

## [0.0.2] - 2026-10-13

- JPEG 2000: pure-Ruby decoder for all of Part 1 (`Formats::JPEG2000`), used
  for standalone JP2/J2K files and JPXDecode images in PDFs; large images are
  read from a reduced-resolution decode first.
- PDF: QR codes drawn as vector graphics are read (groups of small filled or
  stroked right-angled paths or round dots are rasterized;
  `PDF.each_image(vector: true)`), also when set as text in an embedded
  barcode font (TrueType, OpenType, CFF, Type 1, Type 3; simple and Type 0).
- PDF: CMYK and YCCK JPEGs without an inverting `/Decode` array are read
  (as ink amounts, like other PDF readers) instead of being rejected;
  `JPEG.decode(bytes, cmyk: :plain)`.
- PDF: page images cut into strips that overlap by a row or two are joined
  again (a QR-bill printed through a driver that repeats a row per strip was
  not found).
- Long thin images (e.g. 4961x17 strips) no longer raise
  `ArgumentError: downscale factor too large`.

## [0.0.1] - 2026-10-13

- Initial release: pure-Ruby QR code reader (Model 2, versions 1–40; numeric,
  alphanumeric, byte, Kanji, Hanzi, ECI, structured append, FNC1).
- Input: PNG, JPEG (baseline/progressive), GIF, BMP, PNM, TIFF (incl. CCITT
  G3/G4 fax, LZW, Deflate, PackBits, JPEG), PDF (embedded images: JPEG, CCITT,
  JBIG2 generic regions, Flate, LZW, ...), raw pixel buffers.
- Photos and scans: resolution pyramid for large pages, reduced-size JPEG
  decoding, fax pixel-aspect correction, multi-page TIFF/PDF (`Result#page`).
- API: `decode`, `decode!`, `decode_all`, `read`, `read_all`, `scan`;
  `qr_reader` command-line tool.
- Optional `qr_reader-native` gem: the same kernels compiled with Spinel.
