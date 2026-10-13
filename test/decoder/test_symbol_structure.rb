# frozen_string_literal: true

require_relative "decoder_test_helper"

# Function patterns, codeword placement, block layout, format and version
# information reading.
class TestDecoderSymbolStructure < Minitest::Test
  include DecoderTestHelper

  Decoder = QrReader::Decoder

  def test_function_patterns_leave_exactly_the_data_modules
    1.upto(40) do |v|
      version = QrReader::SymbolVersion[v]
      grid = Decoder::FunctionPatterns.for_version(v)
      n = version.dimension
      assert_equal n * n, grid.bytesize
      assert_equal QrReader::SymbolVersion.raw_data_modules(v), grid.count("\x00"), "version #{v}"
      assert grid.frozen?
      assert_same grid, Decoder::FunctionPatterns.for_version(v)
    end
  end

  def test_function_patterns_match_rqrcode_layout
    # rqrcode's QRCode#modules before data placement marks function modules
    # as non-nil; compare via a symbol whose data modules are all light under
    # mask 0 vs. mask 1: data modules differ for some mask, function modules never.
    [1, 2, 7, 14, 40].each do |v|
      qr = RQRCodeCore::QRCode.new("1", level: :l, size: v)
      common = qr.instance_variable_get(:@common_patterns)
      n = 17 + 4 * v
      grid = Decoder::FunctionPatterns.for_version(v)
      n.times do |y|
        n.times do |x|
          next unless common[y][x].nil? # finder/alignment/timing are set; format/version areas are not yet

          in_format = (x == 8 && (y <= 8 || y >= n - 8)) || (y == 8 && (x <= 8 || x >= n - 8))
          in_version = v >= 7 && ((y < 6 && x.between?(n - 11, n - 9)) || (x < 6 && y.between?(n - 11, n - 9)))
          assert_equal (in_format || in_version) ? 1 : 0, grid.getbyte(y * n + x), "v#{v} (#{x},#{y})"
        end
      end
    end
  end

  def test_placement_order_covers_data_modules_once
    [1, 6, 7, 21, 40].each do |v|
      layout = Decoder::Codewords.layout(v)
      version = QrReader::SymbolVersion[v]
      assert_equal version.total_codewords * 8, layout.order.size
      assert_equal layout.order.size, layout.order.uniq.size
      grid = Decoder::FunctionPatterns.for_version(v)
      assert(layout.order.all? { |i| grid.getbyte(i).zero? })
      n = version.dimension
      # first codeword starts in the bottom-right corner, going up
      assert_equal [(n - 1) * n + n - 1, (n - 1) * n + n - 2, (n - 2) * n + n - 1], layout.order.first(3)
      assert_equal(layout.order.map { |i| (i % n) * n + i / n }, layout.mirrored_order)
    end
  end

  def test_codewords_read_from_rqrcode_symbols
    rng = Random.new(10)
    [[1, :M], [2, :L], [5, :H], [7, :Q], [12, :M], [26, :L], [33, :H], [40, :Q]].each_with_index do |(v, level), i|
      mask = i % 8
      text = payload(rng, :byte_8bit, rng.rand(1..capacity(v, level, :byte_8bit)))
      matrix = rqr(text, version: v, level: level, mask: mask, mode: :byte_8bit)
      qr = FixedMaskQRCode.new(text, mask: mask, level: level.downcase, size: v, mode: :byte_8bit)
      expected = RQRCodeCore::QRCode.create_data(v, RQRCodeCore::QRERRORCORRECTLEVEL[level.downcase],
                                                 qr.instance_variable_get(:@data_list))
      expected = expected.map { |cw| cw || 0 } # rqrcode leaves a zero EC coefficient as nil (placed as 0)
      assert_equal expected, Decoder::Codewords.read(matrix, v, mask), "v#{v} #{level} mask #{mask}"
      assert_equal expected, Decoder::Codewords.read(matrix.transpose, v, mask, mirrored: true)
      ec = QrReader::SymbolVersion[v].ec_blocks(level).ec_codewords_per_block
      blocks = Decoder::Codewords.deinterleave(expected, v, level)
      assert_equal QrReader::SymbolVersion[v].ec_blocks(level).block_count, blocks.size
      blocks.each { |block| assert_nil Decoder::ReedSolomon.syndromes(block, ec) }
    end
  end

  def test_block_layout_deinterleaves
    1.upto(40) do |v|
      %i[L M Q H].each do |level|
        ec_blocks = QrReader::SymbolVersion[v].ec_blocks(level)
        blocks = Decoder::Codewords.layout(v).blocks(level)
        assert_equal ec_blocks.data_codewords_per_block, blocks.map(&:first)
        all = blocks.flat_map(&:last)
        assert_equal (0...QrReader::SymbolVersion[v].total_codewords).to_a, all.sort
        blocks.each { |count, indices| assert_equal count + ec_blocks.ec_codewords_per_block, indices.size }
      end
    end
    # Version 5-Q: 2 blocks of 15 and 2 of 16 data codewords, 18 EC each.
    blocks = Decoder::Codewords.layout(5).blocks(:Q)
    assert_equal [0, 4, 8], blocks[0][1].first(3)
    assert_equal [3, 7, 11], blocks[3][1].first(3)
    assert_equal 60, blocks[2][1][15]  # the extra data codeword of a long block comes last
    assert_equal 62, blocks[0][1][15]  # ... followed by the first EC codewords
  end

  def test_format_bits_read_both_copies
    %i[L M Q H].each_with_index do |level, li|
      8.times do |mask|
        next unless (li + mask).even?

        m = rqr("FORMAT", version: 3, level: level, mask: mask, mode: :alphanumeric)
        bits = Decoder::FormatReader.format_bits(m.bits, m.width)
        expected = QrReader::FormatInformation.decode(bits[0])
        assert_equal level, expected.ec_level
        assert_equal mask, expected.mask
        assert_equal bits[0], bits[1]
        assert_equal [expected, 0], Decoder::FormatReader.decode_format(*bits)
        assert_equal bits, Decoder::FormatReader.format_bits(m.transpose.bits, m.width, mirrored: true)
      end
    end
  end

  def test_fast_format_decoding_matches_core
    rng = Random.new(11)
    codes = QrReader::FormatInformation::ALL.map(&:bits)
    samples = Array.new(4000) { [rng.rand(1 << 15), rng.rand(1 << 15)] }
    samples += Array.new(4000) do
      a = codes.sample(random: rng) ^ (1 << rng.rand(15)) ^ (1 << rng.rand(15)) ^ (rng.rand(2) << rng.rand(15))
      b = rng.rand(3).zero? ? a : codes.sample(random: rng) ^ rng.rand(1 << 15) & rng.rand(1 << 15) & rng.rand(1 << 15)
      [a, b]
    end
    samples += Array.new(500) { [codes.sample(random: rng) ^ 0x5412 ^ (1 << rng.rand(15)), rng.rand(1 << 15)] }
    samples.each do |a, b|
      expected = QrReader::FormatInformation.decode(a, b)
      actual = Decoder::FormatReader.decode_format(a, b)&.first
      assert expected == actual, format("%015b %015b: expected %p, got %p", a, b, expected, actual)
    end
  end

  def test_version_bits_read_both_copies
    [7, 8, 21, 32, 40].each do |v|
      m = rqr("V", version: v, level: :L, mask: 0)
      copies = Decoder::FormatReader.version_bits(m.bits, m.width)
      assert_equal [QrReader::SymbolVersion[v].version_info_bits] * 2, copies
      assert_equal copies, Decoder::FormatReader.version_bits(m.transpose.bits, m.width, mirrored: true)
    end
  end

  def test_fast_version_decoding_matches_core
    rng = Random.new(12)
    codes = (7..40).map { |v| QrReader::SymbolVersion[v].version_info_bits }
    words = Array.new(3000) { rng.rand(1 << 18) }
    words += Array.new(3000) { codes.sample(random: rng) ^ (1 << rng.rand(18)) ^ (1 << rng.rand(18)) ^ (rng.rand(2) << rng.rand(18)) }
    words += Array.new(1000) { codes.sample(random: rng) ^ rng.rand(1 << 18) & rng.rand(1 << 18) & rng.rand(1 << 18) }
    words += codes
    words.each do |word|
      expected = QrReader::SymbolVersion.decode_version_info(word)&.number
      actual = Decoder::FormatReader.decode_version(word)
      assert expected == actual, format("%018b: expected %p, got %p", word, expected, actual)
    end
  end

  def test_data_mask_patterns
    # ISO/IEC 18004 Figure 10: first row/column samples of each pattern (i = row, j = column).
    assert QrReader::Decoder::DataMask.masked?(0, 0, 0)
    refute QrReader::Decoder::DataMask.masked?(0, 1, 0)
    refute QrReader::Decoder::DataMask.masked?(1, 0, 1)
    assert QrReader::Decoder::DataMask.masked?(2, 3, 1)
    assert QrReader::Decoder::DataMask.masked?(3, 1, 2)
    assert QrReader::Decoder::DataMask.masked?(4, 2, 1)
    refute QrReader::Decoder::DataMask.masked?(4, 3, 0)
    8.times do |mask|
      30.times do |y|
        30.times do |x|
          assert_equal SymbolBuilderMasks.masked?(mask, y, x), QrReader::Decoder::DataMask.masked?(mask, x, y)
        end
      end
    end
    assert_raises(ArgumentError) { QrReader::Decoder::DataMask.masked?(8, 0, 0) }
  end

  SymbolBuilderMasks = DecoderTestHelper::SymbolBuilder
end
