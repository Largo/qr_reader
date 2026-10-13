# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/tiff/tiff_fixtures"

class TestTIFF < Minitest::Test
  TIFF = QrReader::Formats::TIFF
  Writer = TiffFixtures::TiffWriter
  Image = QrReader::Image

  def build(width, height, chunks, tags = {}, endian: :little, big: false, tiled: false)
    Writer.build([{ tags: { 256 => width, 257 => height }.merge(tags), chunks: chunks, tiled: tiled }],
                 endian: endian, big: big)
  end

  def assert_image(expected, actual, message = nil, tolerance: 0)
    assert_equal [expected.width, expected.height], [actual.width, actual.height], message
    return if expected.data == actual.data && tolerance.zero?

    expected.data.bytes.zip(actual.data.bytes).each_with_index do |(a, b), i|
      next if (a - b).abs <= tolerance

      flunk "#{message}: pixel (#{i % expected.width}, #{i / expected.width}) is #{b}, expected #{a}"
    end
  end

  def gray(width, height, values)
    Image.new(width, height, values.pack("C*"))
  end

  def random_bytes(n, seed:, max: 256)
    rng = Random.new(seed)
    Array.new(n) { rng.rand(max) }
  end

  def luma(r, g, b)
    Image.luma(r, g, b)
  end

  # Packs sample rows (Arrays of Integers) MSB first, each row padded to a byte.
  def pack_bits(rows, bps)
    rows.map { |row| [row.map { |v| v.to_s(2).rjust(bps, "0") }.join].pack("B*") }.join
  end

  # --- real encoders (ImageMagick, Pillow) -----------------------------------

  TiffFixtures.manifest.each do |name, entry|
    define_method("test_fixture_#{name.delete_suffix('.tif')}") do
      bytes = TiffFixtures.read(name)
      assert_equal entry["pages"].size, TIFF.page_count(bytes)
      entry["pages"].each_with_index do |page, i|
        image = TIFF.decode(bytes, page: i)
        assert_equal [page["width"], page["height"]], TIFF.dimensions(bytes, page: i)
        if page["sha256"]
          assert_equal page["sha256"], Digest::SHA256.hexdigest(image.data), "#{name} page #{i}"
        else
          assert_image TiffFixtures.expected(name, i), image, "#{name} page #{i}", tolerance: entry["tolerance"] || 0
        end
      end
    end
  end

  # --- layout -------------------------------------------------------------------

  def test_byte_orders_and_bigtiff
    values = random_bytes(13 * 7, seed: 1)
    data = values.pack("C*")
    chunks = [data.byteslice(0, 39), data.byteslice(39, 39), data.byteslice(78, 13)]
    [[:little, false], [:big, false], [:little, true], [:big, true]].each do |endian, big|
      bytes = build(13, 7, chunks, { 258 => 8, 259 => 1, 262 => 1, 278 => 3 }, endian: endian, big: big)
      assert_image gray(13, 7, values), TIFF.decode(bytes), "#{endian} big=#{big}"
      assert_equal [13, 7], TIFF.dimensions(bytes)
    end
  end

  def test_partial_and_missing_tiles
    w = 37
    h = 21
    values = random_bytes(w * h, seed: 2)
    tiles = []
    (0...h).step(16) do |y0|
      (0...w).step(16) do |x0|
        tile = Array.new(16) do |y|
          Array.new(16) { |x| x0 + x < w && y0 + y < h ? values[(y0 + y) * w + x0 + x] : 99 }
        end
        tiles << tile.flatten.pack("C*")
      end
    end
    tags = { 258 => 8, 259 => 1, 262 => 1, 322 => 16, 323 => 16 }
    assert_image gray(w, h, values), TIFF.decode(build(w, h, tiles, tags, tiled: true))

    # Tile 1 missing (offset 0), tile 4 truncated after three rows.
    tiles[4] = tiles[4].byteslice(0, 3 * 16 + 5)
    bytes = build(w, h, tiles, tags, tiled: true)
    offsets = TiffFixtures.first_directory(bytes)[324]
    bytes = build(w, h, tiles, tags.merge(324 => [4, [offsets[0], 0] + offsets[2..]]), tiled: true)
    want = values.dup
    (0...16).each { |y| (16...32).each { |x| want[y * w + x] = 255 } }
    (19...21).each { |y| (16...32).each { |x| want[y * w + x] = 255 } }
    assert_image gray(w, h, want), TIFF.decode(bytes)
  end

  def test_missing_strips_byte_counts_and_odd_rows_per_strip
    values = random_bytes(10 * 7, seed: 3)
    data = values.pack("C*")
    # No StripByteCounts: data runs to the end of the file.
    assert_image gray(10, 7, values), TIFF.decode(build(10, 7, [data], { 258 => 8, 262 => 1, 279 => nil }))
    # RowsPerStrip 0 or beyond the height means one strip.
    [0, 7, 1000].each do |rps|
      assert_image gray(10, 7, values), TIFF.decode(build(10, 7, [data], { 258 => 8, 262 => 1, 278 => rps }))
    end
    # Fewer strips than RowsPerStrip implies: the missing rows are white.
    bytes = build(10, 7, [data.byteslice(0, 20), data.byteslice(20, 20)], { 258 => 8, 262 => 1, 278 => 2 })
    assert_image gray(10, 7, values.first(40) + [255] * 30), TIFF.decode(bytes)
  end

  def test_planar_configuration_with_tiles_and_missing_planes
    w = 21
    h = 18
    rgb = Array.new(3) { |c| random_bytes(w * h, seed: 10 + c) }
    planes = rgb.map do |plane|
      (0...h).step(16).flat_map do |y0|
        (0...w).step(16).map do |x0|
          tile = Array.new(16) { |y| Array.new(16) { |x| x0 + x < w && y0 + y < h ? plane[(y0 + y) * w + x0 + x] : 0 } }
          tile.flatten.pack("C*")
        end
      end
    end
    tags = { 258 => [8, 8, 8], 262 => 2, 277 => 3, 284 => 2, 322 => 16, 323 => 16 }
    want = Array.new(w * h) { |i| luma(rgb[0][i], rgb[1][i], rgb[2][i]) }
    assert_image gray(w, h, want), TIFF.decode(build(w, h, planes.flatten, tags, tiled: true))

    # The first tile missing in every plane: white.
    bytes = build(w, h, planes.flatten, tags, tiled: true)
    offsets = TiffFixtures.first_directory(bytes)[324]
    [0, 4, 8].each { |i| offsets[i] = 0 }
    bytes = build(w, h, planes.flatten, tags.merge(324 => [4, offsets]), tiled: true)
    (0...16).each { |y| (0...16).each { |x| want[y * w + x] = 255 } }
    assert_image gray(w, h, want), TIFF.decode(bytes)
  end

  # --- compression ----------------------------------------------------------------

  def test_lzw_variants
    rng = Random.new(4)
    smooth = Array.new(300 * 40) { |i| (i / 7 + rng.rand(3)) % 256 } # long strings, several table fills
    noisy = random_bytes(64 * 200, seed: 5) # table full after ~4000 codes
    [[300, 40, smooth], [64, 200, noisy]].each do |w, h, values|
      data = values.pack("C*")
      [{}, { compat: true }, { clear_every: 97 }].each do |opts|
        chunk = TiffFixtures::LzwEncoder.encode(data, **opts)
        bytes = build(w, h, [chunk], { 258 => 8, 259 => 5, 262 => 1 })
        assert_image gray(w, h, values), TIFF.decode(bytes), "#{w}x#{h} #{opts}"
      end
    end
  end

  def test_lzw_with_horizontal_predictor_on_rgb
    w = 23
    h = 9
    pixels = random_bytes(w * h * 3, seed: 6)
    diff = pixels.each_slice(w * 3).flat_map do |row|
      row.each_with_index.map { |v, i| i < 3 ? v : (v - row[i - 3]) & 255 }
    end
    chunk = TiffFixtures::LzwEncoder.encode(diff.pack("C*"))
    bytes = build(w, h, [chunk], { 258 => [8, 8, 8], 259 => 5, 262 => 2, 277 => 3, 317 => 2 })
    want = pixels.each_slice(3).map { |r, g, b| luma(r, g, b) }
    assert_image gray(w, h, want), TIFF.decode(bytes)
  end

  def test_packbits_and_deflate
    values = Array.new(50 * 12) { |i| i % 50 < 20 ? 7 : (i * 13) % 256 }
    data = values.pack("C*")
    [[32_773, TiffFixtures::PackBits.encode(data)], [8, Zlib::Deflate.deflate(data)],
     [32_946, Zlib::Deflate.deflate(data)], [8, Zlib::Deflate.deflate(data)[2..-5]]].each do |compression, chunk|
      bytes = build(50, 12, [chunk], { 258 => 8, 259 => compression, 262 => 1 })
      assert_image gray(50, 12, values), TIFF.decode(bytes), "compression #{compression}"
    end
  end

  def test_truncated_strips_leave_the_rest_white
    w = 40
    h = 30
    values = random_bytes(w * h, seed: 7, max: 200)
    data = values.pack("C*")
    {
      1 => data, 5 => TiffFixtures::LzwEncoder.encode(data), 8 => Zlib::Deflate.deflate(data),
      32_773 => TiffFixtures::PackBits.encode(data)
    }.each do |compression, chunk|
      bytes = build(w, h, [chunk.byteslice(0, chunk.bytesize / 2)], { 258 => 8, 259 => compression, 262 => 1 })
      image = TIFF.decode(bytes)
      assert_equal data.byteslice(0, w), image.row(0), "compression #{compression}"
      assert_equal "\xFF".b * w, image.row(h - 1), "compression #{compression}"
    end
  end

  def test_ccitt_strips_tiles_and_options
    w = 50
    h = 37
    rows = TiffFixtures.random_bilevel(w, h, seed: 8)
    enc = TiffFixtures::CcittEncoder
    strips = ->(**opts) { rows.each_slice(16).map { |part| enc.encode(part, **opts) } }
    want = TiffFixtures.bilevel_image(rows)
    {
      "G4" => [{ 259 => 4 }, strips.call(k: -1)],
      "G4 LSB" => [{ 259 => 4, 266 => 2 }, strips.call(k: -1, fill_order: 2)],
      "G3 1-D" => [{ 259 => 3 }, strips.call(k: 0)],
      "G3 2-D" => [{ 259 => 3, 292 => 1 }, strips.call(k: 3)],
      "G3 2-D fill" => [{ 259 => 3, 292 => 5 }, strips.call(k: 2, byte_align: :eol)],
      "MH" => [{ 259 => 2 }, strips.call(k: 0, eol: false, byte_align: :row, rtc: false)]
    }.each do |label, (tags, chunks)|
      base = { 258 => 1, 262 => 0, 278 => 16 }
      assert_image want, TIFF.decode(build(w, h, chunks, base.merge(tags))), label
      assert_image want.invert, TIFF.decode(build(w, h, chunks, base.merge(tags).merge(262 => 1))), "#{label} inv"
      # Photometric defaults to WhiteIsZero for fax data.
      assert_image want, TIFF.decode(build(w, h, chunks, base.merge(tags).merge(262 => nil))), "#{label} default"
    end

    tiles = (0...h).step(32).flat_map do |y0|
      (0...w).step(32).map do |x0|
        part = Array.new(32) { |y| Array.new(32) { |x| rows.dig(y0 + y, x0 + x) || 0 } }
        enc.encode(part, k: -1)
      end
    end
    tags = { 258 => 1, 259 => 4, 262 => 0, 322 => 32, 323 => 32 }
    assert_image want, TIFF.decode(build(w, h, tiles, tags, tiled: true)), "G4 tiles"
  end

  def test_corrupt_ccitt_strip_is_left_white
    rows = TiffFixtures.random_bilevel(30, 32, seed: 9)
    chunks = rows.each_slice(16).map { |part| TiffFixtures::CcittEncoder.encode(part, k: -1) }
    chunks[1] = "\x02\xFF\xFF\xFF".b # uncompressed-mode extension right away
    image = TIFF.decode(build(30, 32, chunks, { 258 => 1, 259 => 4, 262 => 0, 278 => 16 }))
    assert_equal TiffFixtures.bilevel_image(rows.first(16)).data, image.data.byteslice(0, 480)
    assert_equal "\xFF".b * 480, image.data.byteslice(480, 480)

    chunks[0] = chunks[1]
    assert_raises(QrReader::ImageError) do
      TIFF.decode(build(30, 32, chunks, { 258 => 1, 259 => 4, 262 => 0, 278 => 16 }))
    end
  end

  # libtiff writes JPEG data without JFIF or Adobe markers; colour images
  # are then marked by component ids "RGB" or only by the photometric tag.
  def test_rgb_jpeg_without_component_ids
    bytes = TiffFixtures.read("rgb_jpeg.tif").dup
    sof = bytes.index("\xFF\xC0".b)
    sos = bytes.index("\xFF\xDA".b)
    3.times do |c|
      bytes.setbyte(sof + 10 + 3 * c, c + 1)
      bytes.setbyte(sos + 5 + 2 * c, c + 1)
    end
    assert_image TiffFixtures.expected("rgb_jpeg.tif"), TIFF.decode(bytes)
  end

  def test_old_style_jpeg_with_interchange_format
    source = TiffFixtures.read("gray_jpeg.tif")
    tags = TiffFixtures.first_directory(source)
    tables = tags[347]
    strip = source.byteslice(tags[273][0], tags[279][0])
    jpeg = tables.byteslice(0, tables.bytesize - 2) + strip.byteslice(2..)
    bytes = build(75, 53, [jpeg], { 258 => 8, 259 => 6, 262 => 1, 513 => 8, 514 => jpeg.bytesize })
    assert_image TiffFixtures.expected("gray_jpeg.tif"), TIFF.decode(bytes)

    error = assert_raises(QrReader::UnsupportedImageError) do
      TIFF.decode(build(75, 53, [jpeg], { 258 => 8, 259 => 6, 262 => 1 }))
    end
    assert_match(/old-style JPEG/, error.message)
  end

  # --- samples ------------------------------------------------------------------------

  def test_bit_depths
    w = 11
    h = 5
    [1, 2, 3, 4, 5, 6, 7, 9, 12, 15].each do |bps|
      max = (1 << bps) - 1
      rng = Random.new(bps)
      rows = Array.new(h) { Array.new(w) { rng.rand(max + 1) } }
      want = rows.flatten.map { |v| bps < 8 ? (v * 255 + max / 2) / max : v >> (bps - 8) }
      bytes = build(w, h, [pack_bits(rows, bps)], { 258 => bps, 262 => 1 })
      assert_image gray(w, h, want), TIFF.decode(bytes), "#{bps} bits"
      bytes = build(w, h, [pack_bits(rows, bps)], { 258 => bps, 262 => 0 })
      assert_image gray(w, h, want.map { |v| 255 - v }), TIFF.decode(bytes), "#{bps} bits WhiteIsZero"
    end
  end

  def test_wide_integer_samples_and_predictor
    w = 9
    h = 4
    { 16 => %w[v* n*], 24 => nil, 32 => %w[V* N*], 64 => %w[Q<* Q>*] }.each do |bps, directives|
      rng = Random.new(bps)
      values = Array.new(w * h) { rng.rand(1 << bps) }
      want = values.map { |v| v >> (bps - 8) }
      %i[little big].each do |endian|
        size = bps / 8
        raw = values.map do |v|
          le = Array.new(size) { |i| (v >> (8 * i)) & 0xFF }
          (endian == :little ? le : le.reverse).pack("C*")
        end.join
        bytes = build(w, h, [raw], { 258 => bps, 262 => 1 }, endian: endian)
        assert_image gray(w, h, want), TIFF.decode(bytes), "#{bps} bits #{endian}"
        next unless directives

        diff = values.each_slice(w).flat_map do |row|
          row.each_with_index.map { |v, i| i.zero? ? v : (v - row[i - 1]) % (1 << bps) }
        end
        raw = diff.pack(directives[endian == :little ? 0 : 1])
        tags = { 258 => bps, 259 => 8, 262 => 1, 317 => 2 }
        bytes = build(w, h, [Zlib::Deflate.deflate(raw)], tags, endian: endian)
        assert_image gray(w, h, want), TIFF.decode(bytes), "#{bps} bits #{endian} predictor"
      end
    end
  end

  def test_signed_samples
    signed = [-128, -1, 0, 1, 127, -64]
    bytes = build(6, 1, [signed.pack("c*")], { 258 => 8, 262 => 1, 339 => 2 })
    assert_image gray(6, 1, signed.map { |v| v + 128 }), TIFF.decode(bytes)
    signed16 = [-32_768, -1, 0, 255, 32_767, 1000]
    bytes = build(6, 1, [signed16.pack("s>*")], { 258 => 16, 262 => 1, 339 => 2 }, endian: :big)
    assert_image gray(6, 1, signed16.map { |v| (v >> 8) + 128 }), TIFF.decode(bytes)
  end

  def test_floating_point_samples
    values = [-1.0, 0.0, 0.5, 1.0, 2.0, Float::NAN, Float::INFINITY, 0.25]
    want = gray(8, 1, [0, 0, 128, 255, 255, 0, 255, 64])
    { [32, :little] => "e*", [32, :big] => "g*", [64, :little] => "E*", [64, :big] => "G*" }.each do |(bps, endian), d|
      bytes = build(8, 1, [values.pack(d)], { 258 => bps, 262 => 1, 339 => 3 }, endian: endian)
      assert_image want, TIFF.decode(bytes), "float#{bps} #{endian}"
    end

    # Predictor 3: byte planes (most significant first), then byte differences.
    rows = Array.new(3) { |y| Array.new(5) { |x| (x * 0.2) + (y * 0.1) } }
    raw = rows.map do |row|
      bytes = row.pack("g*").bytes
      planes = (0...4).flat_map { |b| (0...5).map { |i| bytes[i * 4 + b] } }
      planes.each_with_index.map { |v, i| i.zero? ? v : (v - planes[i - 1]) & 0xFF }.pack("C*")
    end.join
    bytes = build(5, 3, [raw], { 258 => 32, 262 => 1, 339 => 3, 317 => 3 })
    want = rows.flatten.map { |v| ([[v].pack("g").unpack1("g"), 1.0].min * 255 + 0.5).to_i }
    assert_image gray(5, 3, want), TIFF.decode(bytes)
  end

  # --- photometric interpretations --------------------------------------------------------

  def test_palettes
    cmap = [0, 255, 10, 200, 0, 255, 20, 100, 0, 255, 30, 0] # 8-bit values: accepted like libtiff
    rows = [[0, 1, 2, 3, 3], [3, 2, 1, 0, 0]]
    want = rows.flatten.map { |i| luma(cmap[i], cmap[4 + i], cmap[8 + i]) }
    bytes = build(5, 2, [pack_bits(rows, 2)], { 258 => 2, 262 => 3, 320 => cmap })
    assert_image gray(5, 2, want), TIFF.decode(bytes)
    bytes = build(5, 2, [pack_bits(rows, 2)], { 258 => 2, 262 => 3, 320 => cmap.map { |v| v * 257 } })
    assert_image gray(5, 2, want), TIFF.decode(bytes)
    assert_raises(QrReader::ImageError) do
      TIFF.decode(build(5, 2, [pack_bits(rows, 2)], { 258 => 2, 262 => 3, 320 => cmap.first(6) }))
    end
  end

  def test_cmyk_variants
    w = 7
    h = 3
    cmyk = random_bytes(w * h * 4, seed: 11)
    want = TiffFixtures.cmyk_luma(cmyk.pack("C*")).unpack("C*")
    alpha = random_bytes(w * h, seed: 12)
    with_alpha = cmyk.each_slice(4).zip(alpha).flat_map { |px, a| px + [a] }
    planes = (0...4).map { |c| cmyk.each_slice(4).map { |px| px[c] }.pack("C*") }
    {
      "chunky" => [[cmyk.pack("C*")], { 258 => [8] * 4, 277 => 4 }],
      "alpha ignored" => [[with_alpha.pack("C*")], { 258 => [8] * 5, 277 => 5, 338 => 2 }],
      "planar" => [planes, { 258 => [8] * 4, 277 => 4, 284 => 2 }]
    }.each do |label, (chunks, tags)|
      assert_image gray(w, h, want), TIFF.decode(build(w, h, chunks, tags.merge(262 => 5))), label
    end
    ink = random_bytes(w * h, seed: 13)
    assert_image gray(w, h, ink.map { |v| 255 - v }), TIFF.decode(build(w, h, [ink.pack("C*")], { 258 => 8, 262 => 5 }))
  end

  def test_alpha_variants
    w = 6
    h = 4
    rgb = random_bytes(w * h * 3, seed: 14)
    alpha = random_bytes(w * h, seed: 15)
    alpha[0] = 0
    alpha[1] = 255
    pixels = rgb.each_slice(3).zip(alpha)
    over = ->(v, a) { (v * a + 255 * (255 - a) + 127) / 255 }

    unassociated = pixels.flat_map { |px, a| px + [a] }
    want = pixels.map { |(r, g, b), a| over.(luma(r, g, b), a) }
    tags = { 258 => [8] * 4, 262 => 2, 277 => 4, 338 => 2 }
    assert_image gray(w, h, want), TIFF.decode(build(w, h, [unassociated.pack("C*")], tags)), "unassociated"

    premultiplied = pixels.map { |px, a| px.map { |v| (v * a + 127) / 255 } + [a] }
    want = premultiplied.map { |r, g, b, a| [luma(r, g, b) + 255 - a, 255].min }
    assert_image gray(w, h, want), TIFF.decode(build(w, h, [premultiplied.flatten.pack("C*")], tags.merge(338 => 1))),
                 "associated"

    # Unspecified extra samples are ignored.
    want = pixels.map { |(r, g, b), _| luma(r, g, b) }
    assert_image gray(w, h, want), TIFF.decode(build(w, h, [unassociated.pack("C*")], tags.merge(338 => 0))),
                 "unspecified"

    v = rgb.first(w * h)
    gray_alpha = v.zip(alpha).flatten.pack("C*")
    tags = { 258 => [8, 8], 262 => 1, 277 => 2, 338 => 2 }
    want = v.zip(alpha).map { |g, a| over.(g, a) }
    assert_image gray(w, h, want), TIFF.decode(build(w, h, [gray_alpha], tags)), "gray alpha"
    want = v.zip(alpha).map { |g, a| over.(255 - g, a) }
    assert_image gray(w, h, want), TIFF.decode(build(w, h, [gray_alpha], tags.merge(262 => 0))), "WhiteIsZero alpha"
    planes = [v.pack("C*"), alpha.pack("C*")]
    want = v.zip(alpha).map { |g, a| over.(g, a) }
    assert_image gray(w, h, want), TIFF.decode(build(w, h, planes, tags.merge(284 => 2))), "planar gray alpha"
    premultiplied = v.zip(alpha).map { |g, a| [(g * a + 127) / 255, a] }
    want = premultiplied.map { |g, a| [g + 255 - a, 255].min }
    assert_image gray(w, h, want), TIFF.decode(build(w, h, [premultiplied.flatten.pack("C*")], tags.merge(338 => 1))),
                 "associated gray alpha"
  end

  def test_ycbcr_luma_from_subsampled_data
    w = 13
    h = 7
    luma_values = random_bytes(w * h, seed: 16)
    [[2, 2], [2, 1], [1, 1], [4, 2], [1, 4]].each do |sh, sv|
      units = []
      (0...h).step(sv) do |y0|
        (0...w).step(sh) do |x0|
          ys = Array.new(sv) { |j| Array.new(sh) { |i| luma_values[[y0 + j, h - 1].min * w + [x0 + i, w - 1].min] } }
          units.concat(ys.flatten + [128, 128])
        end
      end
      data = units.pack("C*")
      tags = { 258 => [8] * 3, 262 => 6, 277 => 3, 530 => [sh, sv] }
      assert_image gray(w, h, luma_values), TIFF.decode(build(w, h, [data], tags)), "#{sh}x#{sv}"
      chunk = TiffFixtures::LzwEncoder.encode(data)
      assert_image gray(w, h, luma_values), TIFF.decode(build(w, h, [chunk], tags.merge(259 => 5))), "#{sh}x#{sv} LZW"
    end
    assert_raises(QrReader::ImageError) do
      TIFF.decode(build(w, h, ["\0".b * 300], { 258 => [8] * 3, 262 => 6, 277 => 3, 530 => [3, 3] }))
    end
  end

  def test_lab_lightness_and_default_photometric
    lab = random_bytes(5 * 3 * 3, seed: 17)
    want = lab.each_slice(3).map(&:first)
    assert_image gray(5, 3, want), TIFF.decode(build(5, 3, [lab.pack("C*")], { 258 => [8] * 3, 262 => 8, 277 => 3 }))
    # No PhotometricInterpretation: BlackIsZero for one sample, RGB for three.
    assert_image gray(5, 3, lab.first(15)), TIFF.decode(build(5, 3, [lab.first(15).pack("C*")], { 258 => 8 }))
    want = lab.each_slice(3).map { |r, g, b| luma(r, g, b) }
    assert_image gray(5, 3, want), TIFF.decode(build(5, 3, [lab.pack("C*")], { 258 => [8] * 3, 277 => 3 }))
  end

  # --- pages ------------------------------------------------------------------------------

  def page(width, value, tags = {})
    { tags: { 256 => width, 257 => 2, 258 => 8, 262 => 1 }.merge(tags), chunks: [[value].pack("C") * (width * 2)] }
  end

  def test_multi_page_api
    bytes = TiffFixtures.read("multipage_mixed.tif")
    assert_equal 3, TIFF.page_count(bytes)
    pages = TIFF.each_page(bytes)
    assert_kind_of Enumerator, pages
    assert_equal 3, pages.size
    images = pages.to_a
    assert_equal([[203, 157], [75, 53], [61, 45]], images.map { |i| [i.width, i.height] })
    assert_equal images[2].data, TIFF.decode(bytes, page: -1).data
    assert_equal images[1].data, TIFF.decode(bytes, page: 1).data
    assert_equal [61, 45], TIFF.dimensions(bytes, page: 2)
    [3, -4, "1", nil].each do |page|
      assert_raises(IndexError) { TIFF.decode(bytes, page: page) }
    end
    yielded = []
    assert_nil(TIFF.each_page(bytes) { |image| yielded << image.width })
    assert_equal [203, 75, 61], yielded
  end

  def test_pages_are_decoded_lazily
    bytes = Writer.build([page(4, 10), page(5, 20, 259 => 34_661)])
    assert_equal 2, TIFF.page_count(bytes)
    assert_equal 4, TIFF.each_page(bytes).first.width
    yielded = []
    error = assert_raises(QrReader::UnsupportedImageError) { TIFF.each_page(bytes) { |image| yielded << image } }
    assert_match(/JBIG/, error.message)
    assert_equal 1, yielded.size
  end

  def test_thumbnails_and_masks_are_not_pages
    bytes = Writer.build([page(4, 10), page(2, 99, 254 => 1), page(5, 20, 254 => 2), page(3, 0, 254 => 4)])
    assert_equal 2, TIFF.page_count(bytes)
    assert_equal [4, 5], TIFF.each_page(bytes).map(&:width)
    assert_equal 1, TIFF.page_count(Writer.build([page(2, 99, 254 => 1)])) # nothing else: use it
  end

  def test_directory_chains_with_loops_and_bad_offsets
    first_ifd = Writer.build([page(4, 10)]).unpack1("V", offset: 4)
    assert_equal 1, TIFF.page_count(Writer.build([page(4, 10).merge(next: first_ifd)])) # points to itself
    assert_equal 2, TIFF.page_count(Writer.build([page(4, 10), page(5, 10).merge(next: first_ifd)]))
    assert_equal 1, TIFF.page_count(Writer.build([page(4, 10).merge(next: 1 << 30)]))
    assert_equal 1, TIFF.page_count(Writer.build([page(4, 10).merge(next: 9)])) # not a directory
  end

  # --- errors -----------------------------------------------------------------------------

  def test_unsupported_variants
    {
      { 259 => 34_661 } => /JBIG/, { 259 => 50_000 } => /Zstandard/, { 259 => 34_712 } => /JPEG 2000/,
      { 259 => 12_345 } => /compression 12345/, { 262 => 32_845 } => /photometric/,
      { 339 => 3 } => /floating point/, { 317 => 5 } => /predictor/
    }.each do |tags, message|
      bytes = build(4, 2, ["\0".b * 16], { 258 => 16, 262 => 1 }.merge(tags))
      error = assert_raises(QrReader::UnsupportedImageError, tags.inspect) { TIFF.decode(bytes) }
      assert_match message, error.message
      assert_equal [4, 2], TIFF.dimensions(bytes)
    end
    assert_raises(QrReader::UnsupportedImageError) do
      TIFF.decode(build(4, 2, ["\0".b * 4], { 258 => 4, 262 => 1, 317 => 2 }))
    end
    assert_raises(QrReader::UnsupportedImageError) do
      TIFF.decode(build(4, 2, ["\0".b * 32], { 258 => [8, 16, 8], 262 => 2, 277 => 3 }))
    end
    assert_raises(QrReader::UnsupportedImageError) { TIFF.decode(build(1 << 15, 1 << 15, [], { 258 => 1 })) }
    assert_raises(QrReader::UnsupportedImageError) do
      TIFF.decode(build(16, 16, ["\0".b], { 258 => 8, 262 => 1, 322 => 1 << 16, 323 => 1 << 16 }, tiled: true))
    end
  end

  def test_corrupt_files_raise_image_error
    good = build(4, 2, ["\0".b * 8], { 258 => 8, 262 => 1 })
    [
      "", "II*\0", "XX*\0\x08\0\0\0".b, "II*\0\xFF\xFF\0\0".b, "II*\0\x08\0\0\0\0\0".b, "II+\0\x04\0\0\0".b + "\0" * 8,
      good.byteslice(0, good.bytesize - 20),
      build(4, 2, ["\0".b * 8], { 258 => 8, 262 => 1, 273 => nil, 279 => nil }), # no strip offsets
      build(0, 2, ["\0".b * 8], { 258 => 8, 262 => 1 }),
      build(4, 2, [], { 258 => 8, 262 => 1, 273 => [4, [0]] }), # no image data at all
      build(4, 2, ["\0".b * 8], { 258 => 8, 262 => 2, 277 => 1 }), # RGB with one sample
      build(4, 2, ["\0".b * 8], { 258 => 3, 259 => 4, 262 => 0 }), # CCITT needs 1 bit per sample
      build(4, 2, ["\0".b * 8], { 258 => 8, 262 => 1, 322 => 0, 323 => 16 }, tiled: true)
    ].each do |bytes|
      assert_raises(QrReader::ImageError, bytes.unpack1("H*")[0, 40]) { TIFF.decode(bytes) }
    end
    assert_raises(QrReader::ImageError) { TIFF.page_count("not a tiff") }
    assert_raises(QrReader::ImageError) { TIFF.decode(nil) }
  end

  FUZZ_FIXTURES = %w[bilevel_g4.tif bilevel_g3_2d_fill.tif bilevel_rle.tif gray_lzw_predictor.tif gray_tiles.tif
                     gray_jpeg.tif rgb_planar.tif palette4.tif gray_bigtiff.tif multipage_mixed.tif cmyk_lzw.tif
                     gray_float.tif rgba_zip.tif].freeze

  def test_mutated_files_decode_or_raise_image_error
    FUZZ_FIXTURES.each_with_index do |name, n|
      bytes = TiffFixtures.read(name)
      rng = Random.new(n)
      variants = Array.new(40) { |i| bytes.byteslice(0, i < 20 ? rng.rand(bytes.bytesize) : bytes.bytesize).dup }
      variants.each_with_index do |copy, i|
        next if i < 20

        (1 + rng.rand(4)).times do
          pos = rng.rand < 0.6 ? copy.bytesize - 1 - rng.rand([copy.bytesize, 400].min) : rng.rand(copy.bytesize)
          pos = rng.rand([copy.bytesize, 64].min) if rng.rand < 0.2
          copy.setbyte(pos, rng.rand(256))
        end
      end
      variants.each do |copy|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          TIFF.each_page(copy) { |image| assert_equal image.width * image.height, image.data.bytesize }
        rescue QrReader::ImageError
          # expected for corrupt input
        rescue StandardError => e
          flunk "#{name}: #{e.class}: #{e.message}\n#{e.backtrace.first(4).join("\n")}"
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :<, 2.0, "#{name} took #{elapsed.round(2)} s"
      end
    end
  end
end
