# frozen_string_literal: true

require "json"
require_relative "decoder_test_helper"

# Symbols encoded by zxing-cpp's writer (libzint: kanji mode, Shift_JIS and
# UTF-8 byte segments without ECI, GS1, binary, all masks), compared with
# zxing-cpp's own decoding. See fixtures/generate_zxing_cpp_symbols.py.
class TestDecoderZxingCppReference < Minitest::Test
  FIXTURES = File.join(__dir__, "fixtures", "zxing_cpp_symbols.jsonl")

  def test_decodes_like_zxing_cpp
    count = 0
    File.foreach(FIXTURES) do |line|
      expected = JSON.parse(line)
      matrix = QrReader::BitMatrix.from_rows(expected["rows"])
      result = QrReader::Decoder.decode(matrix)
      where = expected["text"][0, 40].inspect
      refute_nil result, where
      assert_equal expected["text"], result.text, where
      assert_equal [expected["bytes_hex"]].pack("H*"), result.raw_bytes, where
      # zxing-cpp reports the ECI modifier only in its ECI text mode; ZXing
      # (and we) always add it: ]Q1 -> ]Q2, ]Q3 -> ]Q4.
      symbology = expected["symbology_identifier"]
      symbology = symbology.succ if result.eci
      assert_equal symbology, result.symbology_identifier, where
      assert_equal expected["version"], result.version, where
      assert_equal expected["ec_level"], result.ec_level.to_s.upcase, where
      assert_equal expected["mask"], result.mask, where
      mirrored = QrReader::Decoder.decode(matrix.transpose)
      assert_equal expected["text"], mirrored.text
      count += 1
    end
    assert_operator count, :>=, 30
  end
end
