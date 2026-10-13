# frozen_string_literal: true

require "json"
require "zlib"
require_relative "decoder_test_helper"
require_relative "fixtures/generate_zxing_cpp_damaged"

begin
  require "qr_encoder" # testkit's independent encoder (test/support)
rescue LoadError, StandardError
  nil
end

# Adversarial review of the decoder: orientation handling, inputs the
# BitMatrix contract does not rule out, character sets compared with
# zxing-cpp, the precomputed tables against their definitions, symbols from
# the testkit's independent encoder, damaged format/version information and
# damaged symbols compared with zxing-cpp.
class TestDecoderAdversarial < Minitest::Test
  include DecoderTestHelper

  Decoder = QrReader::Decoder
  CS = Decoder::CharacterSet
  REFERENCE = File.join(__dir__, "fixtures", "charset_reference.json")
  LEVEL_BITS = { L: 1, M: 0, Q: 3, H: 2 }.freeze

  def reference
    @reference ||= JSON.parse(File.read(REFERENCE))
  end

  def unmasked_format(level, mask)
    QrReader::FormatInformation.encode((LEVEL_BITS[level] << 3) | mask) ^ QrReader::FormatInformation::MASK
  end

  # --- orientation -------------------------------------------------------

  # Format information written without the 0x5412 mask (accepted by
  # FormatInformation) reads exactly both ways round for M/0 and Q/7, so the
  # "exact format, skip the other orientation" shortcut must not apply.
  def test_mirrored_symbols_with_unmasked_format_information
    [1, 7].each do |version|
      LEVELS.each do |level|
        8.times do |mask|
          text = "m#{level}#{mask}"
          writer = BitWriter.new.bytes(text, version)
          matrix = SymbolBuilder.build_stream(writer, version: version, level: level, mask: mask,
                                                      format_bits: unmasked_format(level, mask))
          where = "v#{version} #{level} mask #{mask}"
          normal = Decoder.decode(matrix)
          assert_equal text, normal&.text, "#{where} normal"
          refute normal.mirrored
          mirrored = Decoder.decode(matrix.transpose)
          assert_equal text, mirrored&.text, "#{where} mirrored"
          assert mirrored.mirrored
          assert_equal :ok, Decoder.diagnose(matrix.transpose)[:status]
        end
      end
    end
  end

  # The shortcut's precondition: with the standard (masked) format code a
  # symbol read the wrong way round is at least 2 away in both copies.
  def test_wrong_orientation_reads_masked_format_at_distance_two_or_more
    [1, 7].each do |version|
      LEVELS.each do |level|
        8.times do |mask|
          data = "\0".b * QrReader::SymbolVersion[version].data_codewords(level)
          matrix = SymbolBuilder.build(data, version: version, level: level, mask: mask)
          n = matrix.width
          right = Decoder::FormatReader.format_bits(matrix.bits, n)
          wrong = Decoder::FormatReader.format_bits(matrix.bits, n, mirrored: true)
          assert_equal 0, Decoder::FormatReader.decode_format(*right).last
          wrong.each do |word|
            distance = Decoder::FormatReader.decode_format(word, word)&.last || 4
            assert_operator distance, :>=, 2, "v#{version} #{level} mask #{mask}"
          end
        end
      end
    end
  end

  # One format copy damaged arbitrarily (the other intact) or at most one
  # error per copy: the true orientation reads at distance <= 1, so a
  # mirrored symbol must always be found, whatever the wrong way reads.
  def test_mirrored_symbols_with_damaged_format_information
    rng = Random.new(60)
    text, data = nil
    LEVELS.each_with_index do |level, li|
      version = [2, 5, 7, 10][li]
      text = payload(rng, :alphanumeric, 10)
      data = BitWriter.new.alphanumeric(text, version).to_data(QrReader::SymbolVersion[version].data_codewords(level))
      n = 17 + 4 * version
      copy1 = [[0, 8], [1, 8], [2, 8], [3, 8], [4, 8], [5, 8], [7, 8], [8, 8], [8, 7], [8, 5], [8, 4], [8, 3], [8, 2],
               [8, 1], [8, 0]]
      copy2 = (0..6).map { |k| [8, n - 1 - k] } + (0..7).map { |k| [n - 8 + k, 8] }
      8.times do |mask|
        clean = SymbolBuilder.build(data, version: version, level: level, mask: mask)
        12.times do |trial|
          m = clean.dup
          case trial % 3
          when 0 then copy1.each { |x, y| m.set(x, y, rng.rand(2)) }
          when 1 then copy2.each { |x, y| m.set(x, y, rng.rand(2)) }
          else [copy1, copy2].each { |coords| coords.sample(rng.rand(0..1), random: rng).each { |x, y| m.flip(x, y) } }
          end
          result = Decoder.decode(m.transpose)
          assert_equal text, result&.text, "v#{version} #{level} mask #{mask} trial #{trial}"
          assert result.mirrored
          assert_equal text, Decoder.decode(m)&.text
        end
      end
    end
  end

  # --- inputs ------------------------------------------------------------

  def test_module_strings_that_are_not_binary_or_missing
    matrix = rqr("ENCODING", version: 1, level: :M, mode: :alphanumeric, mask: 4)
    utf8 = matrix.dup
    utf8.bits.force_encoding(Encoding::UTF_8)
    assert_equal "ENCODING", Decoder.decode(utf8).text
    utf8.bits.setbyte(0, 0xFE) # invalid UTF-8, in a finder module (ignored by the decoder)
    assert_equal "ENCODING", Decoder.decode(utf8).text
    assert_equal :ok, Decoder.diagnose(utf8)[:status]
    garbage = QrReader::BitMatrix.new(25, 25, Random.new(61).bytes(625))
    garbage.bits.force_encoding(Encoding::UTF_8)
    Decoder.decode(garbage) # must not raise
    Decoder.diagnose(garbage)
    missing = QrReader::BitMatrix.allocate
    missing.instance_variable_set(:@width, 21)
    missing.instance_variable_set(:@height, 21)
    missing.instance_variable_set(:@bits, nil)
    assert_nil Decoder.decode(missing)
    assert_equal :dimension, Decoder.diagnose(missing)[:status]
    frozen = QrReader::BitMatrix.new(21, 21, matrix.bits.dup.freeze)
    assert_equal "ENCODING", Decoder.decode(frozen).text
  end

  # Random grids at every version, with and without valid format/version
  # information, cells of any byte value: never an exception, diagnose
  # always reports a known status, and anything decoded is well formed.
  def test_fuzz_every_version_and_cell_values
    rng = Random.new(62)
    templates = (1..40).map do |version|
      level = LEVELS[version % 4]
      SymbolBuilder.build("\0".b * QrReader::SymbolVersion[version].data_codewords(level), version: version,
                                                                                       level: level, mask: version % 8)
    end
    decoded = 0
    1200.times do |i|
      template = templates[i % 40]
      n = template.width
      matrix = case i % 3
               when 0 then QrReader::BitMatrix.new(n, n, rng.bytes(n * n)) # arbitrary byte values
               when 1 then QrReader::BitMatrix.new(n, n, rng.bytes(n * n).tr("\x80-\xFF".b, "\x01").tr("^\x01".b, "\x00"))
               else
                 m = template.dup
                 order = Decoder::Codewords.layout(i % 40 + 1).order
                 random = rng.bytes(order.size)
                 order.each_with_index { |index, k| m.bits.setbyte(index, random.getbyte(k) & 1) }
                 m
               end
      matrix = matrix.transpose if i.odd?
      result = Decoder.decode(matrix)
      assert_includes Decoder::STATUSES, Decoder.diagnose(matrix)[:status]
      next unless result

      decoded += 1
      assert result.text.valid_encoding?
      assert_equal n, 17 + 4 * result.version
    end
    assert_operator decoded, :<, 3
  end

  # --- character sets (zxing-cpp reference) ------------------------------

  # Byte segments without ECI decode exactly like zxing-cpp, including its
  # rule that control characters (other than CR/LF) mean binary data, not
  # Shift_JIS. Documented deviation: a UTF-16 BOM selects UTF-16 (ZXing
  # Java's behaviour; zxing-cpp shows the bytes as ISO-8859-1).
  def test_byte_mode_guess_matches_zxing_cpp
    compared = 0
    reference["bytes"].each do |hex, expected|
      bytes = [hex].pack("H*")
      text = Decoder::BitstreamParser.parse(BitWriter.new.bytes(bytes, 5).to_data, 5).text
      if bytes.start_with?("\xFE\xFF".b, "\xFF\xFE".b) && bytes.bytesize > 2
        assert_equal CS.to_utf8(bytes, CS.guess(bytes)), text
        next
      end
      assert_equal expected, text, "bytes #{hex}"
      compared += 1
    end
    assert_operator compared, :>, 150
    # binary data stays lossless
    binary = "\xA5\xBB\xC6\xB1\x13M\x9B\x90\xE6\xB5*\xD3".b
    assert_equal CS::ISO_8859_1, CS.guess(binary)
    assert_equal CS::SHIFT_JIS, CS.guess("\xB1\xB2\xB3\r\n".b)
  end

  # Every Kanji-mode code decodes like zxing-cpp, except where we do better
  # or follow ZXing Java: NEC/IBM extension characters (zxing-cpp: U+FFFD;
  # we use Windows-31J) and 0x815F (Java and Unicode's JIS0208 table: U+FF3C
  # FULLWIDTH REVERSE SOLIDUS; zxing-cpp: U+005C).
  def test_every_kanji_code_matches_zxing_cpp
    codes = kanji_codes
    expected = reference["kanji"].chars
    assert_equal codes.size, expected.size
    actual = parse_segments(:kanji, codes).chars
    assert_equal codes.size, actual.size
    codes.each_with_index do |code, i|
      next if expected[i] == actual[i]

      if code == "\x81\x5F".b
        assert_equal "＼", actual[i]
      else
        assert_equal "�", expected[i], "0x#{code.unpack1('H*')}"
        assert_equal code.dup.force_encoding(Encoding::Windows_31J).encode(Encoding::UTF_8), actual[i]
      end
    end
    assert_equal "―", Decoder::BitstreamParser.parse(BitWriter.new.kanji("\x81\x5C".b, 1).to_data, 1).text
    assert_equal "―", CS.to_utf8("\x81\x5C".b, CS::SHIFT_JIS)
  end

  # Every Hanzi-mode (GB 2312 subset) code decodes exactly like zxing-cpp
  # (GB 18030-2005 mappings, not Ruby's 2000 private-use ones).
  def test_every_hanzi_code_matches_zxing_cpp
    codes = hanzi_codes
    text = parse_segments(:hanzi, codes)
    expected = reference["hanzi"]
    assert_equal codes.size, expected.chars.size
    assert_equal expected, text
    assert_equal "︐", CS.to_utf8("\xA6\xD9".b, CS::GB18030)
    assert_equal "ḿ", CS.to_utf8("\xA8\xBC".b, CS::GB18030)
  end

  # Text of a bit stream with the 2-byte +codes+ in +mode+ segments of at
  # most 1500 characters (the count field of versions 27-40 has 12 bits).
  def parse_segments(mode, codes)
    writer = BitWriter.new
    codes.each_slice(1500) { |chunk| writer.public_send(mode, chunk.join, 40) }
    Decoder::BitstreamParser.parse(writer.to_data, 40).text
  end

  def kanji_codes
    ((0x81..0x9F).to_a + (0xE0..0xEA).to_a).flat_map do |hi|
      (0x40..0xFC).filter_map { |lo| [hi, lo].pack("CC") unless lo == 0x7F }
    end
  end

  def hanzi_codes
    ((0xA1..0xAA).to_a + (0xB0..0xF7).to_a).flat_map { |hi| (0xA1..0xFE).map { |lo| [hi, lo].pack("CC") } }
  end

  # The Shift_JIS 0xE040.. range (lead bytes 0xE0-0xEA, Kanji value offset
  # 0xC140) - the original test only asserted a constant.
  def test_kanji_upper_range
    content = Decoder::BitstreamParser.parse(BitWriter.new.kanji("\xE0\x40\xEA\xA4".b, 1).to_data, 1)
    assert_equal "漾熙", content.text
    assert_equal "\xE0\x40\xEA\xA4".b, content.raw_bytes
  end

  # --- precomputed tables against their definitions -----------------------

  def test_tables_match_their_definitions
    gf = Decoder::GaloisField
    table = gf.multiplication_table
    256.times { |a| 256.times { |b| assert_equal SymbolBuilder.gf_mul(a, b), table[a][b] } }
    (1..30).each do |ec|
      generator = SymbolBuilder.generator(ec) # highest degree first, monic
      remainder = Decoder::ReedSolomon.remainder_table(ec)
      256.times do |b|
        expected = generator.inject(0) { |acc, c| (acc << 8) | SymbolBuilder.gf_mul(b, c) }
        assert_equal expected, remainder[b], "ec #{ec} b #{b}"
      end
    end
    1.upto(40) do |v|
      layout = Decoder::Codewords.layout(v)
      n = layout.dimension
      assert_equal(layout.order.map { |i| (i % n) * n + i / n }, layout.mirrored_order)
      8.times do |mask|
        bits = layout.order.map { |i| SymbolBuilder.masked?(mask, i / n, i % n) ? "1" : "0" }
        assert_equal [bits.join].pack("B*").bytes, layout.mask_codewords(mask), "v#{v} mask #{mask}"
      end
    end
  end

  # The format lookup table agrees with FormatInformation.decode on every
  # possible pair of identical copies (all 2**15 words).
  def test_format_table_on_every_word
    (1 << 15).times do |word|
      expected = QrReader::FormatInformation.decode(word)
      actual = Decoder::FormatReader.decode_format(word, word)&.first
      assert expected == actual, format("%015b", word)
    end
  end

  # Unrolled Horner syndromes for every EC count (incl. counts that are not
  # multiples of 4) against a direct polynomial evaluation.
  def test_syndromes_for_every_ec_count
    rng = Random.new(63)
    rs = Decoder::ReedSolomon
    (1..30).each do |ec|
      3.times do
        block = Array.new(ec + 1 + rng.rand(60)) { rng.rand(256) }
        expected = Array.new(ec) do |j|
          x = SymbolBuilder::EXP[j]
          block.inject(0) { |s, c| SymbolBuilder.gf_mul(s, x) ^ c }
        end
        expected = nil if expected.all?(&:zero?)
        assert_equal expected, rs.horner_syndromes(block, ec), "ec #{ec}"
        assert_equal expected, rs.remainder_syndromes(block, ec), "ec #{ec}"
      end
      data = Array.new(rng.rand(1..40)) { rng.rand(256) }
      assert_nil rs.horner_syndromes(data + SymbolBuilder.rs_encode(data, ec), ec)
    end
  end

  # --- independent encoder (testkit) --------------------------------------

  def require_testkit_encoder
    skip "testkit QrTestEncoder not available" unless defined?(QrTestEncoder)
  end

  KANJI = "漢字仮名交じり文点茗亜唖娃阿哀愛挨姶逢葵茜穐悪握渥旭葦芦鯵梓圧斡扱宛姐虻飴絢綾鮎或粟袷安庵按暗案闇鞍杏"
  HANZI = "中文汉字测试二维码编码解码啊阿埃挨哎唉哀皑癌蔼矮艾碍爱隘鞍氨安俺按暗岸胺案肮昂盎凹敖熬翱袄傲奥懊澳"

  # Mixed segments (numeric, alphanumeric, byte with ECI, Kanji, Hanzi,
  # FNC1, Structured Append) with up to floor(ec/2) corrupted codewords in
  # every block, encoded by the testkit's independent encoder.
  def test_mixed_segments_from_independent_encoder
    require_testkit_encoder
    rng = Random.new(64)
    60.times do |i|
      kanji = KANJI.chars.sample(rng.rand(1..8), random: rng).join
      hanzi = HANZI.chars.sample(rng.rand(1..8), random: rng).join
      digits = Array.new(rng.rand(1..20)) { rng.rand(10) }.join
      alnum = Array.new(rng.rand(1..12)) { ALNUM[rng.rand(45)] }.join
      utf8 = ["Grüße", "naïve café", "Ж", "😀"].sample(random: rng)
      segments = [[:numeric, digits], [:kanji, kanji], [:alphanumeric, alnum], [:hanzi, hanzi],
                  [:eci, 26], [:byte, utf8]].shuffle(random: rng)
      # bytes before the first ECI are ISO-8859-1 (ECI 000003), after it UTF-8
      latin1 = segments.index { |mode, _| mode == :byte } < segments.index { |mode, _| mode == :eci }
      expected = segments.sum("") do |mode, value|
        next "" if mode == :eci

        mode == :byte && latin1 ? value.b.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8) : value
      end
      encoded = QrTestEncoder.build(segments, level: LEVELS[i % 4], mask: i % 8, corrupt_per_block: :max, seed: i)
      matrix = i.odd? ? encoded.matrix.transpose : encoded.matrix
      result = Decoder.decode(matrix)
      refute_nil result, "case #{i}: #{segments.inspect}"
      assert_equal expected, result.text, "case #{i}"
      assert_equal 26, result.eci
      assert_equal "]Q2", result.symbology_identifier
      assert_equal i.odd?, result.mirrored
      assert_equal encoded.corrupted[:codewords].size, result.errors_corrected
    end
  end

  def test_fnc1_and_structured_append_from_independent_encoder
    require_testkit_encoder
    gs1 = QrTestEncoder.build([[:numeric, "0104912345123459"], [:alphanumeric, "10ABC\x1D21X%Y"]], fnc1: :first,
                                                                                                 level: :Q)
    result = Decoder.decode(gs1.matrix)
    assert_equal "0104912345123459" "10ABC\x1D21X%Y", result.text
    assert_equal :first, result.fnc1
    assert_equal "]Q3", result.symbology_identifier

    series = QrTestEncoder.structured_append_series("STRUCTURED APPEND ACROSS FOUR SYMBOLS", 4, mode: :alphanumeric)
    results = series.map { |encoded| Decoder.decode(encoded.matrix) }
    assert_equal "STRUCTURED APPEND ACROSS FOUR SYMBOLS", results.map(&:text).join
    parity = results.map(&:raw_bytes).join.bytes.reduce(0, :^)
    results.each_with_index do |result, i|
      assert_equal QrReader::StructuredAppend.new(index: i, count: 4, parity: parity), result.structured_append
    end
  end

  # Beyond the correction capacity: nil or the right text, never wrong text.
  def test_beyond_capacity_with_independent_encoder
    require_testkit_encoder
    rng = Random.new(65)
    outcomes = Hash.new(0)
    [[1, :L], [1, :M], [2, :L], [3, :H], [6, :Q], [9, :M]].each do |version, level|
      t = QrTestEncoder.block_sizes(version, level).last / 2
      blocks = QrTestEncoder.block_sizes(version, level).first.size
      25.times do |i|
        text = payload(rng, :byte_8bit, rng.rand(1..10))
        encoded = QrTestEncoder.build([[:byte, text]], version: version, level: level, mask: i % 8,
                                                       corrupt_codewords: (t + 1) * blocks + rng.rand(3), seed: i)
        result = Decoder.decode(encoded.matrix)
        outcomes[result ? :decoded : :rejected] += 1
        assert_equal text, result.text if result
      end
    end
    assert_operator outcomes[:rejected], :>, 0
  end

  # --- damaged format and version information ----------------------------

  LEVEL_FOR_BITS = LEVEL_BITS.invert.freeze
  # Masked format code words by data bits (EC level bits << 3 | mask).
  FORMAT_CODES = Array.new(32) { |data| SymbolBuilder.bch(data, 5, 0x537, 15) ^ 0x5412 }.freeze

  # Writes the 15-bit words +copy1+ (around the top-left finder) and +copy2+
  # (split between bottom-left and top-right) into +matrix+; bit i of a word
  # goes where ISO/IEC 18004 Figure 25 puts format bit i.
  def write_format_copies(matrix, copy1, copy2)
    n = matrix.width
    15.times do |i|
      x1, y1 = i < 8 ? [8, i < 6 ? i : i + 1] : [i == 8 ? 7 : 14 - i, 8]
      x2, y2 = i < 8 ? [n - 1 - i, 8] : [8, n - 15 + i]
      matrix.set(x1, y1, copy1[i])
      matrix.set(x2, y2, copy2[i])
    end
    matrix
  end

  # Writes an 18-bit version information word into the top-right (:top_right)
  # or bottom-left (:bottom_left) block (ISO/IEC 18004 Figure 27).
  def write_version_copy(matrix, block, word)
    n = matrix.width
    18.times do |i|
      x, y = block == :top_right ? [n - 11 + i % 3, i / 3] : [i / 3, n - 11 + i % 3]
      matrix.set(x, y, word[i])
    end
    matrix
  end

  def random_error(rng, weight)
    (0...15).to_a.sample(weight, random: rng).sum { |bit| 1 << bit }
  end

  def symbol_for_format(rng, data_bits, version)
    level = LEVEL_FOR_BITS[data_bits >> 3]
    text = payload(rng, :alphanumeric, rng.rand(1..8)) # fits v1-H
    data = BitWriter.new.alphanumeric(text, version).to_data(QrReader::SymbolVersion[version].data_codewords(level))
    [text, SymbolBuilder.build(data, version: version, level: level, mask: data_bits & 7)]
  end

  # Both copies damaged: the true copy 3 bits off, the other one damaged into
  # (or close to) another code word that is as close or closer and lower -
  # the reading a single-copy "nearest code word" rule gets wrong. Every
  # code word the copies propose must be tried.
  def test_format_copies_proposing_different_code_words
    rng = Random.new(70)
    32.times do |truth|
      [[3, 3], [3, 2], [2, 1], [3, 0]].each_with_index do |(true_errors, other_errors), k|
        others = (0...32).to_a - [truth]
        other = truth.positive? && k.even? ? rng.rand(truth) : others.sample(random: rng)
        version = [1, 3, 7, 12][(truth + k) % 4]
        text, matrix = symbol_for_format(rng, truth, version)
        good = FORMAT_CODES[truth] ^ random_error(rng, true_errors)
        bad = FORMAT_CODES[other] ^ random_error(rng, other_errors)
        k.odd? ? write_format_copies(matrix, good, bad) : write_format_copies(matrix, bad, good)
        result = Decoder.decode(matrix)
        where = "format #{truth} vs #{other}, errors #{true_errors}/#{other_errors}"
        assert_equal text, result&.text, where
        assert_equal [LEVEL_FOR_BITS[truth >> 3].downcase, truth & 7], [result.ec_level, result.mask], where
        assert_equal text, Decoder.decode(matrix.transpose)&.text, "#{where}, mirrored"
        assert_equal :ok, Decoder.diagnose(matrix)[:status]
      end
    end
  end

  # Whatever the other copy reads (random words, other code words, the
  # unmasked variant), a symbol with one format copy at most 3 bits off its
  # code word decodes, in either orientation.
  def test_one_format_copy_within_three_bits_suffices
    rng = Random.new(71)
    300.times do |i|
      truth = rng.rand(32)
      text, matrix = symbol_for_format(rng, truth, [1, 2, 5, 7, 10][i % 5])
      good = FORMAT_CODES[truth] ^ random_error(rng, rng.rand(0..3))
      other = case i % 4
              when 0 then rng.rand(1 << 15)
              when 1 then FORMAT_CODES[rng.rand(32)] ^ random_error(rng, rng.rand(0..3))
              when 2 then FORMAT_CODES[truth] ^ random_error(rng, rng.rand(4..15))
              else FORMAT_CODES[rng.rand(32)] ^ 0x5412
              end
      i.odd? ? write_format_copies(matrix, good, other) : write_format_copies(matrix, other, good)
      matrix = matrix.transpose if (i / 2).odd?
      assert_equal text, Decoder.decode(matrix)&.text, "case #{i}: #{format('%015b %015b', good, other)}"
    end
  end

  # Full-capacity payloads whose parity codewords, read as data of the
  # weaker level (same block layout, so the stronger symbol's code words are
  # valid weaker ones too), parse into extra or different text.
  NESTED_LEVEL_TRAPS = [
    [1, :H, :L, "07215873479921415"], [1, :Q, :M, "004925020914316934336348268"],
    [2, :H, :L, "5620516770542677009791648967704996"],
    [4, :Q, :M, "8938805399576047816221358187810541547600924588751115574300002270501412248060415188700917874004" \
                "30827213241227341"]
  ].freeze

  # Format copies naming the weaker level (exactly) and the true, stronger
  # one (2 bits off) with the same mask: the weaker reading decodes too, so
  # the stronger one must win - else the result has the wrong level and,
  # here, wrong text.
  def test_weaker_level_reading_of_damaged_format_information
    rng = Random.new(74)
    NESTED_LEVEL_TRAPS.each do |version, strong, weak, digits|
      data = BitWriter.new.numeric(digits, version).to_data(QrReader::SymbolVersion[version].data_codewords(strong))
      mask = rng.rand(8)
      matrix = SymbolBuilder.build(data, version: version, level: strong, mask: mask)
      strong_code = FORMAT_CODES[(LEVEL_BITS[strong] << 3) | mask]
      weak_code = FORMAT_CODES[(LEVEL_BITS[weak] << 3) | mask]
      write_format_copies(matrix, weak_code, strong_code ^ random_error(rng, 2))
      [matrix, matrix.transpose].each do |m|
        result = Decoder.decode(m)
        assert_equal digits, result&.text, "v#{version} #{strong} read as #{weak}"
        assert_equal strong.downcase, result.ec_level
        assert_equal result, Decoder.diagnose(m)[:result]
      end
    end
  end

  # The dimension decides the version. Only when both version information
  # copies name the same other version is the grid rejected (the detector
  # sampled it at the wrong size); one copy damaged into another version's
  # code word, alone or next to an unreadable or different one, is not
  # enough. zxing-cpp ignores the version information entirely.
  def test_version_information_damaged_into_other_versions
    rng = Random.new(72)
    [7, 11, 22, 40].each do |version|
      text, data = nil
      text = payload(rng, :alphanumeric, 20)
      data = BitWriter.new.alphanumeric(text, version).to_data(QrReader::SymbolVersion[version].data_codewords(:M))
      clean = SymbolBuilder.build(data, version: version, level: :M, mask: version % 8)
      code = ->(v) { SymbolBuilder.bch(v, 6, 0x1F25, 18) }
      others = ((7..40).to_a - [version]).sample(2, random: rng)
      readable = [[code.call(others[0]), code.call(version)], [code.call(others[0]), 0],
                  [code.call(others[0]), code.call(others[1])], [0, code.call(others[1])]]
      readable.each do |top_right, bottom_left|
        [false, true].each do |swap|
          m = clean.dup
          write_version_copy(m, :top_right, swap ? bottom_left : top_right)
          write_version_copy(m, :bottom_left, swap ? top_right : bottom_left)
          where = "v#{version}: #{format('%018b %018b', top_right, bottom_left)}"
          assert_equal text, Decoder.decode(m)&.text, where
          assert_equal text, Decoder.decode(m.transpose)&.text, "#{where}, mirrored"
        end
      end
      m = clean.dup
      write_version_copy(m, :top_right, code.call(others[0]))
      write_version_copy(m, :bottom_left, code.call(others[0]) ^ 0b101) # 2 bits off, same version
      assert_nil Decoder.decode(m)
      diagnosis = Decoder.diagnose(m)
      assert_equal :version_info, diagnosis[:status]
      assert_equal [others[0], others[0]], diagnosis[:version_info]
    end
  end

  # --- diagnose agrees with decode ---------------------------------------

  # diagnose tries exactly what decode tries: :ok exactly when decode
  # returns a Result (the same one), on damaged symbols and garbage, with
  # and without mirrored readings.
  def test_diagnose_agrees_with_decode
    rng = Random.new(73)
    matrices = damaged_reference_cases.map { |spec, _| ZxingCppDamaged.build(spec) }
    matrices += Array.new(150) do |i|
      n = [21, 25, 45, 57][i % 4]
      QrReader::BitMatrix.new(n, n, rng.bytes(n * n).tr("\x80-\xFF".b, "\x01").tr("^\x01".b, "\x00"))
    end
    statuses = Hash.new(0)
    matrices.each_with_index do |matrix, i|
      [true, false].each do |try_mirrored|
        result = Decoder.decode(matrix, try_mirrored: try_mirrored)
        diagnosis = Decoder.diagnose(matrix, try_mirrored: try_mirrored)
        statuses[diagnosis[:status]] += 1
        assert_equal !result.nil?, diagnosis[:status] == :ok, "case #{i}, try_mirrored #{try_mirrored}"
        assert_equal result, diagnosis[:result] if result
        assert_includes Decoder::STATUSES, diagnosis[:status]
      end
    end
    %i[ok format_info reed_solomon].each { |status| assert_operator statuses[status], :>, 0, status }
  end

  def test_matrix_with_inconsistent_attributes
    odd = QrReader::BitMatrix.allocate
    odd.instance_variable_set(:@width, 21.0)
    odd.instance_variable_set(:@height, 21.0)
    odd.instance_variable_set(:@bits, "\0".b * 441)
    assert_nil Decoder.decode(odd)
    assert_equal :dimension, Decoder.diagnose(odd)[:status]
  end

  # --- damaged symbols compared with zxing-cpp ---------------------------

  DAMAGED_REFERENCE = File.join(__dir__, "fixtures", "zxing_cpp_damaged.jsonl")

  def damaged_reference_cases
    @damaged_reference_cases ||= File.foreach(DAMAGED_REFERENCE).map { |line| [JSON.parse(line), line] }
  end

  # Damaged symbols (codeword errors up to capacity + 1, format and version
  # information bit errors, mirrored ones) that zxing-cpp read or failed to
  # read (fixtures/generate_zxing_cpp_damaged.rb): we must read every one it
  # reads, with the same text, and never return wrong text.
  def test_reads_every_damaged_symbol_zxing_cpp_reads
    read = 0
    reference = 0
    damaged_reference_cases.each do |spec, line|
      matrix = ZxingCppDamaged.build(spec)
      assert_equal spec["crc"], Zlib.crc32(matrix.bits), "fixture grid differs (test builder changed?): #{line[0, 80]}"
      text = Decoder.decode(matrix)&.text
      expected = spec["zxing_cpp"]
      if expected
        reference += 1
        assert_equal spec["text"], expected
        assert_equal expected, text, line[0, 120]
      else
        assert_includes [nil, spec["text"]], text, line[0, 120]
      end
      read += 1 if text
    end
    assert_operator reference, :>=, 200
    assert_operator read, :>, reference
  end
end
