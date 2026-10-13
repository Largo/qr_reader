# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/images/format_fixtures"

class TestBMP < Minitest::Test
  include FormatFixtures::Assertions

  BMP = QrReader::Formats::BMP
  W = FormatFixtures::BmpWriter

  def decode(bytes)
    BMP.decode(bytes)
  end

  def luma(r, g, b)
    QrReader::Image.luma(r, g, b)
  end

  def over_white(v, a)
    (v * a + 255 * (255 - a) + 127) / 255
  end

  PALETTE = [[0, 0, 0], [255, 255, 255], [200, 30, 40], [10, 220, 90], [60, 70, 250], [128, 128, 128]].freeze

  FormatFixtures.names("bmp_").each do |name|
    define_method("test_fixture_#{name.delete_suffix('.bmp')}") do
      bytes = FormatFixtures.read(name)
      assert_same_image FormatFixtures.expected(name), decode(bytes), name
      entry = FormatFixtures.manifest[name]
      assert_equal [entry["width"], entry["height"]], BMP.dimensions(bytes)
    end
  end

  # rows of palette indices -> packed rows at +bpp+
  def pack_indices(rows, bpp)
    rows.map { |row| [row.map { |i| i.to_s(2).rjust(bpp, "0") }.join].pack("B*") }
  end

  def palette_luma(index, palette = PALETTE)
    rgb = palette[index] || [0, 0, 0]
    luma(*rgb)
  end

  def test_palette_depths_with_both_row_orders_and_header_types
    rows = Array.new(5) { |y| Array.new(11) { |x| (x * 3 + y) % 4 } }
    [1, 2, 4, 8].each do |bpp|
      pal = PALETTE.first(1 << [bpp, 2].min)
      data = bpp == 1 ? rows.map { |r| r.map { |i| i & 1 } } : rows
      want = data.flatten.map { |i| palette_luma(i, pal) }
      %i[info core os2_16 os2_64 v4 v5].each do |header|
        [false, true].each do |top_down|
          next if top_down && header == :core

          bmp = W.encode(width: 11, height: 5, bpp: bpp, rows: pack_indices(data, bpp), palette: pal,
                         header: header, top_down: top_down)
          assert_equal want, decode(bmp).data.bytes, "#{bpp} bpp #{header} top_down=#{top_down}"
        end
      end
    end
  end

  def test_short_palette_and_out_of_range_indices_are_black
    rows = [[0, 1, 2, 3, 4, 5, 6, 7, 200]]
    bmp = W.encode(width: 9, height: 1, bpp: 8, rows: [rows[0].pack("C*")], palette: PALETTE.first(3), colors_used: 3)
    assert_equal [0, 255, luma(200, 30, 40), 0, 0, 0, 0, 0, 0], decode(bmp).data.bytes
  end

  def test_bogus_data_offset_falls_back_to_after_the_palette
    bmp = W.encode(width: 2, height: 1, bpp: 8, rows: ["\x01\x02".b], palette: PALETTE.first(3), colors_used: 3)
    bmp[10, 4] = [0xFFFFFF].pack("V")
    assert_equal [255, luma(200, 30, 40)], decode(bmp).data.bytes
  end

  def test_24_bit_and_missing_final_padding
    rows = [[1, 2, 3, 250, 128, 0, 9, 9, 9], [0, 0, 0, 255, 255, 255, 40, 50, 60]]
    bmp = W.encode(width: 3, height: 2, bpp: 24, rows: rows.map { |r| r.pack("C*") })
    expected = rows.flatten.each_slice(3).map { |b, g, r| luma(r, g, b) }
    assert_equal expected, decode(bmp).data.bytes
    assert_equal expected, decode(bmp.byteslice(0, bmp.bytesize - 3)).data.bytes # last row's padding missing
    assert_raises(QrReader::ImageError) { decode(bmp.byteslice(0, bmp.bytesize - 4)) }
  end

  def test_16_bit_default_555_and_bitfields_565
    values = [0x0000, 0x7FFF, 0x7C00, 0x03E0, 0x001F, 0x1234]
    bmp = W.encode(width: 6, height: 1, bpp: 16, rows: [values.pack("v*")])
    widen5 = ->(v) { (v << 3) | (v >> 2) }
    expected = values.map { |v| luma(widen5.(v >> 10 & 31), widen5.(v >> 5 & 31), widen5.(v & 31)) }
    assert_equal expected, decode(bmp).data.bytes

    bmp = W.encode(width: 6, height: 1, bpp: 16, rows: [values.pack("v*")], compression: 3,
                   masks: [0xF800, 0x07E0, 0x001F])
    widen6 = ->(v) { (v << 2) | (v >> 4) }
    expected = values.map { |v| luma(widen5.(v >> 11 & 31), widen6.(v >> 5 & 63), widen5.(v & 31)) }
    assert_equal expected, decode(bmp).data.bytes
  end

  def test_32_bit_alpha_handling
    pixels = [[10, 20, 30, 255], [10, 20, 30, 0], [200, 100, 50, 128]] # B, G, R, A
    rows = [pixels.flatten.pack("C*")]
    with_alpha = pixels.map { |b, g, r, a| over_white(luma(r, g, b), a) }
    opaque = pixels.map { |b, g, r, _| luma(r, g, b) }
    # BI_RGB: the fourth byte is alpha (like browsers and ImageMagick)...
    assert_equal with_alpha, decode(W.encode(width: 3, height: 1, bpp: 32, rows: rows)).data.bytes
    # ...unless it is zero everywhere.
    zero = [pixels.map { |b, g, r, _| [b, g, r, 0] }.flatten.pack("C*")]
    assert_equal opaque, decode(W.encode(width: 3, height: 1, bpp: 32, rows: zero)).data.bytes
    # Bitfields without an alpha mask ignore the byte.
    bmp = W.encode(width: 3, height: 1, bpp: 32, rows: rows, compression: 3, masks: [0xFF0000, 0xFF00, 0xFF])
    assert_equal opaque, decode(bmp).data.bytes
    # BI_ALPHABITFIELDS (6) with four masks after an info header.
    bmp = W.encode(width: 3, height: 1, bpp: 32, rows: rows, compression: 6,
                   masks: [0xFF0000, 0xFF00, 0xFF, 0xFF000000])
    assert_equal with_alpha, decode(bmp).data.bytes
    # V3+ header with an alpha mask.
    bmp = W.encode(width: 3, height: 1, bpp: 32, rows: rows, compression: 3, header: :v3,
                   masks: [0xFF0000, 0xFF00, 0xFF, 0xFF000000])
    assert_equal with_alpha, decode(bmp).data.bytes
  end

  def test_unusual_masks
    # Swapped channels, a 2-bit alpha and 12-bit fields.
    px = (3 << 30) | (0x0AB << 18) | (0x0CD << 6) | 0x3F
    bmp = W.encode(width: 2, height: 1, bpp: 32, rows: [[px, px & ~(3 << 30)].pack("V*")], compression: 3,
                   header: :v5, masks: [0x3F, 0xFFF << 6, 0xFFF << 18, 3 << 30])
    r = 255 # 6 bits all set
    g = 0x0CD >> 4
    b = 0x0AB >> 4
    assert_equal [luma(r, g, b), 255], decode(bmp).data.bytes # alpha 0 on the second pixel
  end

  def test_bitfields_without_masks_use_the_defaults
    values = [0x7C00, 0x001F]
    bmp = W.encode(width: 2, height: 1, bpp: 16, rows: [values.pack("v*")], compression: 3, data_offset: 54)
    assert_equal [luma(255, 0, 0), luma(0, 0, 255)], decode(bmp).data.bytes
  end

  def rle(*bytes)
    bytes.flatten.pack("C*")
  end

  def test_rle8_runs_absolute_delta_and_early_end_of_line
    pal = PALETTE
    # Bottom-up: file line 0 is the bottom row.
    data = rle([3, 2], [0, 3, 1, 4, 5, 0], [0, 0], # run of 2s, absolute 1 4 5 (padded), EOL
               [0, 2, 1, 1], [2, 3], [0, 0],         # delta right 1/up 1, run
               [9, 1], [0, 1])                       # run clipped at the edge, end of bitmap
    bmp = W.encode(width: 6, height: 4, bpp: 8, data: data, palette: pal, compression: 1)
    l = ->(i) { palette_luma(i) }
    w = 255
    expected = [
      [l.(1)] * 6,                            # file line 3, run clipped at the edge
      [w, l.(3), l.(3), w, w, w],             # file line 2, after the delta
      [w] * 6,                                # file line 1, skipped by the delta
      [l.(2), l.(2), l.(2), l.(1), l.(4), l.(5)] # file line 0
    ]
    assert_equal expected.flatten, decode(bmp).data.bytes
    # The same data stored top-down.
    bmp = W.encode(width: 6, height: 4, bpp: 8, data: data, palette: pal, compression: 1, top_down: true)
    assert_equal expected.reverse.flatten, decode(bmp).data.bytes
  end

  def test_rle4_alternating_runs_and_odd_absolute_groups
    data = rle([5, 0x12], [0, 3, 0x34, 0x50], [0, 0], [0, 5, 0x11, 0x22, 0x30, 0], [1, 0x40], [0, 1])
    bmp = W.encode(width: 8, height: 2, bpp: 4, data: data, palette: PALETTE, compression: 2)
    l = ->(i) { palette_luma(i) }
    expected = [[l.(1), l.(1), l.(2), l.(2), l.(3), l.(4), 255, 255],
                [l.(1), l.(2), l.(1), l.(2), l.(1), l.(3), l.(4), l.(5)]]
    assert_equal expected.flatten, decode(bmp).data.bytes
  end

  def test_rle_missing_end_of_bitmap_after_last_row
    bmp = W.encode(width: 2, height: 1, bpp: 8, data: rle([2, 1], [0, 0]), palette: PALETTE, compression: 1)
    assert_equal [255, 255], decode(bmp).data.bytes
    truncated = W.encode(width: 2, height: 2, bpp: 8, data: rle([2, 1]), palette: PALETTE, compression: 1)
    assert_raises(QrReader::ImageError) { decode(truncated) }
    absolute = W.encode(width: 9, height: 1, bpp: 8, data: rle([0, 9, 1, 2]), palette: PALETTE, compression: 1)
    assert_raises(QrReader::ImageError) { decode(absolute) }
  end

  def test_unsupported_and_invalid_files
    base = W.encode(width: 1, height: 1, bpp: 24, rows: ["\0\0\0".b])
    {
      4 => QrReader::UnsupportedImageError, 5 => QrReader::UnsupportedImageError,
      11 => QrReader::UnsupportedImageError, 1 => QrReader::ImageError, 3 => QrReader::ImageError
    }.each do |compression, error|
      bmp = base.dup
      bmp[30, 4] = [compression].pack("V")
      assert_raises(error, "compression #{compression}") { decode(bmp) }
    end
    bmp = base.dup
    bmp[28, 2] = [64].pack("v")
    assert_raises(QrReader::UnsupportedImageError) { decode(bmp) }
    bmp = base.dup
    bmp[18, 4] = [-5].pack("l<")
    assert_raises(QrReader::ImageError) { decode(bmp) }
    bmp = base.dup
    bmp[14, 4] = [41].pack("V")
    assert_raises(QrReader::ImageError) { decode(bmp) }
    huge = base.dup
    huge[18, 8] = [50_000, 50_000].pack("l<l<")
    assert_raises(QrReader::UnsupportedImageError) { decode(huge) }
    os2_huffman = W.encode(width: 1, height: 1, bpp: 1, rows: ["\0".b], palette: PALETTE.first(2), header: :os2_64,
                           compression: 3)
    assert_raises(QrReader::UnsupportedImageError) { decode(os2_huffman) }
    assert_raises(QrReader::ImageError) { decode("BM") }
    assert_raises(QrReader::ImageError) { decode(base.byteslice(0, 30)) }
  end

  def test_fuzzed_fixtures_raise_only_image_errors
    names = FormatFixtures.names("bmp_").reject { |n| n.include?("medium") }
    names.each_with_index do |name, i|
      FormatFixtures.mutations(FormatFixtures.read(name), seed: i, truncations: 40, flips: 80).each do |bytes|
        assert_image_or_image_error(bytes) { |b| decode(b) }
      end
    end
  end
end
