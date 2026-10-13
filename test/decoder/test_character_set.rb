# frozen_string_literal: true

require_relative "decoder_test_helper"

class TestDecoderCharacterSet < Minitest::Test
  CS = QrReader::Decoder::CharacterSet

  def test_eci_designators
    assert_equal Encoding::IBM437, CS.for_eci(0)
    assert_equal Encoding::IBM437, CS.for_eci(2)
    assert_equal Encoding::ISO_8859_1, CS.for_eci(1)
    assert_equal Encoding::ISO_8859_1, CS.for_eci(3)
    assert_equal Encoding::ISO_8859_2, CS.for_eci(4)
    assert_equal Encoding::ISO_8859_10, CS.for_eci(12)
    assert_equal Encoding::ISO_8859_11, CS.for_eci(13)
    assert_nil CS.for_eci(14) # ISO-8859-12 does not exist
    assert_equal Encoding::ISO_8859_13, CS.for_eci(15)
    assert_equal Encoding::ISO_8859_16, CS.for_eci(18)
    assert_nil CS.for_eci(19)
    assert_equal Encoding::Shift_JIS, CS.for_eci(20)
    assert_equal Encoding::Windows_1250, CS.for_eci(21)
    assert_equal Encoding::Windows_1256, CS.for_eci(24)
    assert_equal Encoding::UTF_16BE, CS.for_eci(25)
    assert_equal Encoding::UTF_8, CS.for_eci(26)
    assert_equal Encoding::US_ASCII, CS.for_eci(27)
    assert_equal Encoding::US_ASCII, CS.for_eci(170)
    assert_equal Encoding::Big5, CS.for_eci(28)
    assert_equal Encoding::GB18030, CS.for_eci(29)
    assert_equal Encoding::EUC_KR, CS.for_eci(30)
    assert_equal Encoding::BINARY, CS.for_eci(899)
    assert_nil CS.for_eci(31)
  end

  def test_guess
    assert_equal Encoding::ISO_8859_1, CS.guess("plain ascii".b)
    assert_equal Encoding::UTF_8, CS.guess("Grüße".b)
    assert_equal Encoding::UTF_8, CS.guess("\xEF\xBB\xBFabc".b)
    assert_equal Encoding::ISO_8859_1, CS.guess("Gr\xFC\xDFe".b)
    assert_equal Encoding::ISO_8859_1, CS.guess("caf\xE9".b)
    assert_equal Encoding::Shift_JIS, CS.guess("日本語".encode("Shift_JIS").b)
    assert_equal Encoding::Shift_JIS, CS.guess("\xB1\xB2\xB3".b) # half-width katakana run
    assert_equal Encoding::Shift_JIS, CS.guess("\xB1\xB2 x".b)   # exactly two katakana
    assert_equal Encoding::Shift_JIS, CS.guess("a\x82\xA0".b)   # 0x80..0x9F rules out Latin-1
    assert_equal Encoding::UTF_16BE, CS.guess("\xFE\xFF\x00A".b)
    assert_equal Encoding::UTF_16LE, CS.guess("\xFF\xFE\x41\x00".b)
    assert_equal Encoding::ISO_8859_1, CS.guess("\x80\x81\xFF".b) # nothing fits: lossless fallback
    # Mostly Latin-1 symbols (>= 10% in 0xA0..0xBF, ×, ÷): ZXing picks Shift_JIS
    assert_equal Encoding::Shift_JIS, CS.guess("\xA9 2024".b)
  end

  def test_to_utf8
    assert_equal "abc", CS.to_utf8("abc".b, Encoding::ISO_8859_1)
    assert_equal "é", CS.to_utf8("\xE9".b, Encoding::ISO_8859_1)
    assert_equal "a�b", CS.to_utf8("a\xFFb".b, Encoding::UTF_8)
    assert_equal "é\u0000", CS.to_utf8("\xE9\x00".b, Encoding::BINARY)
    assert_equal "AB", CS.to_utf8("\x00A\x00B".b, Encoding::UTF_16BE)
    assert_equal "A", CS.to_utf8("\xFE\xFF\x00A".b, Encoding::UTF_16BE)
    assert_equal "A�", CS.to_utf8("\x00A\x00".b, Encoding::UTF_16BE)
    assert_equal "〜", CS.to_utf8("\x81\x60".b, Encoding::Shift_JIS) # JIS X 0208 mapping (like Java)
    assert_equal "①", CS.to_utf8("\x87\x40".b, Encoding::Shift_JIS) # NEC extension via Windows-31J
    assert_equal "�", CS.to_utf8("\x81".b, Encoding::Shift_JIS)
    assert_equal "�", CS.to_utf8("\x80".b, Encoding::US_ASCII)
  end

  def test_random_bytes_always_give_valid_utf8
    rng = Random.new(30)
    encodings = CS::ECI_ENCODINGS.values.uniq + [Encoding::UTF_16LE, CS::GB18030, CS::WINDOWS_31J]
    encodings.each do |encoding|
      200.times do
        bytes = rng.bytes(rng.rand(0..12))
        text = CS.to_utf8(bytes, encoding)
        assert_equal Encoding::UTF_8, text.encoding
        assert text.valid_encoding?, "#{encoding}: #{bytes.inspect}"
      end
    end
    500.times do
      bytes = rng.bytes(rng.rand(1..20))
      assert CS.to_utf8(bytes, CS.guess(bytes)).valid_encoding?
    end
  end
end
