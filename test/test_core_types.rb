# frozen_string_literal: true

require_relative "test_helper"

class TestSymbolVersion < Minitest::Test
  def test_dimensions_and_lookup
    assert_equal 21, QrReader::SymbolVersion[1].dimension
    assert_equal 177, QrReader::SymbolVersion[40].dimension
    assert_equal 7, QrReader::SymbolVersion.for_dimension(45).number
    assert_nil QrReader::SymbolVersion.for_dimension(46)
    assert_nil QrReader::SymbolVersion[41]
  end

  def test_ec_table_matches_codeword_capacity
    1.upto(40) do |n|
      v = QrReader::SymbolVersion[n]
      QrReader::SymbolVersion::EC_LEVELS.each do |level|
        b = v.ec_blocks(level)
        total = b.groups.sum { |count, data| count * (data + b.ec_codewords_per_block) }
        assert_equal v.total_codewords, total, "version #{n} level #{level}"
      end
    end
  end

  def test_ec_table_matches_rqrcode_core
    table = RQRCodeCore::QRRSBlock::RS_BLOCK_TABLE
    # rqrcode_core order per version: L, M, Q, H; each [count, total, data(, count, total, data)]
    1.upto(40) do |n|
      %i[L M Q H].each_with_index do |level, li|
        row = table[(n - 1) * 4 + li]
        expected = row.each_slice(3).map { |count, total, data| [count, data, total - data] }
        b = QrReader::SymbolVersion[n].ec_blocks(level)
        actual = b.groups.map { |count, data| [count, data, b.ec_codewords_per_block] }
        assert_equal expected, actual, "version #{n} level #{level}"
      end
    end
  end

  def test_alignment_centers_match_rqrcode_core
    1.upto(40) do |n|
      assert_equal RQRCodeCore::QRUtil::PATTERN_POSITION_TABLE[n - 1], QrReader::SymbolVersion[n].alignment_centers, "version #{n}"
    end
  end

  def test_version_info
    assert_equal 0x07C94, QrReader::SymbolVersion[7].version_info_bits
    assert_equal 0x28C69, QrReader::SymbolVersion[40].version_info_bits
    assert_equal 7, QrReader::SymbolVersion.decode_version_info(0x07C94 ^ 0b101).number
    assert_nil QrReader::SymbolVersion.decode_version_info(0x07C94 ^ 0b1111)
  end
end

class TestFormatInformation < Minitest::Test
  def test_encode_known_values
    # ISO 18004 Annex C example: EC level M (00), mask 101 -> 100000011001110
    assert_equal 0b100000011001110, QrReader::FormatInformation.encode(0b00101)
  end

  def test_decode_with_errors
    info = QrReader::FormatInformation::ALL[0b01011] # L, mask 3
    assert_equal :L, info.ec_level
    assert_equal 3, info.mask
    assert_equal info, QrReader::FormatInformation.decode(info.bits ^ 0b100000100000001)
    assert_equal info, QrReader::FormatInformation.decode(0, info.bits ^ 0b11)
    assert_nil QrReader::FormatInformation.decode(info.bits ^ 0b111100000000000, info.bits ^ 0b000000000001111)
  end

  def test_unmasked_variant
    info = QrReader::FormatInformation::ALL[0b10110]
    assert_equal info, QrReader::FormatInformation.decode(info.bits ^ QrReader::FormatInformation::MASK)
  end
end

class TestImage < Minitest::Test
  def test_from_pixels_and_rotation
    img = QrReader::Image.from_pixels(2, 1, "\xff\x00\x00\xff\x00\x00\x00\x00".b, :rgba)
    assert_equal [76, 255], [img[0, 0], img[1, 0]]
    rgb = QrReader::Image.from_rgb(3, 2, ([255, 255, 255] * 3 + [0, 0, 0] * 3).pack("C*"))
    assert_equal [255, 0], [rgb[0, 0], rgb[0, 1]]
    r = rgb.rotate90
    assert_equal [2, 3], [r.width, r.height]
    assert_equal 0, r[0, 0]
    assert_equal 255, r[1, 0]
    assert_equal rgb.data, r.rotate270.data
    assert_equal rgb.data, rgb.rotate180.rotate180.data
    assert_equal rgb.data, r.rotate90.rotate90.rotate90.data
    assert_equal [0, 255], [rgb.invert[0, 0], rgb.invert[0, 1]]
  end

  def test_downscale_and_crop
    img = QrReader::Image.new(4, 4, (0...16).map { |i| i * 10 }.pack("C*"))
    small = img.downscale(2)
    assert_equal [2, 2], [small.width, small.height]
    assert_equal (0 + 10 + 40 + 50 + 2) / 4, small[0, 0]
    c = img.crop(1, 1, 2, 2)
    assert_equal [50, 60, 90, 100], c.data.bytes
    assert_equal [30, 20, 10, 0], img.mirror.row(0).bytes
  end
end

class TestBitMatrix < Minitest::Test
  def test_basic_ops
    m = QrReader::BitMatrix.from_rows(["#.", ".."])
    assert m.dark?(0, 0)
    refute m.dark?(1, 0)
    m.flip(1, 1)
    assert_equal 2, m.dark_count
    t = QrReader::BitMatrix.from_rows(["##", ".."]).transpose
    assert t.dark?(0, 1)
    refute t.dark?(1, 0)
    assert_equal 2, m.invert.dark_count
  end
end
