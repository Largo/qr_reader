# frozen_string_literal: true

require_relative "decoder_test_helper"

# Damaged and random input: correct up to the error correction capacity,
# beyond it return nil or the correct text - never wrong text - and never
# raise.
class TestDecoderRobustness < Minitest::Test
  include DecoderTestHelper

  Decoder = QrReader::Decoder

  # Raw (interleaved) codeword indices of each RS block, derived like the
  # builder's interleaving.
  def block_indices(version, level)
    blocks = QrReader::SymbolVersion[version].ec_blocks(level)
    counts = blocks.data_codewords_per_block
    indices = counts.map { [] }
    raw = 0
    counts.max.times do |i|
      counts.each_with_index do |count, b|
        next if i >= count

        indices[b] << raw
        raw += 1
      end
    end
    blocks.ec_codewords_per_block.times { indices.each { |list| (list << raw) && raw += 1 } }
    indices
  end

  # A symbol with a random alphanumeric payload; returns [text, data codewords].
  def random_payload(rng, version, level)
    text = payload(rng, :alphanumeric, rng.rand(1..capacity(version, level, :alphanumeric)))
    data = BitWriter.new.alphanumeric(text, version).to_data(QrReader::SymbolVersion[version].data_codewords(level))
    [text, data]
  end

  # Corrupts +per_block+ (Integer or Proc returning one per block) random
  # codewords in every block.
  def corrupter(version, level, rng, per_block)
    blocks = block_indices(version, level)
    lambda do |codewords|
      blocks.each do |indices|
        count = per_block.is_a?(Proc) ? per_block.call(indices.size) : per_block
        indices.sample(count, random: rng).each { |i| codewords[i] ^= rng.rand(1..255) }
      end
    end
  end

  CASES = [[1, :L], [1, :M], [1, :Q], [1, :H], [2, :L], [3, :Q], [5, :H], [7, :M], [9, :L], [12, :Q],
           [16, :H], [23, :M], [31, :L]].freeze

  def test_corrects_errors_up_to_capacity_in_every_block
    rng = Random.new(50)
    CASES.each do |version, level|
      t = QrReader::SymbolVersion[version].ec_blocks(level).ec_codewords_per_block / 2
      blocks = block_indices(version, level).size
      [t, rng.rand(1..t)].each_with_index do |errors, i|
        text, data = random_payload(rng, version, level)
        matrix = SymbolBuilder.build(data, version: version, level: level, mask: (version + i) % 8,
                                           corrupt: corrupter(version, level, rng, errors))
        result = Decoder.decode(matrix)
        refute_nil result, "v#{version} #{level} #{errors} errors per block"
        assert_equal text, result.text
        assert_equal errors * blocks, result.errors_corrected
      end
    end
  end

  def test_beyond_capacity_never_gives_wrong_text
    rng = Random.new(51)
    outcomes = Hash.new(0)
    CASES.first(9).each do |version, level|
      t = QrReader::SymbolVersion[version].ec_blocks(level).ec_codewords_per_block / 2
      30.times do |i|
        text, data = random_payload(rng, version, level)
        extra = ->(_size) { rng.rand(2).zero? ? t : t + 1 + rng.rand(4) }
        matrix = SymbolBuilder.build(data, version: version, level: level, mask: i % 8,
                                           corrupt: corrupter(version, level, rng, extra))
        result = Decoder.decode(matrix)
        outcomes[result ? :decoded : :rejected] += 1
        assert_equal text, result.text, "v#{version} #{level} seed #{i}" if result
      end
    end
    assert_operator outcomes[:rejected], :>, 0
  end

  def test_random_module_noise_never_gives_wrong_text
    rng = Random.new(52)
    outcomes = Hash.new(0)
    [[1, :L], [1, :H], [2, :M], [4, :Q], [6, :L], [8, :H]].each do |version, level|
      text, data = random_payload(rng, version, level)
      clean = SymbolBuilder.build(data, version: version, level: level, mask: version % 8)
      cells = (0...clean.bits.bytesize).to_a
      150.times do
        noisy = flip_modules(clean, cells, rng.rand(1..cells.size / 6), rng)
        result = Decoder.decode(noisy)
        outcomes[result ? :decoded : :rejected] += 1
        assert_equal text, result.text if result
      end
    end
    assert_operator outcomes[:decoded], :>, 0
    assert_operator outcomes[:rejected], :>, 0
  end

  def test_damaged_format_information
    rng = Random.new(53)
    text, data = random_payload(rng, 4, :Q)
    clean = SymbolBuilder.build(data, version: 4, level: :Q, mask: 5)
    n = clean.width
    copy1 = [[0, 8], [1, 8], [2, 8], [3, 8], [4, 8], [5, 8], [7, 8], [8, 8], [8, 7], [8, 5], [8, 4], [8, 3], [8, 2],
             [8, 1], [8, 0]]
    copy2 = (0..6).map { |k| [8, n - 1 - k] } + (0..7).map { |k| [n - 8 + k, 8] }
    damage = lambda do |matrix, coords, count|
      coords.sample(count, random: rng).each { |x, y| matrix.flip(x, y) }
      matrix
    end
    # one copy destroyed (all bits random), the other intact
    [copy1, copy2].each do |coords|
      20.times do
        m = clean.dup
        coords.each { |x, y| m.set(x, y, rng.rand(2)) }
        assert_equal text, Decoder.decode(m).text
      end
    end
    # up to 3 errors in both copies
    20.times do
      m = damage.call(damage.call(clean.dup, copy1, rng.rand(0..3)), copy2, rng.rand(0..3))
      assert_equal text, Decoder.decode(m).text
    end
    # both copies replaced by a far-away word: format_info failure
    far = (0...(1 << 15)).find { |w| QrReader::FormatInformation.decode(w).nil? }
    broken = SymbolBuilder.build(data, version: 4, level: :Q, mask: 5, format_bits: far)
    assert_nil Decoder.decode(broken)
    assert_equal :format_info, Decoder.diagnose(broken, try_mirrored: false)[:status]
  end

  def test_damaged_version_information
    rng = Random.new(54)
    [7, 18, 40].each do |version|
      text, data = random_payload(rng, version, :L)
      clean = SymbolBuilder.build(data, version: version, level: :L, mask: 2)
      n = clean.width
      top_right = (0...18).map { |i| [n - 11 + i % 3, i / 3] }
      bottom_left = (0...18).map { |i| [i / 3, n - 11 + i % 3] }
      [top_right, bottom_left].each do |coords|
        m = clean.dup
        coords.each { |x, y| m.set(x, y, rng.rand(2)) }
        assert_equal text, Decoder.decode(m).text, "v#{version}: one copy destroyed"
      end
      # both unreadable (all light: far from every version code) -> dimension fallback
      m = clean.dup
      (top_right + bottom_left).each { |x, y| m.unset(x, y) }
      assert_nil QrReader::SymbolVersion.decode_version_info(0)
      assert_equal text, Decoder.decode(m).text, "v#{version}: both unreadable"
      # 3 errors in each copy
      m = clean.dup
      top_right.sample(3, random: rng).each { |x, y| m.flip(x, y) }
      bottom_left.sample(3, random: rng).each { |x, y| m.flip(x, y) }
      assert_equal text, Decoder.decode(m).text
      # both copies name another version: reject
      other = SymbolBuilder.build(data, version: version, level: :L, mask: 2,
                                        version_bits: QrReader::SymbolVersion[version == 40 ? 39 : version + 1].version_info_bits)
      assert_nil Decoder.decode(other)
      assert_equal :version_info, Decoder.diagnose(other)[:status]
    end
  end

  # Random module grids: mostly rejected early, never an exception.
  def test_fuzz_random_matrices
    rng = Random.new(55)
    dims = [21, 21, 21, 21, 25, 25, 29, 33, 45, 57, 101, 177]
    # byte ranges mapped to dark for densities 1/2, 1/8 and 7/8
    dark_ranges = ["\x80-\xFF", "\x00-\x1F", "\x20-\xFF"].map(&:b)
    decoded = 0
    12_000.times do |i|
      n = dims[i % dims.size]
      bits = rng.bytes(n * n).tr(dark_ranges[i % 3], "\x01").tr("^\x01".b, "\x00")
      decoded += 1 if Decoder.decode(QrReader::BitMatrix.new(n, n, bits))
    end
    assert_operator decoded, :<, 3
  end

  # Grids with valid function patterns and format information around random
  # codewords: exercises Reed-Solomon on garbage.
  def test_fuzz_random_codewords
    rng = Random.new(56)
    templates = [[1, :L], [1, :H], [2, :M], [3, :Q], [5, :L], [7, :H], [10, :M]].map do |version, level|
      [version, level, SymbolBuilder.build("\0".b * QrReader::SymbolVersion[version].data_codewords(level),
                                           version: version, level: level, mask: 0)]
    end
    decoded = 0
    10_000.times do |i|
      version, _level, template = templates[i % templates.size]
      matrix = template.dup
      order = Decoder::Codewords.layout(version).order
      random = rng.bytes(order.size)
      order.each_with_index { |index, k| matrix.bits.setbyte(index, random.getbyte(k) & 1) }
      decoded += 1 if Decoder.decode(matrix)
    end
    assert_operator decoded, :<, 3
  end

  # Valid RS codewords around random data: exercises the bit stream parser on
  # garbage. Whatever decodes must have valid UTF-8 text.
  def test_fuzz_random_data_with_valid_error_correction
    rng = Random.new(57)
    parsed = 0
    1500.times do |i|
      version = [1, 1, 2, 3, 4, 6, 7, 10][i % 8]
      level = LEVELS[i % 4]
      count = QrReader::SymbolVersion[version].data_codewords(level)
      data = if i.even?
               rng.bytes(count)
             else # plausible start: a valid mode indicator and a small count
               ([rng.rand(16) << 4 | rng.rand(2)].pack("C") + rng.bytes(count - 1)).b
             end
      result = Decoder.decode(SymbolBuilder.build(data, version: version, level: level, mask: i % 8))
      next unless result

      parsed += 1
      assert result.text.valid_encoding?
      assert_equal Encoding::UTF_8, result.text.encoding
      assert_equal Encoding::BINARY, result.raw_bytes.encoding
    end
    assert_operator parsed, :>, 50
  end
end
