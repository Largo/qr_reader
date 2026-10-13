# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/images/format_fixtures"

class TestPNM < Minitest::Test
  include FormatFixtures::Assertions

  PNM = QrReader::Formats::PNM

  def decode(bytes)
    PNM.decode(bytes)
  end

  def luma(r, g, b)
    QrReader::Image.luma(r, g, b)
  end

  def over_white(v, a)
    a == 255 ? v : (v * a + 255 * (255 - a) + 127) / 255
  end

  def scale(v, max)
    v >= max ? 255 : (v * 255 + max / 2) / max
  end

  FormatFixtures.names("pnm_").concat(FormatFixtures.names("pam_")).each do |name|
    define_method("test_fixture_#{name.sub('.', '_')}") do
      bytes = FormatFixtures.read(name)
      assert_same_image FormatFixtures.expected(name), decode(bytes), name
      entry = FormatFixtures.manifest[name]
      assert_equal [entry["width"], entry["height"]], PNM.dimensions(bytes)
    end
  end

  def test_plain_bitmap_with_comments_and_without_separators
    pbm = "P1\n# size\n3 2\n1 0\n1#x\n010\n".b
    assert_equal [0, 255, 0, 255, 0, 255], decode(pbm).data.bytes
    assert_equal [0, 255, 0, 255, 0, 255], decode("P1 3 2 101010".b).data.bytes
  end

  def test_packed_bitmap_rows_are_byte_aligned
    pbm = "P4\n10 2\n".b + [0b10000000, 0b01000000, 0b11111111, 0b11000000].pack("C*")
    assert_equal [0, 255, 255, 255, 255, 255, 255, 255, 255, 0] + [0] * 10, decode(pbm).data.bytes
  end

  def test_gray_maxvals
    [1, 3, 100, 255].each do |max|
      values = [0, max / 2, max, 1].map { |v| [v, max].min }
      expected = values.map { |v| scale(v, max) }
      assert_equal expected, decode("P5 4 1 #{max}\n".b + values.pack("C*")).data.bytes, "P5 #{max}"
      assert_equal values.map { |v| scale(v, max) }, decode("P2 4 1 #{max}\n#{values.join(' ')}\n".b).data.bytes,
                   "P2 #{max}"
    end
    [256, 1000, 4095].each do |max|
      values = [0, max / 3, max, 1]
      assert_equal values.map { |v| scale(v, max) }, decode("P5 4 1 #{max}\n".b + values.pack("n*")).data.bytes,
                   "P5 #{max}"
    end
    values = [0x0000, 0x12FF, 0xFFFF, 0x80FE]
    assert_equal [0x00, 0x12, 0xFF, 0x80], decode("P5 4 1 65535\n".b + values.pack("n*")).data.bytes
  end

  def test_values_above_maxval_saturate
    assert_equal [255, 255, 128], decode("P5 3 1 100\n".b + [101, 255, 50].pack("C*")).data.bytes
    assert_equal [255, 255], decode("P2 2 1 100\n101 99999999999999999999\n".b).data.bytes
    assert_equal [255], decode("P5 1 1 1000\n".b + [4000].pack("n")).data.bytes
  end

  def test_color
    rgb = [[255, 0, 0], [0, 255, 0], [10, 20, 30]]
    expected = rgb.map { |c| luma(*c) }
    assert_equal expected, decode("P6 3 1 255\n".b + rgb.flatten.pack("C*")).data.bytes
    assert_equal expected, decode("P3 3 1 255 #{rgb.flatten.join(' ')}".b).data.bytes
    assert_equal expected, decode("P6 3 1 65535\n".b + rgb.flatten.map { |v| v * 257 }.pack("n*")).data.bytes
    assert_equal expected, decode("P3 3 1 65535\n#{rgb.flatten.map { |v| v * 257 }.join("\n")}".b).data.bytes
  end

  def test_comments_everywhere_in_the_header
    raster = [1, 2, 3, 4].pack("C*")
    headers = ["P5#a\n2 2 255\n", "P5\n#a\n#b\n2#c\n2#d\n255\n", "P5 2\t2\r255\n", "P5\n2 # x y z\n2\n# 99\n255 "]
    headers.each do |header|
      assert_equal [1, 2, 3, 4], decode(header.b + raster).data.bytes, header.inspect
      assert_equal [2, 2], PNM.dimensions(header.b + raster)
    end
  end

  def test_raster_starts_after_exactly_one_whitespace_byte
    assert_equal [10, 32], decode("P5 2 1 255\n\n ".b).data.bytes
  end

  def test_only_the_first_image_is_read
    two = "P5 1 1 255\n\x07P5 1 1 255\n\x09".b
    assert_equal [7], decode(two).data.bytes
  end

  def pam(width:, height:, depth:, maxval:, type: nil, raster: "", extra: "")
    header = "P7\n#{extra}WIDTH #{width}\nHEIGHT #{height}\nDEPTH #{depth}\nMAXVAL #{maxval}\n"
    header += "TUPLTYPE #{type}\n" if type
    (header + "ENDHDR\n").b + raster.b
  end

  def test_pam_tuple_types
    assert_equal [0, 255], decode(pam(width: 2, height: 1, depth: 1, maxval: 1, type: "BLACKANDWHITE",
                                      raster: "\x00\x01")).data.bytes
    assert_equal [255, 0, over_white(255, 255)],
                 decode(pam(width: 3, height: 1, depth: 2, maxval: 1, type: "BLACKANDWHITE_ALPHA",
                            raster: "\x00\x00\x00\x01\x01\x01")).data.bytes
    assert_equal [over_white(100, 128), 255],
                 decode(pam(width: 2, height: 1, depth: 2, maxval: 255, type: "GRAYSCALE_ALPHA",
                            raster: [100, 128, 7, 0].pack("C*"))).data.bytes
    assert_equal [over_white(100, 128)],
                 decode(pam(width: 1, height: 1, depth: 2, maxval: 65_535, type: "GRAYSCALE_ALPHA",
                            raster: [100 * 257, 128 * 257].pack("n*"))).data.bytes
    assert_equal [luma(1, 2, 3)], decode(pam(width: 1, height: 1, depth: 3, maxval: 255, type: "RGB",
                                             raster: "\x01\x02\x03")).data.bytes
    assert_equal [over_white(luma(9, 8, 7), 200)],
                 decode(pam(width: 1, height: 1, depth: 4, maxval: 255, type: "RGB_ALPHA",
                            raster: "\x09\x08\x07\xC8")).data.bytes
  end

  def test_pam_tuple_type_inferred_from_depth
    rgb = pam(width: 1, height: 1, depth: 3, maxval: 255, raster: "\x01\x02\x03")
    assert_equal [luma(1, 2, 3)], decode(rgb).data.bytes
    # Several TUPLTYPE lines are joined; an unknown type with depth 2 is gray + alpha.
    split = pam(width: 1, height: 1, depth: 2, maxval: 255, type: "MY\nTUPLTYPE TYPE", raster: "\x05\x80")
    assert_equal [over_white(5, 128)], decode(split).data.bytes
  end

  def test_pam_header_variants
    crlf = "P7\r\n# c\r\nWIDTH 1\r\nHEIGHT 1\r\nDEPTH 1\r\nMAXVAL 255\r\nENDHDR\r\n\x05".b
    assert_equal [5], decode(crlf).data.bytes
    lower = "P7\nwidth 1\nheight 1\ndepth 1\nmaxval 255\nendhdr\n\x06".b
    assert_equal [6], decode(lower).data.bytes
    unknown_type = pam(width: 1, height: 1, depth: 3, maxval: 255, type: "SOMETHING", raster: "\x01\x02\x03")
    assert_equal [luma(1, 2, 3)], decode(unknown_type).data.bytes
  end

  def test_unsupported_and_invalid
    assert_raises(QrReader::UnsupportedImageError) do
      decode(pam(width: 1, height: 1, depth: 4, maxval: 255, type: "CMYK", raster: "\0\0\0\0"))
    end
    assert_raises(QrReader::UnsupportedImageError) { decode(pam(width: 1, height: 1, depth: 5, maxval: 255, raster: "\0" * 5)) }
    assert_raises(QrReader::ImageError) { decode(pam(width: 1, height: 1, depth: 2, maxval: 255, type: "RGB", raster: "\0\0")) }
    assert_raises(QrReader::UnsupportedImageError) { decode("P7 332\n#XVVERSION:Version 2.28\n".b) }
    assert_raises(QrReader::ImageError) { decode("P7\nWIDTH 1\nHEIGHT 1\nENDHDR\n\0".b) }
    assert_raises(QrReader::ImageError) { decode("P7\nWIDTH 1\nHEIGHT 1\nDEPTH 1\nMAXVAL 255\n".b) }
    assert_raises(QrReader::ImageError) { decode("P5 1 1 0\n\0".b) }
    assert_raises(QrReader::ImageError) { decode("P5 1 1 65536\n\0\0".b) }
    assert_raises(QrReader::ImageError) { decode("P5 1 1 255".b) }
    assert_raises(QrReader::ImageError) { decode("P5 1 1 255\n".b) }
    assert_raises(QrReader::ImageError) { decode("P5 2 2 255\n\0\0\0".b) }
    assert_raises(QrReader::ImageError) { decode("P6 1 1 65535\n\0\0\0\0\0".b) }
    assert_raises(QrReader::ImageError) { decode("P2 2 1 255\n1".b) }
    assert_raises(QrReader::ImageError) { decode("P1 2 2 1 0 1".b) }
    assert_raises(QrReader::ImageError) { decode("P1 2 1 1 2".b) }
    assert_raises(QrReader::ImageError) { decode("P4 9 1\n\0".b) }
    assert_raises(QrReader::ImageError) { decode("P5 0 1 255\n".b) }
    assert_raises(QrReader::ImageError) { decode("P5 x 1 255\n\0".b) }
    assert_raises(QrReader::ImageError) { decode("P5 12345678901 1 255\n\0".b) }
    assert_raises(QrReader::UnsupportedImageError) { decode("P5 100000 100000 255\n".b) }
    assert_raises(QrReader::ImageError) { decode("P8 1 1 255\n\0".b) }
  end

  def test_pathological_header_does_not_backtrack
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(QrReader::ImageError) { decode("P5 #{"# # #\n" * 20_000} x".b) }
    assert_raises(QrReader::ImageError) { decode("P5#{' ' * 200_000}x".b) }
    assert_raises(QrReader::ImageError) { decode("P7\n#{"# a b\n" * 20_000}".b) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 1.0
  end

  def test_fuzzed_fixtures_raise_only_image_errors
    names = (FormatFixtures.names("pnm_") + FormatFixtures.names("pam_")).reject { |n| n.include?("medium") }
    names.each_with_index do |name, i|
      FormatFixtures.mutations(FormatFixtures.read(name), seed: i, truncations: 40, flips: 80).each do |bytes|
        assert_image_or_image_error(bytes) { |b| decode(b) }
      end
    end
  end
end
