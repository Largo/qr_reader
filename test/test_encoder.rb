# frozen_string_literal: true

require_relative "test_helper"
require "qr_encoder"
require "reference"
require "tmpdir"

# Validates the independent test encoder (test/support/qr_encoder.rb):
# spec examples, cross-checks with the core tables, symbol-for-symbol
# equality with rqrcode_core, and round trips through zxing-cpp.
class TestQrTestEncoder < Minitest::Test
  LEVELS = %i[L M Q H].freeze

  # rqrcode_core with the mask forced instead of chosen by its penalty
  # evaluation (much faster, and covers all eight masks evenly).
  class ForcedMaskQRCode < RQRCodeCore::QRCode
    def initialize(data, mask:, **options)
      @forced_mask = mask
      super(data, options)
    end

    private

    def get_best_mask_pattern
      @forced_mask
    end
  end

  def bits_of(encoded)
    encoded.data_codewords.pack("C*").unpack1("B*")[0, encoded.bit_length]
  end

  def random_text(rng, mode, length)
    case mode
    when :number then Array.new(length) { rng.rand(10).to_s }.join
    when :alphanumeric then Array.new(length) { QrTestEncoder::ALPHANUMERIC_CHARSET[rng.rand(45)] }.join
    else Array.new(length) { rng.rand(256).chr }.join.b
    end
  end

  # Largest payload of +mode+ that fits version/level (by bit arithmetic).
  def max_length(mode, version, level)
    capacity = QrTestEncoder.capacity_bits(version, level)
    vc = version <= 9 ? 0 : (version <= 26 ? 1 : 2)
    case mode
    when :number
      bits = capacity - 4 - [10, 12, 14][vc]
      (bits / 10 * 3) + [0, 0, 0, 0, 1, 1, 1, 2, 2, 2][bits % 10]
    when :alphanumeric
      bits = capacity - 4 - [9, 11, 13][vc]
      (bits / 11 * 2) + (bits % 11 >= 6 ? 1 : 0)
    else
      (capacity - 4 - [8, 16, 16][vc]) / 8
    end
  end

  def rqr_mode_to_ours(mode)
    { number: :numeric, alphanumeric: :alphanumeric, byte_8bit: :byte }.fetch(mode)
  end

  # --- ISO/IEC 18004 examples ------------------------------------------------

  def test_numeric_example_codewords_and_error_correction
    # §7.4.3 / Annex I: "01234567" as 1-M.
    e = QrTestEncoder.build("01234567", version: 1, level: :M, mask: 0)
    assert_equal "0001" "0000001000" "0000001100" "0101011001" "1000011", bits_of(e)
    assert_equal [0x10, 0x20, 0x0C, 0x56, 0x61, 0x80] + [0xEC, 0x11] * 5, e.data_codewords
    assert_equal [0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55], e.blocks[0][1]
    assert_equal e.data_codewords + e.blocks[0][1], e.codewords
  end

  def test_alphanumeric_example
    # §7.4.4: "AC-42".
    e = QrTestEncoder.build("AC-42", version: 1, level: :H)
    assert_equal "0010" "000000101" "00111001110" "11100111001" "000010", bits_of(e)
  end

  def test_kanji_example
    # §7.4.6: Shift JIS 0x935F, 0xE4AA -> 0x0D9F, 0x1AAA.
    e = QrTestEncoder.build([[:kanji, "点茗"]], version: 1)
    assert_equal "1000" "00000010" "0110110011111" "1101010101010", bits_of(e)
  end

  def test_hanzi_segment
    # GB2312 0xD6D0 - 0xA6A1 = 0x302F -> 0x30 * 0x60 + 0x2F = 4655; 0xA1A1 -> 0.
    e = QrTestEncoder.build([[:hanzi, "中　"]], version: 1)
    assert_equal "1101" "0001" "00000010" + format("%013b", 4655) + "0" * 13, bits_of(e)
  end

  def test_byte_segment_uses_string_bytes
    e = QrTestEncoder.build([[:byte, "é"]], version: 1)
    assert_equal "0100" "00000010" "11000011" "10101001", bits_of(e)
    latin1 = QrTestEncoder.build([[:byte, "é".encode("ISO-8859-1")]], version: 1)
    assert_equal "0100" "00000001" "11101001", bits_of(latin1)
  end

  def test_eci_designators_of_one_two_and_three_bytes
    {
      9 => "00001001", 127 => "01111111", 128 => "1000000010000000",
      16_383 => "1011111111111111", 16_384 => "110000000100000000000000", 999_999 => "110011110100001000111111"
    }.each do |value, designator|
      e = QrTestEncoder.build([[:byte, "A"]], eci: value, version: 1)
      assert_equal "0111" + designator + "0100" "00000001" "01000001", bits_of(e), "ECI #{value}"
    end
  end

  def test_fnc1_and_structured_append_headers
    e = QrTestEncoder.build("1", fnc1: :first, version: 1)
    assert_equal "0101" "0001" "0000000001" "0001", bits_of(e)
    e = QrTestEncoder.build("1", fnc1: [:second, "a"], version: 1)
    assert_equal "1001" "11000101" "0001" "0000000001" "0001", bits_of(e)
    e = QrTestEncoder.build("1", fnc1: [:second, 37], version: 1)
    assert_equal "1001" "00100101" "0001" "0000000001" "0001", bits_of(e)
    # Symbol 3 of 4 (§8.3.12 example layout: index 2, count-1 = 3).
    e = QrTestEncoder.build("1", structured_append: [2, 4, 0x5A], version: 1)
    assert_equal "0011" "0010" "0011" "01011010" "0001" "0000000001" "0001", bits_of(e)
    # Header order: structured append, ECI, FNC1, data.
    e = QrTestEncoder.build("1", structured_append: [0, 2, 1], eci: 26, fnc1: :first, version: 1)
    assert_equal %i[structured_append eci fnc1_first numeric], e.segments.map(&:mode)
  end

  def test_fnc1_percent_handling_in_alphanumeric_segments
    e = QrTestEncoder.build([[:alphanumeric, "A\x1DB%"]], fnc1: :first, version: 1)
    assert_equal "A%B%%", e.segments.last.data
    assert_raises(QrTestEncoder::Error) { QrTestEncoder.build([[:alphanumeric, "A\x1DB"]], version: 1) }
  end

  def test_structured_append_parity_defaults_to_xor_of_data
    e = QrTestEncoder.build("AB", structured_append: [0, 2, nil])
    assert_equal "A".ord ^ "B".ord, e.segments.first.data[2]
    series = QrTestEncoder.structured_append_series("Hello, structured world!", 3)
    assert_equal 3, series.size
    parity = "Hello, structured world!".bytes.reduce(:^)
    series.each_with_index do |s, i|
      assert_equal [i, 3, parity], s.segments.first.data
    end
    assert_equal "Hello, structured world!", series.map { |s| s.segments.last.data }.join
  end

  def test_character_count_bits_per_version_range
    {
      [:numeric, "1"] => [18, 20, 22], [:alphanumeric, "A"] => [19, 21, 23], [:byte, "a"] => [20, 28, 28],
      [:kanji, "点"] => [25, 27, 29], [:hanzi, "中"] => [29, 31, 33]
    }.each do |segment, lengths|
      [[9, 0], [10, 1], [26, 1], [27, 2], [40, 2]].each do |version, range|
        e = QrTestEncoder.build([segment], version: version, level: :H, mask: 0)
        assert_equal lengths[range], e.bit_length, "#{segment.inspect} in version #{version}"
      end
    end
  end

  def test_terminator_and_padding
    # 3 data bits of a 1-L symbol's 19 codewords, then terminator and pads.
    e = QrTestEncoder.build("1", version: 1, level: :L, mask: 0)
    assert_equal "0001" "0000000001" "0001", bits_of(e)
    assert_equal 0b00010000, e.data_codewords[0]
    assert_equal 0b00000100, e.data_codewords[1]
    assert_equal 0b01000000, e.data_codewords[2] # "01" + terminator + zero fill
    assert_equal [0xEC, 0x11] * 8, e.data_codewords[3..]
    # 17 digits in 1-H: 71 of 72 bits, the terminator shrinks to one bit.
    e = QrTestEncoder.build("12345678901234567", version: 1, level: :H, mask: 0)
    assert_equal 71, e.bit_length
    assert_equal 9, e.data_codewords.size
    assert_equal 0, e.data_codewords.last & 1
    refute_includes e.data_codewords.last(1), 0xEC
  end

  def test_spec_capacities
    # Table 7 extremes: 1-L and 40-L/H in every mode.
    assert_equal 41, max_length(:number, 1, :L)
    assert_equal 17, max_length(:byte, 1, :L)
    assert_equal 7089, max_length(:number, 40, :L)
    assert_equal 4296, max_length(:alphanumeric, 40, :L)
    assert_equal 2953, max_length(:byte, 40, :L)
    assert_equal 1273, max_length(:byte, 40, :H)
    assert_equal 1817, (QrTestEncoder.capacity_bits(40, :L) - 4 - 12) / 13
  end

  def test_automatic_version_is_smallest_that_fits
    [1, 9, 10, 26, 27, 39].each do |version|
      LEVELS.each do |level|
        %i[number alphanumeric byte].each do |mode|
          n = max_length(mode, version, level)
          text = random_text(Random.new(version), mode, n)
          ours = rqr_mode_to_ours(mode == :byte ? :byte_8bit : mode)
          assert_equal version, QrTestEncoder.version_for([[ours, text]], level: level)
          assert_equal version + 1, QrTestEncoder.version_for([[ours, text + text[0]]], level: level)
        end
      end
    end
    assert_equal 40, QrTestEncoder.version_for("1" * 7089, level: :L)
    assert_raises(QrTestEncoder::Error) { QrTestEncoder.version_for("1" * 7090, level: :L) }
    assert_raises(QrTestEncoder::Error) { QrTestEncoder.build("1" * 42, version: 1, level: :L) }
  end

  def test_invalid_input_raises_encoder_error
    [
      -> { QrTestEncoder.build([[:numeric, "12a"]]) },
      -> { QrTestEncoder.build([[:alphanumeric, "abc"]]) },
      -> { QrTestEncoder.build([[:kanji, "abc"]]) },
      -> { QrTestEncoder.build([[:hanzi, "\u{1F600}"]]) }, # not in GB2312
      -> { QrTestEncoder.build([[:byte, "x" * 256]], version: 9, level: :L) }, # 8-bit count
      -> { QrTestEncoder.build([[:eci, 1_000_000]]) },
      -> { QrTestEncoder.build([[:bogus, "x"]]) },
      -> { QrTestEncoder.build("x", level: :X) },
      -> { QrTestEncoder.build("x", mask: 8) },
      -> { QrTestEncoder.build("x", version: 41) },
      -> { QrTestEncoder.build("x", structured_append: [3, 2, 0]) }
    ].each { |call| assert_raises(QrTestEncoder::Error) { call.call } }
  end

  def test_garbage_specifications_raise_only_encoder_errors
    garbage = [nil, 42, :x, 1.5, {}, [], [nil], [[]], [[:numeric]], [[:eci]], [[:eci, "26"]], [[:fnc1_second]],
               [[:fnc1_second, "ab"]], [[:structured_append, "a", 2]], [[:structured_append, 0, 2, "x"]],
               [[:kanji, nil]], [[:hanzi, 5]], [{ data: "x" }], [[:byte, "x"], 7]]
    garbage.each do |content|
      QrTestEncoder.build(content)
    rescue QrTestEncoder::Error
      nil
    end
    [{ fnc1: :third }, { fnc1: [:first] }, { structured_append: 5 }, { eci: -1 }, { version: "2" }, { level: nil }].each do |options|
      assert_raises(QrTestEncoder::Error, options.inspect) { QrTestEncoder.build("x", **options) }
    end
    sa = QrReader::StructuredAppend.new(index: 1, count: 2, parity: 9)
    assert_equal [1, 2, 9], QrTestEncoder.build("x", structured_append: sa).segments.first.data
  end

  # --- cross-checks with the core tables -------------------------------------

  def test_layout_matches_symbol_version
    1.upto(40) do |n|
      core = QrReader::SymbolVersion[n]
      layout = QrTestEncoder.layout(n)
      assert_equal core.total_codewords, layout.raw_codewords, "version #{n}"
      assert_equal core.alignment_centers, QrTestEncoder::ALIGNMENT_POSITIONS[n], "version #{n}"
      assert_equal core.version_info_bits, QrTestEncoder.version_bits(n), "version #{n}" if n >= 7
      LEVELS.each do |level|
        blocks = core.ec_blocks(level)
        assert_equal [blocks.data_codewords_per_block, blocks.ec_codewords_per_block],
                     QrTestEncoder.block_sizes(n, level), "#{n}-#{level}"
      end
    end
  end

  def test_remainder_bits
    expected = { 1 => 0, 2..6 => 7, 7..13 => 0, 14..20 => 3, 21..27 => 4, 28..34 => 3, 35..40 => 0 }
    expected.each do |versions, bits|
      Array(versions).each { |v| assert_equal bits, QrTestEncoder.layout(v).remainder_bits, "version #{v}" }
    end
  end

  def test_format_bits_match_core
    LEVELS.each do |level|
      8.times do |mask|
        data = (QrTestEncoder::LEVEL_BITS[level] << 3) | mask
        assert_equal QrReader::FormatInformation.encode(data), QrTestEncoder.format_bits(level, mask)
      end
    end
  end

  # --- symbol equality with rqrcode_core ---------------------------------------

  # rqrcode picks the mask itself; we read it back from its format bits.
  def test_matches_rqrcode_with_its_own_mask_choice
    rng = Random.new(2024)
    versions = (1..10).to_a + [14, 21, 27, 33, 40]
    versions.each_with_index do |version, i|
      levels = version <= 10 ? LEVELS : [LEVELS[i % 4]]
      levels.each do |level|
        mode = %i[number alphanumeric byte_8bit][rng.rand(3)]
        text = random_text(rng, mode, rng.rand(1..max_length(mode, version, level)))
        qr = RQRCodeCore::QRCode.new(text, level: level.downcase, size: version, mode: mode)
        theirs = QrReader::BitMatrix.from_rows(qr.modules)
        read_level, mask = QrTestEncoder.read_format(theirs)
        assert_equal level, read_level
        ours = QrTestEncoder.encode([[rqr_mode_to_ours(mode), text]], version: version, level: level, mask: mask)
        assert_equal theirs, ours, "#{version}-#{level} mask #{mask} #{mode} #{text.size}"
      end
    end
  end

  # Every version, all eight masks and levels in rotation (every version at
  # every level with QR_ENCODER_FULL=1; rqrcode_core is slow).
  def test_matches_rqrcode_for_all_versions_with_forced_masks
    rng = Random.new(7)
    full = ENV["QR_ENCODER_FULL"]
    1.upto(40) do |version|
      LEVELS.each_with_index do |level, li|
        next unless full || li == version % 4

        mask = (version * 3 + li) % 8
        mode = %i[number alphanumeric byte_8bit][(version + li) % 3]
        text = random_text(rng, mode, rng.rand(1..max_length(mode, version, level)))
        qr = ForcedMaskQRCode.new(text, mask: mask, level: level.downcase, size: version, mode: mode)
        theirs = QrReader::BitMatrix.from_rows(qr.modules)
        assert_equal [level, mask], QrTestEncoder.read_format(theirs)
        ours = QrTestEncoder.encode([[rqr_mode_to_ours(mode), text]], version: version, level: level, mask: mask)
        assert_equal theirs, ours, "#{version}-#{level} mask #{mask} #{mode} #{text.size}"
      end
    end
  end

  def test_matches_rqrcode_for_multi_segment_payloads
    rng = Random.new(99)
    30.times do |i|
      segments = Array.new(rng.rand(2..5)) do
        mode = %i[number alphanumeric byte_8bit][rng.rand(3)]
        { data: random_text(rng, mode, rng.rand(1..40)), mode: mode }
      end
      level = LEVELS[i % 4]
      qr = RQRCodeCore::QRCode.new(segments, level: level.downcase)
      theirs = QrReader::BitMatrix.from_rows(qr.modules)
      _, mask = QrTestEncoder.read_format(theirs)
      ours = QrTestEncoder.encode(segments.map { |s| [rqr_mode_to_ours(s[:mode]), s[:data]] },
                                  version: qr.version, level: level, mask: mask)
      assert_equal theirs, ours, "case #{i}"
    end
  end

  # --- masks, corruption, determinism ------------------------------------------

  def test_automatic_mask_has_lowest_penalty
    ["HELLO WORLD", "https://example.com/" * 5, "0" * 300].each do |text|
      auto = QrTestEncoder.build(text, level: :Q)
      scores = (0..7).map { |m| QrTestEncoder.penalty(QrTestEncoder.encode(text, level: :Q, mask: m)) }
      assert_equal scores.index(scores.min), auto.mask, text
    end
  end

  def test_read_codewords_round_trip
    [1, 7, 23, 40].each do |version|
      e = QrTestEncoder.build("round trip #{version}", version: version, level: :L)
      assert_equal e.codewords, QrTestEncoder.read_codewords(e.matrix)
    end
  end

  def test_corrupt_codewords
    clean = QrTestEncoder.build("corruption test", version: 5, level: :H, mask: 2)
    bad = QrTestEncoder.build("corruption test", version: 5, level: :H, mask: 2, corrupt_codewords: 9, seed: 4)
    assert_equal 9, bad.corrupted[:codewords].size
    read = QrTestEncoder.read_codewords(bad.matrix)
    differing = read.each_index.reject { |i| read[i] == clean.codewords[i] }
    assert_equal bad.corrupted[:codewords], differing
    assert_equal clean.codewords, bad.codewords
  end

  def test_corrupt_per_block_max
    e = QrTestEncoder.build("x" * 200, version: 12, level: :M, corrupt_per_block: :max, seed: 1)
    read = QrTestEncoder.read_codewords(e.matrix)
    assert_equal e.corrupted[:codewords], read.each_index.reject { |i| read[i] == e.codewords[i] }
    # Block of each interleaved codeword: data columns, then EC columns.
    sizes, ecc = QrTestEncoder.block_sizes(12, :M)
    owner = []
    sizes.max.times { |i| sizes.each_with_index { |size, b| owner << b if i < size } }
    ecc.times { sizes.each_index { |b| owner << b } }
    damaged = e.corrupted[:codewords].map { |i| owner[i] }.tally
    assert_equal sizes.each_index.to_h { |b| [b, ecc / 2] }, damaged
  end

  def test_corrupt_modules_only_touches_the_data_region
    clean = QrTestEncoder.build("modules", version: 3, mask: 1)
    bad = QrTestEncoder.build("modules", version: 3, mask: 1, corrupt_modules: 12, seed: 5)
    diffs = []
    clean.matrix.height.times do |y|
      clean.matrix.width.times { |x| diffs << [x, y] if clean.matrix.get(x, y) != bad.matrix.get(x, y) }
    end
    assert_equal bad.corrupted[:modules].sort, diffs.sort
    assert_equal 12, diffs.size
    function = QrTestEncoder.layout(3).function
    diffs.each { |x, y| assert_equal 0, function.getbyte(y * 29 + x) }
  end

  def test_corruption_is_deterministic_per_seed
    a = QrTestEncoder.encode("seeded", corrupt_codewords: 3, seed: 11)
    b = QrTestEncoder.encode("seeded", corrupt_codewords: 3, seed: 11)
    c = QrTestEncoder.encode("seeded", corrupt_codewords: 3, seed: 12)
    assert_equal a, b
    refute_equal a, c
  end

  def test_render
    e = QrTestEncoder.build("render", version: 1, mask: 0)
    img = e.to_image(module_size: 3, quiet: 2)
    assert_equal (21 + 4) * 3, img.width
    assert_equal 0, img[6, 6] # top-left finder corner module
    assert_equal 255, img[0, 0]
    assert_equal img.data, QrTestHelper.render(e.matrix, module_size: 3, quiet: 2).data
  end

  # --- independent decoder round trips ---------------------------------------------

  # Expected zxing-cpp "HexECI" output: AIM symbology identifier, ECI
  # designators as "\nnnnnn", then the raw bytes.
  ZXING_CASES = [
    ["numeric", "01234567890123456789", {}, "]Q1" + "01234567890123456789"],
    ["alphanumeric", [[:alphanumeric, "HELLO WORLD $%*+-./:"]], {}, "]Q1HELLO WORLD $%*+-./:"],
    ["byte utf-8", [[:byte, "Grüße"]], {}, "]Q1" + "Grüße".b],
    ["kanji", [[:kanji, "点茗漢字テスト"]], {}, "]Q1" + "点茗漢字テスト".encode("Shift_JIS").b],
    ["hanzi", [[:hanzi, "中文汉字测试"]], {}, "]Q1" + "中文汉字测试".encode("GB2312").b],
    ["mixed", [[:numeric, "12345"], [:alphanumeric, "HELLO "], [:byte, "world"], [:kanji, "漢字"]], {},
     "]Q112345HELLO world" + "漢字".encode("Shift_JIS").b],
    ["eci 26", [[:byte, "Grüße €"]], { eci: 26 }, "]Q2\\000026" + "Grüße €".b],
    ["eci 3", [[:byte, "café".encode("ISO-8859-1")]], { eci: 3 }, "]Q2\\000003caf\xE9".b],
    ["eci 127", [[:byte, "abc"]], { eci: 127 }, "]Q2\\000127abc"],
    ["eci 128", [[:byte, "abc"]], { eci: 128 }, "]Q2\\000128abc"],
    ["eci 899", [[:byte, "\x00\x01\xFF".b]], { eci: 899 }, "]Q2\\000899\x00\x01\xFF".b],
    ["eci 16383", [[:byte, "abc"]], { eci: 16_383 }, "]Q2\\016383abc"],
    ["eci 16384", [[:byte, "abc"]], { eci: 16_384 }, "]Q2\\016384abc"],
    ["eci 999999", [[:byte, "abc"]], { eci: 999_999 }, "]Q2\\999999abc"],
    ["eci switch", [[:eci, 26], [:byte, "é"], [:eci, 3], [:byte, "\xE9".b]], {},
     "]Q2\\000026\xC3\xA9\\000003\xE9".b],
    ["fnc1 first", [[:numeric, "01095011015300031"], [:alphanumeric, "7160430"], [:byte, "10ABC"]], { fnc1: :first },
     "]Q301095011015300031716043010ABC"],
    ["fnc1 gs", [[:alphanumeric, "10ABC\x1D21XYZ%"]], { fnc1: :first }, "]Q310ABC\x1D21XYZ%"],
    ["fnc1 first eci", [[:byte, "01é"]], { fnc1: :first, eci: 26 }, "]Q4\\00002601\xC3\xA9".b],
    ["fnc1 second 37", [[:byte, "hello"]], { fnc1: [:second, 37] }, "]Q537hello"],
    ["fnc1 second a", [[:byte, "hello"]], { fnc1: [:second, "a"] }, "]Q5ahello"],
    ["fnc1 second eci", [[:byte, "é"]], { fnc1: [:second, "Z"], eci: 26 }, "]Q6\\000026Z\xC3\xA9".b],
    ["structured append", [[:byte, "part one"]], { structured_append: [0, 3, 0x42] }, "]Q1part one"],
    ["structured append eci", [[:byte, "ü"]], { structured_append: [2, 3, 0x42], eci: 26 }, "]Q2\\000026\xC3\xBC".b],
    ["v10 byte count", [[:byte, "b" * 260]], { version: 10, level: :L }, "]Q1" + "b" * 260],
    ["v27 numeric count", [[:numeric, "7" * 1100]], { version: 27, level: :H }, "]Q1" + "7" * 1100],
    ["v40 kanji", [[:kanji, "漢" * 700]], { version: 40, level: :Q }, "]Q1" + ("漢" * 700).encode("Shift_JIS").b],
    ["v20 alnum", [[:alphanumeric, "AB" * 200]], { version: 20, level: :M, mask: 5 }, "]Q1" + "AB" * 200],
    ["max errors", [[:byte, "error correction"]], { version: 8, level: :H, corrupt_per_block: :max, seed: 3 },
     "]Q1error correction"],
    ["max errors v25", [[:byte, "z" * 400]], { version: 25, level: :L, corrupt_per_block: :max, seed: 4 },
     "]Q1" + "z" * 400]
  ].freeze

  def test_zxing_cpp_reads_every_feature
    skip "zxing-cpp reference venv not available" unless QrReference.available?

    Dir.mktmpdir do |dir|
      cases = ZXING_CASES.each_with_index.map do |(name, content, options, expected), i|
        encoded = QrTestEncoder.build(content, **{ level: LEVELS[i % 4], mask: i % 8 }.merge(options))
        path = File.join(dir, "case#{i}.png")
        QrTestHelper.write_png(encoded.to_image(module_size: 3), path)
        [name, path, expected.b, encoded]
      end
      results = QrReference.decode(cases.map { |_, path, _| path }, text_mode: "HexECI")
      cases.zip(results).each do |(name, _, expected, encoded), result|
        texts = result["results"].map { |r| r["text"].split.map { |h| h.to_i(16) }.pack("C*") }
        assert_equal [expected], texts, name
        found = result["results"].first
        assert_equal [encoded.version, encoded.mask, encoded.level.to_s],
                     [found["version"], found["mask"], found["ec_level"]], name
      end
    end
  end
end
