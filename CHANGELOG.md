# Changelog

## [Unreleased]

## [0.1.0]

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
