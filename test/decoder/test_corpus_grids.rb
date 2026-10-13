# frozen_string_literal: true

require "json"
require_relative "decoder_test_helper"

# Real-world symbols: module grids sampled (crudely, see
# fixtures/sample_corpus_grids.py) from the ZXing blackbox corpus images.
# Whatever decodes must match the corpus' expected text exactly - this covers
# kanji, Hanzi, Shift_JIS byte mode, control characters, large versions.
class TestDecoderCorpusGrids < Minitest::Test
  FIXTURES = File.join(__dir__, "fixtures", "corpus_grids.jsonl")
  CORPUS = File.expand_path("../corpus/zxing", __dir__)

  def grid(entry)
    n = entry["dimension"]
    rows = entry["rows"].map { |hex| [hex].pack("H*").unpack1("B*")[0, n] }
    QrReader::BitMatrix.from_rows(rows)
  end

  def test_sampled_corpus_grids
    skip "corpus not present (rake corpus:fetch)" unless Dir.exist?(File.join(CORPUS, "qrcode-1"))

    decoded = 0
    File.foreach(FIXTURES) do |line|
      entry = JSON.parse(line)
      expected = File.read(File.join(CORPUS, entry["image"].sub(/\.png\z/, ".txt")), encoding: "UTF-8")
      result = QrReader::Decoder.decode(grid(entry))
      next unless result

      assert_equal expected, result.text, entry["image"]
      decoded += 1
    end
    assert_operator decoded, :>=, 140
  end
end
