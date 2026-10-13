# frozen_string_literal: true

require_relative "decoder_test_helper"

class TestDecoderBitstreamParser < Minitest::Test
  BitWriter = DecoderTestHelper::BitWriter
  Parser = QrReader::Decoder::BitstreamParser
  FormatError = QrReader::Decoder::FormatError

  def parse(writer, version = 1, capacity: nil)
    Parser.parse(writer.to_data(capacity), version)
  end

  def bits(string)
    writer = BitWriter.new
    string.delete(" ").each_char { |c| writer.put(c.to_i, 1) }
    writer
  end

  # ISO/IEC 18004:2015 §7.4.4 example.
  def test_iso_numeric_example
    content = parse(bits("0001 0000001000 0000001100 0101011001 1000011"))
    assert_equal "01234567", content.text
    assert_equal "01234567".b, content.raw_bytes
    assert_equal [QrReader::Segment.new(mode: :numeric, text: "01234567", eci: nil)], content.segments
    assert_equal "]Q1", content.symbology_identifier
    assert_equal Encoding::UTF_8, content.text.encoding
    assert_equal Encoding::BINARY, content.raw_bytes.encoding
  end

  # ISO/IEC 18004:2015 §7.4.5 example.
  def test_iso_alphanumeric_example
    content = parse(bits("0010 000000101 00111001110 11100111001 000010"))
    assert_equal "AC-42", content.text
  end

  # ISO/IEC 18004:2015 §7.4.6 example: "点茗" in Kanji mode.
  def test_iso_kanji_example
    content = parse(bits("1000 00000010 0110110011111 1101010101010"))
    assert_equal "点茗", content.text
    assert_equal "\x93\x5F\xE4\xAA".b, content.raw_bytes
    assert_equal :kanji, content.segments.first.mode
  end

  def test_numeric_remainders_and_limits
    assert_equal "1", parse(BitWriter.new.numeric("1", 1)).text
    assert_equal "12", parse(BitWriter.new.numeric("12", 1)).text
    assert_equal "123", parse(BitWriter.new.numeric("123", 1)).text
    assert_equal "0000000", parse(BitWriter.new.numeric("0000000", 1)).text
    assert_equal "", parse(BitWriter.new.numeric("", 1)).text
    assert_equal "9" * 7089, parse(BitWriter.new.numeric("9" * 7089, 40), 40).text
    assert_raises(FormatError) { parse(BitWriter.new.put(1, 4).put(3, 10).put(1000, 10)) }
    assert_raises(FormatError) { parse(BitWriter.new.put(1, 4).put(2, 10).put(100, 7)) }
    assert_raises(FormatError) { parse(BitWriter.new.put(1, 4).put(1, 10).put(10, 4)) }
    assert_raises(FormatError) { parse(BitWriter.new.put(1, 4).put(4, 10).put(123, 10)) } # 24 bits, digit 4 missing
  end

  def test_character_count_lengths_per_version_range
    { 9 => 10, 10 => 12, 26 => 12, 27 => 14 }.each do |version, count_bits|
      writer = BitWriter.new.put(1, 4).put(3, count_bits).put(42, 10)
      assert_equal "042", parse(writer, version).text, "numeric v#{version}"
    end
    { 9 => 8, 10 => 16, 40 => 16 }.each do |version, count_bits|
      writer = BitWriter.new.put(4, 4).put(1, count_bits).put(0x41, 8)
      assert_equal "A", parse(writer, version).text, "byte v#{version}"
    end
    { 1 => 9, 10 => 11, 27 => 13 }.each do |version, count_bits|
      assert_equal "Z", parse(BitWriter.new.put(2, 4).put(1, count_bits).put(35, 6), version).text
    end
    { 1 => 8, 10 => 10, 27 => 12 }.each do |version, count_bits|
      assert_equal "点", parse(BitWriter.new.put(8, 4).put(1, count_bits).put(0x0D9F, 13), version).text
      assert_equal "啊", parse(BitWriter.new.put(13, 4).put(1, 4).put(1, count_bits).put(0x03C0, 13), version).text
    end
  end

  def test_alphanumeric_all_characters_and_invalid_values
    all = DecoderTestHelper::ALNUM
    assert_equal all, parse(BitWriter.new.alphanumeric(all, 1)).text
    assert_raises(FormatError) { parse(BitWriter.new.put(2, 4).put(2, 9).put(2025, 11)) }
    assert_raises(FormatError) { parse(BitWriter.new.put(2, 4).put(1, 9).put(45, 6)) }
  end

  # ZXing DecodedBitStreamParserTestCase#testSimpleByteMode / testSimpleSJIS.
  def test_byte_mode_guessing_like_zxing
    assert_equal "ñòó", parse(BitWriter.new.bytes("\xF1\xF2\xF3", 1)).text
    assert_equal "｡｢｣ﾐ", parse(BitWriter.new.bytes("\xA1\xA2\xA3\xD0", 1)).text
    assert_equal "Grüße 漢字", parse(BitWriter.new.bytes("Grüße 漢字", 1)).text
    assert_equal "日本語", parse(BitWriter.new.bytes("日本語".encode("Shift_JIS"), 1)).text
  end

  def test_byte_mode_unaligned_and_aligned
    data = (0..255).map(&:chr).join.b
    content = parse(BitWriter.new.bytes(data, 10), 10, capacity: 300)
    assert_equal data, content.raw_bytes
    assert content.text.valid_encoding?
    # aligned: 4 (mode) + 8 (count) + 4 bits of a previous segment = 16
    writer = BitWriter.new.numeric("7", 1).bytes("xyz", 1)
    assert_equal "7xyz", parse(writer).text
  end

  # ZXing DecodedBitStreamParserTestCase#testECI (ECI 2 = CP437).
  def test_eci_cp437
    content = parse(BitWriter.new.eci(2).bytes("\xA1\xA2\xA3", 1))
    assert_equal "íóú", content.text
    assert_equal 2, content.eci
    assert_equal "]Q2", content.symbology_identifier
    assert_equal 2, content.segments.first.eci
  end

  def test_eci_switches_encoding_for_following_segments
    writer = BitWriter.new
    writer.bytes("\xE9", 1)                                # before any ECI: ISO-8859-1 by default
    writer.eci(26).bytes("é", 1)                           # UTF-8
    writer.eci(7).bytes("Ж".encode("ISO-8859-5"), 1)       # Cyrillic
    writer.numeric("42", 1)
    writer.eci(25).bytes("Ω".encode("UTF-16BE"), 1)        # UTF-16BE
    writer.eci(20).bytes("漢".encode("Shift_JIS"), 1)
    writer.eci(29).bytes("汉".encode("GB18030"), 1)
    writer.eci(28).bytes("說".encode("Big5"), 1)
    writer.eci(30).bytes("한".encode("EUC-KR"), 1)
    writer.eci(24).bytes("ب".encode("Windows-1256"), 1)
    content = parse(writer, 5)
    assert_equal "ééЖ42Ω漢汉說한ب", content.text
    assert_equal 26, content.eci
    assert_equal [nil, 26, 7, 7, 25, 20, 29, 28, 30, 24], content.segments.map(&:eci)
    assert_equal "]Q2", content.symbology_identifier
  end

  def test_eci_designator_lengths
    assert_equal "é", parse(BitWriter.new.eci(3).bytes("\xE9", 1)).text
    content = parse(BitWriter.new.eci(899).bytes("\xE9\x00", 1))
    assert_equal 899, content.eci
    assert_equal "é\u0000", content.text
    assert_equal 811_799, parse(BitWriter.new.eci(811_799).bytes("a", 1)).eci
    assert_equal "é", parse(BitWriter.new.eci(12_345).bytes("\xE9", 1)).text # unknown: Latin-1
    assert_raises(FormatError) { parse(BitWriter.new.put(7, 4).put(0xE0, 8)) }
    assert_raises(FormatError) { parse(BitWriter.new.put(7, 4).put(0b110, 3).put(1_000_000, 21)) }
  end

  def test_kanji_mode_mixed_with_other_segments
    writer = BitWriter.new.kanji("漢字".encode("Shift_JIS"), 1).alphanumeric("ABC", 1).kanji("\x88\x9F".b, 1)
    content = parse(writer)
    assert_equal "漢字ABC亜", content.text
    assert_equal %i[kanji alphanumeric kanji], content.segments.map(&:mode)
    # E040.. range and an NEC extension character (only in Windows-31J)
    assert_equal "漾", parse(BitWriter.new.kanji("\xE0\x40".b, 1)).text
    assert_equal "①", parse(BitWriter.new.kanji("\x87\x40".b, 1)).text
  end

  def test_hanzi_gb2312
    text = "中文测试开"
    content = parse(BitWriter.new.hanzi(text.encode("GB2312"), 1))
    assert_equal text, content.text
    assert_equal :hanzi, content.segments.first.mode
    assert_equal text.encode("GB2312").b, content.raw_bytes
    # GB2312 A5A2 (katakana A) -> 0x0181 (ZXing testHanziLevel1)
    assert_equal "ア", parse(BitWriter.new.put(13, 4).put(1, 4).put(1, 8).put(0x0181, 13)).text
    assert_raises(FormatError) { parse(BitWriter.new.hanzi("中".encode("GB2312"), 1, subset: 2)) }
  end

  def test_fnc1_first_position_gs1
    writer = BitWriter.new.fnc1_first.numeric("01049123451234591", 2).alphanumeric("97A%%B%10", 2)
    content = parse(writer, 2)
    assert_equal "0104912345123459197A%B\x1D10", content.text
    assert_equal :first, content.fnc1
    assert_equal "]Q3", content.symbology_identifier
    # byte segments are untouched
    assert_equal "a%b", parse(BitWriter.new.fnc1_first.bytes("a%b", 1)).text
    assert_equal "]Q4", parse(BitWriter.new.eci(26).fnc1_first.bytes("x", 1)).symbology_identifier
    # without FNC1, % is literal
    assert_equal "A%%B%", parse(BitWriter.new.alphanumeric("A%%B%", 1)).text
  end

  def test_fnc1_second_position
    content = parse(BitWriter.new.fnc1_second(37).alphanumeric("AB%C", 1))
    assert_equal [:second, "37"], content.fnc1
    assert_equal "AB\x1DC", content.text
    assert_equal "]Q5", content.symbology_identifier
    assert_equal [:second, "05"], parse(BitWriter.new.fnc1_second(5).numeric("1", 1)).fnc1
    assert_equal [:second, "a"], parse(BitWriter.new.fnc1_second(197).numeric("1", 1)).fnc1
    assert_equal [:second, "Z"], parse(BitWriter.new.fnc1_second(190).numeric("1", 1)).fnc1
    assert_equal "]Q6", parse(BitWriter.new.eci(3).fnc1_second(1).numeric("1", 1)).symbology_identifier
    assert_raises(FormatError) { parse(BitWriter.new.fnc1_second(150)) }
  end

  def test_structured_append
    content = parse(BitWriter.new.structured_append(2, 4, 0x5A).bytes("part", 1))
    assert_equal QrReader::StructuredAppend.new(index: 2, count: 4, parity: 0x5A), content.structured_append
    assert_equal "part", content.text
    assert_equal "]Q1", content.symbology_identifier
    assert_raises(FormatError) { parse(BitWriter.new.put(3, 4).put(1, 8)) }
  end

  def test_terminator_and_short_tails
    assert_equal "1", parse(BitWriter.new.numeric("1", 1).terminator.put(0xFF, 8)).text
    # fewer than 4 bits left: implicit terminator, whatever their value
    data = BitWriter.new.numeric("12", 1).to_data # 4+10+7 = 21 bits -> 3 padding bits
    assert_equal "12", Parser.parse(data, 1).text
    assert_equal "12", Parser.parse(data.b.tap { |d| d.setbyte(2, d.getbyte(2) | 0x07) }, 1).text
    assert_equal "", Parser.parse("".b, 1).text
    assert_equal "", Parser.parse("\x00".b, 1).text
    # exactly full (v1-M: 128 bits), no room for a terminator
    data = BitWriter.new.numeric("1" * 34, 1).to_data
    assert_equal 16, data.bytesize
    assert_equal "1" * 34, Parser.parse(data, 1).text
  end

  def test_invalid_modes_and_truncated_segments
    [0b0110, 0b1010, 0b1011, 0b1100, 0b1110, 0b1111].each do |mode|
      assert_raises(FormatError) { parse(BitWriter.new.put(mode, 4).put(0, 12)) }
    end
    assert_raises(FormatError) { parse(BitWriter.new.put(4, 4).put(10, 8).put(0x41, 8)) }
    assert_raises(FormatError) { parse(BitWriter.new.put(8, 4).put(3, 8).put(1, 13)) }
    assert_raises(FormatError) { parse(BitWriter.new.put(1, 4).put(30, 10).put(1, 10)) }
    assert_raises(FormatError) { parse(BitWriter.new.put(2, 4).put(30, 9).put(1, 11)) }
    assert_raises(FormatError) { parse(BitWriter.new.put(1, 4).put(1, 5)) } # count cut short
    # padding after the data (0xEC 0x11) without terminator reads as invalid mode 1110
    data = BitWriter.new.alphanumeric("AB", 1).to_data # 24 bits, no room left for padding bits
    assert_equal "AB", Parser.parse(data, 1).text
    assert_raises(FormatError) { Parser.parse(data + "\xEC\x11".b, 1) }
  end

  def test_segments_split_multibyte_characters_are_joined_in_text
    writer = BitWriter.new.bytes("\xC3", 1).bytes("\xA9", 1)
    content = parse(writer)
    assert_equal "é", content.text
    assert_equal ["�", "�"], content.segments.map(&:text)
    assert_equal "\xC3\xA9".b, content.raw_bytes
  end

  def test_garbage_never_raises_anything_but_format_error
    rng = Random.new(20)
    ok = 0
    20_000.times do |i|
      data = rng.bytes(rng.rand(0..60))
      version = 1 + i % 40
      content = Parser.parse(data, version)
      assert content.text.valid_encoding?
      assert_equal Encoding::UTF_8, content.text.encoding
      ok += 1
    rescue FormatError
      nil
    end
    assert_operator ok, :>, 0
  end
end
