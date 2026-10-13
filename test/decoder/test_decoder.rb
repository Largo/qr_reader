# frozen_string_literal: true

require_relative "decoder_test_helper"

# End-to-end decoding of complete module grids.
class TestDecoder < Minitest::Test
  include DecoderTestHelper

  Decoder = QrReader::Decoder
  MODES = %i[number alphanumeric byte_8bit].freeze
  SEGMENT_MODE = { number: :numeric, alphanumeric: :alphanumeric, byte_8bit: :byte }.freeze

  # Every version and level, with payloads of assorted modes and lengths
  # (from one character up to full capacity) and all eight masks.
  def test_all_versions_and_levels_from_rqrcode
    rng = Random.new(40)
    1.upto(40) do |version|
      LEVELS.each_with_index do |level, li|
        mode = MODES[(version + li) % 3]
        max = capacity(version, level, mode)
        length = [1, max, rng.rand(1..max), max / 2][(version + li) % 4].clamp(1, max)
        text = payload(rng, mode, length)
        mask = (version * 3 + li) % 8
        matrix = rqr(text, version: version, level: level, mask: mask, mode: mode)
        result = Decoder.decode(matrix)
        where = "v#{version} #{level} #{mode} len #{length} mask #{mask}"
        refute_nil result, where
        assert_equal text, result.text, where
        assert_equal text.b, result.raw_bytes, where
        assert_equal version, result.version
        assert_equal level.downcase, result.ec_level
        assert_equal mask, result.mask
        assert_equal 0, result.errors_corrected
        refute result.mirrored
        assert_nil result.points
        assert_nil result.eci
        assert_nil result.fnc1
        assert_nil result.structured_append
        assert_equal "]Q1", result.symbology_identifier
        assert_equal [QrReader::Segment.new(mode: SEGMENT_MODE[mode], text: text, eci: nil)], result.segments
      end
    end
  end

  def test_multi_segment_rqrcode
    segments = [{ data: "0123456789", mode: :number }, { data: "HELLO ", mode: :alphanumeric },
                { data: "wörld", mode: :byte_8bit }, { data: "42", mode: :number }]
    result = Decoder.decode(rqr(segments, version: 4, level: :M, mask: 5))
    assert_equal "0123456789HELLO wörld42", result.text
    assert_equal %i[numeric alphanumeric byte numeric], result.segments.map(&:mode)
  end

  def test_mirrored_symbols
    [[1, :L], [6, :H], [7, :M], [20, :Q]].each do |version, level|
      text = "MIRROR #{version}"
      matrix = rqr(text, version: version, level: level, mask: version % 8)
      mirrored = matrix.transpose
      result = Decoder.decode(mirrored)
      assert_equal text, result.text
      assert result.mirrored
      assert_nil Decoder.decode(mirrored, try_mirrored: false)
      diagnosis = Decoder.diagnose(mirrored)
      assert_equal :ok, diagnosis[:status]
      assert diagnosis[:mirrored]
    end
  end

  # Decoder.decode skips the second orientation when the first one had exact
  # format information; that relies on this property of the format code.
  def test_wrong_orientation_never_reads_an_exact_format_code
    LEVELS.each do |level|
      8.times do |mask|
        matrix = SymbolBuilder.build("\0".b * QrReader::SymbolVersion[1].data_codewords(level), version: 1, level: level,
                                                                                               mask: mask)
        bits = Decoder::FormatReader.format_bits(matrix.bits, 21, mirrored: true)
        assert_operator Decoder::FormatReader.decode_format(*bits)&.last || 4, :>=, 2, "#{level} mask #{mask}"
      end
    end
  end

  def test_mirrored_symbols_with_noise
    rng = Random.new(41)
    decoded = 0
    [[2, :H], [5, :Q], [8, :M]].each do |version, level|
      text = payload(rng, :byte_8bit, 12)
      clean = rqr(text, version: version, level: level, mask: rng.rand(8), mode: :byte_8bit).transpose
      cells = (0...clean.bits.bytesize).to_a
      40.times do
        noisy = flip_modules(clean, cells, rng.rand(1..cells.size / 25), rng)
        result = Decoder.decode(noisy)
        next unless result

        decoded += 1
        assert_equal text, result.text
        assert result.mirrored
      end
    end
    assert_operator decoded, :>, 60
  end

  def test_kanji_hanzi_eci_fnc1_structured_append_symbols
    w = BitWriter.new.structured_append(1, 3, 0x42).eci(26).bytes("Ünïcödé ", 3).fnc1_first
    w.kanji("漢字".encode("Shift_JIS"), 3).hanzi("中文".encode("GB2312"), 3).alphanumeric("A%B", 3)
    result = Decoder.decode(SymbolBuilder.build_stream(w, version: 3, level: :M, mask: 6))
    assert_equal "Ünïcödé 漢字中文A\x1DB", result.text
    assert_equal QrReader::StructuredAppend.new(index: 1, count: 3, parity: 0x42), result.structured_append
    assert_equal 26, result.eci
    assert_equal :first, result.fnc1
    assert_equal "]Q4", result.symbology_identifier
    assert_equal %i[byte kanji hanzi alphanumeric], result.segments.map(&:mode)
  end

  def test_shift_jis_byte_mode_without_eci
    text = "こんにちは世界"
    w = BitWriter.new.bytes(text.encode("Shift_JIS"), 2)
    assert_equal text, Decoder.decode(SymbolBuilder.build_stream(w, version: 2, level: :L, mask: 1)).text
  end

  def test_result_text_is_always_valid_utf8
    w = BitWriter.new.eci(26).bytes("ok \xFF\xFE broken".b, 2)
    result = Decoder.decode(SymbolBuilder.build_stream(w, version: 2, level: :L))
    assert result.text.valid_encoding?
    assert_equal "ok �� broken", result.text
    assert_equal "ok \xFF\xFE broken".b, result.raw_bytes
  end

  def test_empty_symbol
    result = Decoder.decode(SymbolBuilder.build_stream(BitWriter.new, version: 1, level: :H))
    assert_equal "", result.text
    assert_empty result.segments
  end

  def test_invalid_inputs
    assert_nil Decoder.decode(QrReader::BitMatrix.new(20, 20))
    assert_nil Decoder.decode(QrReader::BitMatrix.new(21, 25))
    assert_nil Decoder.decode(QrReader::BitMatrix.new(181, 181))
    assert_nil Decoder.decode(QrReader::BitMatrix.new(17, 17))
    assert_nil Decoder.decode(QrReader::BitMatrix.new(21, 21))
    assert_nil Decoder.decode(QrReader::BitMatrix.new(177, 177, "\x01".b * (177 * 177)))
    assert_raises(TypeError) { Decoder.decode(nil) }
    assert_equal :dimension, Decoder.diagnose(QrReader::BitMatrix.new(22, 22))[:status]
    # a module String that was resized after construction
    broken = QrReader::BitMatrix.new(21, 21)
    broken.bits << "\x00"
    assert_nil Decoder.decode(broken)
  end

  def test_cells_other_than_0_and_1_count_as_light
    matrix = rqr("TWO FIVE FIVE", version: 2, level: :Q, mask: 3)
    odd = QrReader::BitMatrix.new(matrix.width, matrix.height, matrix.bits.tr("\x00".b, "\xFE".b))
    assert_equal "TWO FIVE FIVE", Decoder.decode(odd).text
  end

  def test_diagnose_reports_stages
    matrix = rqr("DIAGNOSE ME", version: 8, level: :Q, mask: 2)
    ok = Decoder.diagnose(matrix)
    assert_equal :ok, ok[:status]
    assert_equal 8, ok[:version]
    assert_equal :q, ok[:ec_level]
    assert_equal 2, ok[:mask]
    assert_equal 0, ok[:format_distance]
    assert_equal [8, 8], ok[:version_info]
    assert_equal 6, ok[:blocks]
    assert_equal [0] * 6, ok[:block_errors]
    assert_equal "DIAGNOSE ME", ok[:result].text
    refute ok[:mirrored]

    far = (0...(1 << 15)).find { |w| QrReader::FormatInformation.decode(w).nil? }
    no_format = SymbolBuilder.build(BitWriter.new.to_data(19), version: 1, level: :L, mask: 0, format_bits: far)
    diagnosis = Decoder.diagnose(no_format, try_mirrored: false)
    assert_equal :format_info, diagnosis[:status]
    assert_equal [far, far], diagnosis[:format_bits]

    wrong_version = rqr("V", version: 9, level: :L, mask: 0)
    n = wrong_version.width
    [[n - 11, 0], [0, n - 11]].each do |x0, y0| # write version 10's info into both copies
      bits = QrReader::SymbolVersion[10].version_info_bits
      18.times do |i|
        x, y = x0 == 0 ? [i / 3, y0 + i % 3] : [x0 + i % 3, i / 3]
        wrong_version.set(x, y, bits[i])
      end
    end
    diagnosis = Decoder.diagnose(wrong_version, try_mirrored: false)
    assert_equal :version_info, diagnosis[:status]
    assert_equal [10, 10], diagnosis[:version_info]

    w = BitWriter.new.put(0b0110, 4)
    bad_stream = Decoder.diagnose(SymbolBuilder.build_stream(w, version: 1, level: :L), try_mirrored: false)
    assert_equal :bitstream, bad_stream[:status]
    assert_match(/invalid mode/, bad_stream[:error])

    damaged = SymbolBuilder.build(BitWriter.new.to_data(19), version: 1, level: :L, mask: 0,
                                  corrupt: ->(cw) { [0, 3, 6, 9].each { |i| cw[i] ^= 0xFF } })
    rs = Decoder.diagnose(damaged, try_mirrored: false)
    assert_equal :reed_solomon, rs[:status]
    assert_equal [nil], rs[:block_errors]
  end
end
