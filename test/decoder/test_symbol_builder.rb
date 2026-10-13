# frozen_string_literal: true

require_relative "decoder_test_helper"

# The test-side symbol builder must agree with rqrcode_core module for
# module; only then are builder-made symbols (kanji, ECI, ...) trustworthy.
class TestDecoderSymbolBuilder < Minitest::Test
  include DecoderTestHelper

  CASES = [
    [1, :L, "HELLO WORLD", :alphanumeric], [1, :H, "12345", :number], [2, :M, "hello", :byte_8bit],
    [5, :Q, "0123456789" * 3, :number], [7, :L, "VERSION SEVEN", :alphanumeric], [8, :H, "abc" * 5, :byte_8bit],
    [14, :M, "https://example.com/" * 3, :byte_8bit], [22, :Q, "9" * 200, :number],
    [32, :L, "MIXED $%*+-./: 42", :alphanumeric], [40, :H, "x" * 300, :byte_8bit]
  ].freeze

  def test_builder_matches_rqrcode
    CASES.each_with_index do |(version, level, text, mode), i|
      mask = i % 8
      expected = rqr(text, version: version, level: level, mask: mask, mode: mode)
      writer = BitWriter.new
      case mode
      when :number then writer.numeric(text, version)
      when :alphanumeric then writer.alphanumeric(text, version)
      else writer.bytes(text, version)
      end
      actual = SymbolBuilder.build_stream(writer, version: version, level: level, mask: mask)
      assert_equal expected, actual, "version #{version} level #{level} mask #{mask}"
    end
  end

  def test_rs_encoder_matches_rqrcode
    [[1, :L], [3, :Q], [10, :M], [27, :H], [40, :L]].each do |version, level|
      qr = RQRCodeCore::QRCode.new("x", level: level.downcase, size: version)
      data_list = qr.instance_variable_get(:@data_list)
      ecl = RQRCodeCore::QRERRORCORRECTLEVEL[level.downcase]
      expected = RQRCodeCore::QRCode.create_data(version, ecl, data_list)
      capacity = QrReader::SymbolVersion[version].data_codewords(level)
      data = BitWriter.new.bytes("x", version).to_data(capacity)
      assert_equal expected, SymbolBuilder.codewords(data, version, level), "version #{version} #{level}"
    end
  end
end
