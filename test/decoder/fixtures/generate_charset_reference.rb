# frozen_string_literal: true

# Development-only fixture generator: charset_reference.json.
#
# Records zxing-cpp's decoding (text mode Plain) of
#   * byte-mode segments without ECI (its encoding guess), and
#   * every Kanji-mode code (lead bytes 0x81-0x9F, 0xE0-0xEA) and every
#     Hanzi-mode code (GB 2312 rows 0xA1-0xAA, 0xB0-0xF7),
# so that test_decoder_adversarial.rb can compare our character set handling
# with that reference without needing zxing-cpp at test time. The symbols are
# built with the test-side SymbolBuilder (not the library), rendered to PNG
# and read by bench/reference/zxcpp.py.
#
#   bundle exec ruby -Itest test/decoder/fixtures/generate_charset_reference.rb
#
# ZXCPP_PYTHON overrides the Python interpreter (a venv with zxing-cpp and Pillow).

require "json"
require "tmpdir"
require_relative "../decoder_test_helper"

module CharsetReference
  ROOT = File.expand_path("../../..", __dir__)
  OUTPUT = File.join(__dir__, "charset_reference.json")
  PYTHON = ENV.fetch("ZXCPP_PYTHON",
                     "/tmp/claude-1000/-home-andi-workspace/024a2597-ef40-4f4c-a25b-3210b1b14972/scratchpad/venv/bin/python")

  # Byte payloads for the encoding guess: Latin-1, Shift_JIS, UTF-8 (valid
  # and broken), binary with control characters, BOMs, and random bytes.
  def self.byte_payloads
    fixed = [
      "caf\xE9", "Gr\xFC\xDFe", "\xA9 2024", "\xA9 2024 copyright", "\x93quoted\x94", "\x80 100", "Gr\xC3\xBC\xC3\x9Fe",
      "\xEF\xBB\xBFbom utf8", "\xFE\xFF", "\xC0\x80 overlong", "\xED\xA0\x80 surrogate", "\xF4\x90\x80\x80 big",
      "\xF8\x88\x80\x80\x80", "\x93\xFA\x96\x7B\x8C\xEA", "\xC3\xBD\xC4", "\xC3\xBD", "a\xC3\xBDb", "\x8A\xBF",
      "\x8A\xBF\x8E\x9A", "\x82\xA0", "\x81\x5C\x81\x60", "\xA1\xA2\xA3\xD0", "\xE9\xE8\xE0 accents", "\xD7\xF7",
      "\xC4\xD6\xDC", "\x00\x01\x02\x03", "\xFF\xFF\xFF", "\x9F\xA0\xA1", "\xE3\x81\x82", "\xE3\x81",
      "mixed \xE3\x81\x82 and \xE9", "\xA0\xA0\xA0", "\xB1\xB2\xB3\x09", "\xB1\xB2\xB3\x0A", "\xB1\xB2\xB3\x0D",
      "\xB1\xB2\xB3\x00", "\xB1\xB2\xB3\x1F", "\xB1\xB2\xB3\x7F", "Gr\xC3\xBC\xC3\x9Fe\x01", "\xB1\xB2 x", "\xB1\xB2\x01x",
      "\x01\xA9 2024", "\x01caf\xE9", "\x82\xA0\x82\xA2\x82\xA4\x01", "\xE9\x01", "\x01\x82\xA0",
      "\x1B\x82\xA0\x82\xA2\x82\xA4", "\x82\xA0\x82\xA2\x82\xA4\r\n\x82\xA0"
    ].map(&:b)
    rng = Random.new(9)
    random = Array.new(60) { rng.bytes(rng.rand(1..12)) }
    latin = Array.new(40) do
      Array.new(rng.rand(1..10)) { [rng.rand(0x20..0x7E), rng.rand(0xA0..0xFF)].sample(random: rng) }.pack("C*")
    end
    kana = Array.new(20) do
      Array.new(rng.rand(1..8)) { [rng.rand(0x20..0x7E), rng.rand(0xA1..0xDF), 0x0A].sample(random: rng) }.pack("C*")
    end
    fixed + random + latin + kana
  end

  # Kanji-mode codes as 2-byte Shift_JIS Strings, in a fixed order.
  def self.kanji_codes
    ((0x81..0x9F).to_a + (0xE0..0xEA).to_a).flat_map do |hi|
      (0x40..0xFC).filter_map { |lo| [hi, lo].pack("CC") unless lo == 0x7F }
    end
  end

  # Hanzi-mode codes as 2-byte GB 2312 Strings, in a fixed order.
  def self.hanzi_codes
    ((0xA1..0xAA).to_a + (0xB0..0xF7).to_a).flat_map do |hi|
      (0xA1..0xFE).map { |lo| [hi, lo].pack("CC") }
    end
  end

  def self.symbol(writer)
    DecoderTestHelper::SymbolBuilder.build_stream(writer, version: 40, level: :L, mask: 2)
  end

  def self.run
    Dir.mktmpdir do |dir|
      images = []
      byte_payloads.each_with_index do |bytes, i|
        writer = DecoderTestHelper::BitWriter.new.bytes(bytes, 5)
        matrix = DecoderTestHelper::SymbolBuilder.build_stream(writer, version: 5, level: :M, mask: i % 8)
        images << [:bytes, i, write(dir, "b#{i}", matrix)]
      end
      { kanji: kanji_codes, hanzi: hanzi_codes }.each do |mode, codes|
        codes.each_slice(1500).with_index do |chunk, i|
          writer = DecoderTestHelper::BitWriter.new.public_send(mode, chunk.join, 40)
          images << [mode, i, write(dir, "#{mode}#{i}", symbol(writer))]
        end
      end
      results = read_with_zxing_cpp(images.map(&:last))
      fixture = { "bytes" => [], "kanji" => +"", "hanzi" => +"" }
      images.each_with_index do |(kind, i, path), k|
        text = results.fetch(k)
        abort "zxing-cpp could not read #{path}" unless text
        if kind == :bytes
          fixture["bytes"] << [byte_payloads[i].unpack1("H*"), text]
        else
          fixture[kind.to_s] << text
        end
      end
      File.write(OUTPUT, "#{JSON.generate(fixture)}\n")
    end
  end

  def self.write(dir, name, matrix)
    path = File.join(dir, "#{name}.png")
    QrTestHelper.write_png(QrTestHelper.render(matrix, module_size: 3), path)
    path
  end

  def self.read_with_zxing_cpp(paths)
    script = File.join(ROOT, "bench/reference/zxcpp.py")
    output = IO.popen([PYTHON, "-I", script, "--text-mode", "Plain", "--pure", *paths], &:read)
    output.lines.map { |line| JSON.parse(line)["results"].first&.fetch("text") }
  end
end

CharsetReference.run if $PROGRAM_NAME == __FILE__
