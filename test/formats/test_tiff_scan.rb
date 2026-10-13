# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "../fixtures/tiff/tiff_fixtures"

# Reading QR codes from scanned TIFF documents through the public API.
class TestTIFFScan < Minitest::Test
  TIFF = QrReader::Formats::TIFF
  A4 = File.join(TiffFixtures::DIR, "scan_a4_g4.tif")

  def test_a4_group4_scan
    text = TiffFixtures.manifest["scan_a4_g4.tif"]["pages"][0]["text"]
    result = QrReader.read(A4)
    assert_equal text, result.text
    assert_equal 0, result.page
    assert_equal text, QrReader.decode(StringIO.new(File.binread(A4)))
  end

  # Bilevel pages with codes on the first and third page (the second one is
  # blank), as one Group 4 strip each.
  def multi_page_scan
    pages = ["page one", nil, "page three"].map do |text|
      rows = Array.new(300) { Array.new(320, 0) }
      if text
        image = QrTestHelper.render(QrTestHelper.rqr_matrix(text), module_size: 6)
        image.height.times { |y| image.width.times { |x| rows[y + 10][x + 20] = image[x, y] < 128 ? 1 : 0 } }
      end
      tags = { 256 => 320, 257 => 300, 258 => 1, 259 => 4, 262 => 0, 254 => 2 }
      { tags: tags, chunks: [TiffFixtures::CcittEncoder.encode(rows, k: -1)] }
    end
    TiffFixtures::TiffWriter.build(pages, endian: :big)
  end

  def test_multi_page_scan
    bytes = multi_page_scan
    assert_equal 3, TIFF.page_count(bytes)
    results = QrReader.read_all(bytes)
    assert_equal([["page one", 0], ["page three", 2]], results.map { |r| [r.text, r.page] })
    assert_equal "page one", QrReader.decode(bytes)
    first = QrReader.scan(bytes).first
    assert_equal ["page one", 0], [first.text, first.page]
  end

  def test_a4_page_decodes_quickly
    bytes = File.binread(A4)
    TIFF.decode(bytes) # warm-up
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    image = TIFF.decode(bytes)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal [2480, 3508], [image.width, image.height]
    assert_operator elapsed, :<, 1.5, "A4 Group 4 TIFF took #{elapsed.round(3)} s"
  end
end
