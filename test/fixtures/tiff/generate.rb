#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates the TIFF fixtures in this directory (development only):
#
#   PILLOW_PYTHON=/path/to/venv/bin/python bundle exec ruby test/fixtures/tiff/generate.rb
#
# Needs ImageMagick 7 (`magick`, built with libtiff), Python with Pillow
# built with libtiff (PILLOW_PYTHON, default `python3`, always run with -I)
# and the rqrcode_core dev dependency.
#
# Every fixture is written by a real encoder: ImageMagick (libtiff) for most,
# Pillow (libtiff) for Group 3 T4Options variants and CCITT RLE. Reference
# pixels are ImageMagick's decoding of each page as 8-bit RGBA (CMYK pages:
# raw 8-bit CMYK), stored zlib-compressed and deduplicated as
# ref_<digest>.{rgba,cmyk}.z; large bilevel pages store only the SHA-256 of
# their luminance, and the run-length coverage image is computed by the test.
# Pillow decodes every page too and any disagreement is reported.
#
# Finally the test-side encoders in tiff_fixtures.rb (CCITT in all TIFF
# variants, LZW in both bit orders, PackBits) are checked against libtiff by
# letting Pillow decode TIFFs built with them: the CCITT tests rely on them.

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "zlib"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__), File.expand_path("../../support", __dir__)
require "qr_reader" # Image.from_pixels / Image.luma only: the luminance semantics under test
require "qr_test_helper"
require_relative "tiff_fixtures"

module TiffFixtureGenerator
  DIR = __dir__
  PYTHON = ENV.fetch("PILLOW_PYTHON", "python3")

  # name => [sources, ImageMagick arguments] or [sources, { pillow: save keyword arguments }].
  # Options: tolerance (maximum difference allowed), digest (store only the
  # luminance digest). ImageMagick ignores rows-per-strip for Group 4,
  # -interlace for CMYK, always uses predictor 2 for 8-bit LZW/Zip and writes
  # broken associated alpha, so the tests craft those variants themselves.
  FIXTURES = {
    # Bilevel (203x157: rows are not a whole number of bytes)
    "bilevel_none.tif" => [%w[bilevel], %w[-type Bilevel -compress None]],
    "bilevel_none_lsb.tif" => [%w[bilevel], %w[-type Bilevel -compress None -define tiff:fill-order=lsb]],
    "bilevel_packbits.tif" => [%w[bilevel], %w[-type Bilevel -compress RLE]],
    "bilevel_lzw_msb.tif" => [%w[bilevel], %w[-type Bilevel -compress LZW -endian MSB]],
    "bilevel_lzw_lsb.tif" => [%w[bilevel], %w[-type Bilevel -compress LZW -define tiff:fill-order=lsb]],
    "bilevel_g4.tif" => [%w[bilevel], %w[-compress Group4]],
    "bilevel_g4_miniswhite.tif" => [%w[bilevel], %w[-compress Group4 -define quantum:polarity=min-is-white]],
    "bilevel_g4_lsb.tif" => [%w[bilevel], %w[-compress Group4 -define tiff:fill-order=lsb]],
    "bilevel_g4_msb.tif" => [%w[bilevel], %w[-compress Group4 -endian MSB]],
    "bilevel_g4_tiles.tif" => [%w[bilevel], %w[-compress Group4 -define tiff:tile-geometry=64x64]],
    "bilevel_fax.tif" => [%w[bilevel], %w[-compress Fax -define quantum:polarity=min-is-white]],
    "bilevel_g3_1d.tif" => [%w[bilevel], { pillow: { compression: "group3", tiffinfo: { 292 => 0 } } }],
    "bilevel_g3_2d.tif" => [%w[bilevel], { pillow: { compression: "group3", tiffinfo: { 292 => 1 } } }],
    "bilevel_g3_fill.tif" => [%w[bilevel], { pillow: { compression: "group3", tiffinfo: { 292 => 4 } } }],
    "bilevel_g3_2d_fill.tif" => [%w[bilevel], { pillow: { compression: "group3", tiffinfo: { 292 => 5 } } }],
    "bilevel_rle.tif" => [%w[bilevel], { pillow: { compression: "tiff_ccitt" } }],
    # Every run-length code of both colours, incl. extended make-up codes
    "runs_g4.tif" => [%w[runs], %w[-compress Group4]],
    "runs_fax.tif" => [%w[runs], %w[-compress Fax]],
    "runs_g3_2d_fill.tif" => [%w[runs], { pillow: { compression: "group3", tiffinfo: { 292 => 5 } } }],
    "runs_rle.tif" => [%w[runs], { pillow: { compression: "tiff_ccitt" } }],
    # 8-bit gray (75x53) and other depths
    "gray_none.tif" => [%w[gray], %w[-compress None]],
    "gray_lzw_predictor.tif" => [%w[gray], %w[-compress LZW -define tiff:predictor=2]],
    "gray_zip_predictor_msb.tif" => [%w[gray], %w[-compress Zip -define tiff:predictor=2 -endian MSB]],
    "gray_packbits.tif" => [%w[gray], %w[-compress RLE]],
    "gray_miniswhite.tif" => [%w[gray], %w[-compress LZW -define quantum:polarity=min-is-white]],
    "gray_strips.tif" => [%w[gray], %w[-compress Zip -define tiff:rows-per-strip=5]],
    "gray_tiles.tif" => [%w[gray], %w[-compress LZW -define tiff:tile-geometry=32x32]],
    "gray_jpeg.tif" => [%w[gray], %w[-compress JPEG -quality 90]],
    "gray_jpeg_tiles.tif" => [%w[gray], %w[-compress JPEG -quality 90 -define tiff:tile-geometry=32x32]],
    "gray_depth2.tif" => [%w[gray], %w[-depth 2 -compress None]],
    "gray_depth4.tif" => [%w[gray], %w[-depth 4 -compress LZW]],
    "gray_depth16.tif" => [%w[gray], %w[-depth 16 -compress LZW -define tiff:predictor=2]],
    "gray_depth16_msb.tif" => [%w[gray], %w[-depth 16 -compress Zip -define tiff:predictor=2 -endian MSB]],
    "gray_float.tif" => [%w[gray], %w[-depth 32 -define quantum:format=floating-point -compress Zip
                                      -define tiff:predictor=3]],
    "gray_bigtiff.tif" => [%w[gray], %w[-compress LZW -define tiff:predictor=2 TIFF64:]],
    # Colour (61x45)
    "rgb_none.tif" => [%w[color], %w[-compress None]],
    "rgb_lzw_predictor.tif" => [%w[color], %w[-compress LZW -define tiff:predictor=2]],
    "rgb_zip_msb.tif" => [%w[color], %w[-compress Zip -endian MSB]],
    "rgb_planar.tif" => [%w[color], %w[-compress LZW -interlace Plane]],
    "rgb_jpeg.tif" => [%w[color], %w[-compress JPEG -quality 90]],
    "rgb16_zip_predictor.tif" => [%w[color], %w[-depth 16 -compress Zip -define tiff:predictor=2]],
    # Colour map entries are not multiples of 257: libtiff readers take the
    # high byte, ImageMagick rounds.
    "palette_lzw.tif" => [%w[color], %w[-colors 200 -type Palette -compress LZW], { tolerance: 1 }],
    "palette4.tif" => [%w[color], %w[-colors 16 -type Palette -depth 4 -compress None]],
    "cmyk_lzw.tif" => [%w[color], %w[-colorspace CMYK -compress LZW]],
    # Alpha (37x29)
    "rgba_zip.tif" => [%w[rgba], %w[-compress Zip]],
    "rgba_planar.tif" => [%w[rgba], %w[-compress Zip -interlace Plane]],
    "gray_alpha.tif" => [%w[rgba], %w[-type GrayscaleAlpha -compress LZW]],
    # Multi-page
    "multipage_mixed.tif" => [%w[bilevel gray color], %w[-compress LZW]],
    "multipage_g4.tif" => [%w[bilevel bilevel_negated runs], %w[-compress Group4]],
    # A4 page at 300 DPI as a sheet-fed scanner writes it (text, rules, a QR code)
    "scan_a4_g4.tif" => [%w[page], %w[-type Bilevel -compress Group4 -define quantum:polarity=min-is-white],
                         { digest: true }]
  }.freeze

  PAGE_TEXT = "https://example.com/invoice/2026-10-13/4711"

  module_function

  def run
    Dir.mktmpdir do |tmp|
      sources = write_sources(tmp)
      Dir[File.join(DIR, "*.tif")].each { |f| File.delete(f) }
      Dir[File.join(DIR, "ref_*.z")].each { |f| File.delete(f) }
      manifest = {}
      FIXTURES.each do |name, (srcs, how, opts)|
        path = File.join(DIR, name)
        inputs = srcs.map { |s| sources.fetch(s) }
        if how.is_a?(Hash)
          pillow_save(inputs.first, path, how[:pillow])
        else
          *args, prefix = how.last&.end_with?(":") ? how : how + [""]
          sh("magick", *inputs, *args, "#{prefix}#{path}")
        end
        manifest[name] = { "pages" => references(path, name, srcs, opts || {}) }
        manifest[name]["tolerance"] = opts[:tolerance] if opts&.key?(:tolerance)
        puts format("%-30s %7d bytes, %d page(s)", name, File.size(path), manifest[name]["pages"].size)
      end
      File.write(File.join(DIR, "manifest.json"), "#{JSON.pretty_generate(manifest)}\n")
      cross_check(manifest, tmp)
      check_encoders(tmp)
    end
    total = Dir[File.join(DIR, "*")].sum { |f| File.size(f) }
    puts "total #{total} bytes"
  end

  def sh(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

    out
  end

  # --- sources ---------------------------------------------------------------

  def write_sources(tmp)
    {
      "gray" => raw_png(tmp, "gray", 75, 53, 1) { |x, y| gray_pixel(x, y) },
      "color" => raw_png(tmp, "color", 61, 45, 3) { |x, y| color_pixel(x, y) },
      "rgba" => raw_png(tmp, "rgba", 37, 29, 4) { |x, y| color_pixel(x * 2, y * 2) + [alpha(x, y)] },
      "bilevel" => bilevel_source(tmp, false),
      "bilevel_negated" => bilevel_source(tmp, true),
      "runs" => runs_source(tmp),
      "page" => page_source(tmp)
    }
  end

  def raw_png(tmp, name, w, h, channels)
    data = Array.new(h) { |y| Array.new(w) { |x| yield(x, y) } }.flatten.pack("C*")
    raw = File.join(tmp, "#{name}.raw")
    File.binwrite(raw, data)
    png = File.join(tmp, "#{name}.png")
    map = { 1 => "gray", 3 => "rgb", 4 => "rgba" }.fetch(channels)
    sh("magick", "-size", "#{w}x#{h}", "-depth", "8", "#{map}:#{raw}", png)
    png
  end

  # Full 8-bit range: gradient, blocks and a deterministic pattern.
  def gray_pixel(x, y)
    v = (x * 7 + y * 13 + (x * y) % 17) % 256
    (((x / 6) + (y / 6)) % 3).zero? ? v / 4 : v
  end

  def color_pixel(x, y)
    return [20, 30, 200] if (x / 10 + y / 10).even? && x % 10 < 3
    return [0, 0, 0] if x < 4 && y < 4
    return [255, 255, 255] if x > 50 && y > 35

    [(x * 37 + y * 3) % 256, (y * 41 + x) % 256, (x * y * 5) % 256]
  end

  def alpha(x, y)
    return 0 if x < 5
    return 255 if y < 5

    (x * 7 + y * 11) % 256
  end

  # 203x157 bilevel: a QR code plus deterministic clutter (dots, bars, blocks).
  def bilevel_source(tmp, negated)
    w = 203
    h = 157
    rows = Array.new(h) { Array.new(w, 0) }
    qr = QrTestHelper.rqr_matrix("TIFF test", level: :m)
    qr.height.times do |my|
      qr.width.times do |mx|
        next unless qr.dark?(mx, my)

        3.times { |dy| 3.times { |dx| rows[12 + my * 3 + dy][12 + mx * 3 + dx] = 1 } }
      end
    end
    rng = Random.new(42)
    300.times do
      x = 100 + rng.rand(w - 100)
      y = rng.rand(h)
      len = 1 + rng.rand(30)
      len.times { |i| rows[y][x + i] = 1 if x + i < w }
    end
    rows[150][0, w] = Array.new(w, 1)
    rows[151][0, w] = Array.new(w, 1)
    (90..140).each { |y| (5..60).each { |x| rows[y][x] = (x + y).odd? ? 1 : 0 } }
    (100..120).each { |y| rows[y][w - 1] = 1 }
    rows.each { |r| r.map! { |b| b ^ 1 } } if negated
    bilevel_png(tmp, negated ? "bilevel_negated" : "bilevel", rows)
  end

  def runs_source(tmp)
    w = 5256
    h = 258
    path = File.join(tmp, "runs.raw")
    File.binwrite(path, TiffFixtures.runs_image(w, h))
    png = File.join(tmp, "runs.png")
    sh("magick", "-size", "#{w}x#{h}", "-depth", "8", "gray:#{path}", "-type", "Bilevel", png)
    png
  end

  def bilevel_png(tmp, name, rows)
    image = TiffFixtures.bilevel_image(rows)
    raw = File.join(tmp, "#{name}.raw")
    File.binwrite(raw, image.data)
    png = File.join(tmp, "#{name}.png")
    sh("magick", "-size", "#{image.width}x#{image.height}", "-depth", "8", "gray:#{raw}", "-type", "Bilevel", png)
    png
  end

  def page_source(tmp)
    qr = QrTestHelper.render(QrTestHelper.rqr_matrix(PAGE_TEXT, level: :m), module_size: 10, quiet: 2)
    qr_png = File.join(tmp, "page_qr.png")
    QrTestHelper.write_png(qr, qr_png)
    rng = Random.new(7)
    words = %w[lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore
               et dolore magna aliqua Invoice Total Amount due Payment reference Account 2026 CHF 1'234.50 No.]
    lines = Array.new(70) { Array.new(9 + rng.rand(4)) { words[rng.rand(words.size)] }.join(" ") }
    png = File.join(tmp, "page.png")
    sh("magick", "-size", "2480x3508", "xc:white", "-fill", "black", "-font", "DejaVu-Sans", "-pointsize", "34",
       "-annotate", "+200+300", lines.first(25).join("\n"), "-annotate", "+200+2050", lines.drop(25).join("\n"),
       "-pointsize", "70", "-font", "DejaVu-Sans-Bold", "-annotate", "+200+200", "INVOICE",
       "-stroke", "black", "-strokewidth", "3", "-draw", "line 200,1950 2280,1950",
       qr_png, "-geometry", "+1700+1400", "-composite", "-rotate", "0.4", "-gravity", "center",
       "-extent", "2480x3508", "-threshold", "50%", png)
    png
  end

  # --- writers and references ------------------------------------------------

  PILLOW_SAVE = <<~PY
    import json, sys
    from PIL import Image, TiffImagePlugin
    TiffImagePlugin.WRITE_LIBTIFF = True
    src, dst, opts = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
    info = {int(k): v for k, v in opts.pop("tiffinfo", {}).items()}
    Image.open(src).convert("1").save(dst, tiffinfo=info, **opts)
  PY

  def pillow_save(src, dst, opts)
    sh(PYTHON, "-I", "-c", PILLOW_SAVE, src, dst, JSON.generate(opts))
  end

  def page_count(path)
    sh("magick", "identify", path).lines.size
  end

  def references(path, name, srcs, opts)
    Array.new(page_count(path)) do |page|
      cmyk = name.start_with?("cmyk")
      data = sh("magick", "#{path}[#{page}]", "-depth", "8", "#{cmyk ? 'cmyk' : 'rgba'}:-").b
      size = sh("magick", "identify", "-format", "%w %h", "#{path}[#{page}]").split.map(&:to_i)
      entry = { "width" => size[0], "height" => size[1] }
      if srcs[page] == "runs"
        luma = QrReader::Image.from_pixels(*size, data, :rgba).data
        raise "#{name}: ImageMagick disagrees with the run-length image" unless luma == TiffFixtures.runs_image(*size)

        entry["reference"] = "runs"
      elsif opts[:digest]
        entry["sha256"] = Digest::SHA256.hexdigest(QrReader::Image.from_pixels(*size, data, :rgba).data)
        entry["text"] = PAGE_TEXT
      else
        file = "ref_#{Digest::SHA256.hexdigest(data)[0, 16]}.#{cmyk ? 'cmyk' : 'rgba'}.z"
        File.binwrite(File.join(DIR, file), Zlib::Deflate.deflate(data, 9))
        entry["reference"] = file
      end
      entry
    end
  end

  # --- cross-checks ------------------------------------------------------------

  # Decodes files with Pillow: one line per page "<file> <page> <mode> <w> <h>"
  # and the page's RGBA (or CMYK) bytes in OUT/<index>.<page>.raw.
  PILLOW_DECODE = <<~PY
    import sys
    import numpy as np
    from PIL import Image, ImageSequence
    out = sys.argv[1]
    for i, path in enumerate(sys.argv[2:]):
        im = Image.open(path)
        for p, frame in enumerate(ImageSequence.Iterator(im)):
            if frame.mode == "CMYK":
                data = frame.tobytes()
            elif frame.mode.startswith("I;16"):
                high = (np.asarray(frame).astype(np.uint32) >> 8).astype(np.uint8)
                data = Image.fromarray(high, "L").convert("RGBA").tobytes()
            elif frame.mode == "F":
                scaled = np.clip(np.asarray(frame) * 255 + 0.5, 0, 255).astype(np.uint8)
                data = Image.fromarray(scaled, "L").convert("RGBA").tobytes()
            else:
                data = frame.convert("RGBA").tobytes()
            with open(f"{out}/{i}.{p}.raw", "wb") as f:
                f.write(data)
            print(i, p, frame.mode, frame.size[0], frame.size[1], flush=True)
  PY

  def cross_check(manifest, tmp)
    names = manifest.keys
    out = sh(PYTHON, "-I", "-c", PILLOW_DECODE, tmp, *names.map { |n| File.join(DIR, n) })
    out.lines.each do |line|
      i, page, mode, w, h = line.split
      name = names[i.to_i]
      entry = manifest[name]["pages"][page.to_i]
      data = File.binread(File.join(tmp, "#{i}.#{page}.raw"))
      pillow = if mode == "CMYK" then TiffFixtures.cmyk_luma(data)
               else QrReader::Image.from_pixels(w.to_i, h.to_i, data, :rgba).data
               end
      if entry["sha256"]
        puts "  #{name}[#{page}]: Pillow disagrees" if Digest::SHA256.hexdigest(pillow) != entry["sha256"]
        next
      end
      expected = TiffFixtures.expected(name, page.to_i).data
      diff = pillow.bytes.zip(expected.bytes).map { |a, b| (a - b).abs }.max
      puts "  #{name}[#{page}] (#{mode}): Pillow differs from ImageMagick by up to #{diff}" if diff.positive?
    end
  end

  # Builds TIFFs with the test-side encoders and checks that libtiff
  # (through Pillow) decodes them to the encoded image.
  def check_encoders(tmp)
    cases = []
    [[203, 37], [1, 5], [8, 9], [9, 4], [2600, 6], [1728, 20]].each_with_index do |(w, h), i|
      rows = TiffFixtures.random_bilevel(w, h, seed: i)
      enc = TiffFixtures::CcittEncoder
      cases << [rows, 4, {}, enc.encode(rows, k: -1)]
      cases << [rows, 4, { 266 => 2 }, enc.encode(rows, k: -1, fill_order: 2)]
      cases << [rows, 3, { 292 => 0 }, enc.encode(rows, k: 0)]
      cases << [rows, 3, { 292 => 4 }, enc.encode(rows, k: 0, byte_align: :eol)]
      cases << [rows, 3, { 292 => 1 }, enc.encode(rows, k: 2)]
      cases << [rows, 3, { 292 => 5 }, enc.encode(rows, k: 4, byte_align: :eol)]
      cases << [rows, 2, {}, enc.encode(rows, k: 0, eol: false, byte_align: :row, rtc: false)]
      # Bit 1 is white with BlackIsZero, as the CCITT cases decode coded black.
      bytes = rows.map { |r| [r.join].pack("B*") }.join
      cases << [rows, 5, {}, TiffFixtures::LzwEncoder.encode(bytes)]
      cases << [rows, 5, {}, TiffFixtures::LzwEncoder.encode(bytes, compat: true)]
      cases << [rows, 5, {}, TiffFixtures::LzwEncoder.encode(bytes, clear_every: 50)]
      cases << [rows, 32_773, {}, TiffFixtures::PackBits.encode(bytes)]
    end
    files = cases.each_with_index.map do |(rows, compression, extra, data), i|
      tags = { 256 => rows[0].size, 257 => rows.size, 258 => 1, 259 => compression, 262 => 1, 278 => rows.size }
      path = File.join(tmp, "enc#{i}.tif")
      File.binwrite(path, TiffFixtures::TiffWriter.build([{ tags: tags.merge(extra), chunks: [data] }]))
      path
    end
    sh(PYTHON, "-I", "-c", PILLOW_DECODE, tmp, *files).lines.each do |line|
      i, _page, _mode, w, h = line.split
      rows, compression, extra = cases[i.to_i]
      got = QrReader::Image.from_pixels(w.to_i, h.to_i, File.binread(File.join(tmp, "#{i}.0.raw")), :rgba).data
      # PhotometricInterpretation 1 (BlackIsZero): coded black is white.
      want = rows.flatten.map { |b| b == 1 ? 255 : 0 }.pack("C*")
      raise "test encoder case #{i} (compression #{compression} #{extra}) disagrees with libtiff" unless got == want
    end
    puts "test-side encoders agree with libtiff (#{cases.size} cases)"
  end
end

TiffFixtureGenerator.run if $PROGRAM_NAME == __FILE__
