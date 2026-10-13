# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/pdf/pdf_writer"
require_relative "../fixtures/pdf/jbig2_writer"

# JBIG2Decode: generic regions (arithmetic and MMR coding) and page
# composition. Streams come from test/fixtures/pdf/jbig2_writer.rb, whose
# output Ghostscript's jbig2dec renders exactly like the source bitmaps.
class TestPdfJbig2 < Minitest::Test
  DIR = File.expand_path("../fixtures/pdf", __dir__)
  PDF = QrReader::Formats::PDF
  J = Jbig2Writer
  W = 61
  H = 40

  def bitmap(width = W, height = H, density: 0.5, seed: 1)
    rng = Random.new(seed)
    bits = Array.new(width * height) do |i|
      x = i % width
      y = i / width
      (x / 5 + y / 3).even? && rng.rand < density ? 1 : 0
    end
    (10..13).each { |y| bits[y * width, width] = bits[9 * width, width] } if height > 13 # repeated rows
    bits
  end

  def pixels(bits) = bits.map { |b| b == 1 ? 0 : 255 }

  def decode(stream, width = W, height = H, globals: nil, mask: false)
    w = PdfWriter.new
    extra = { Filter: :JBIG2Decode }
    extra[:DecodeParms] = { JBIG2Globals: w.add({}, stream: globals) } if globals
    extra[:ImageMask] = true if mask
    img = w.image(width: width, height: height, data: stream, bpc: 1, color_space: mask ? nil : :DeviceGray,
                  extra: extra)
    images = PDF.images(w.document([["/Im0 Do", { XObject: { Im0: img } }]]))
    assert_equal 1, images.size
    images.first
  end

  def test_all_templates_with_and_without_typical_prediction
    bits = bitmap
    4.times do |template|
      [false, true].each do |typical|
        image = decode(J.stream(bits, W, H, template: template, typical: typical))
        assert_equal pixels(bits), image.data.bytes, "template #{template}, typical #{typical}"
      end
    end
  end

  def test_adaptive_pixels_off_their_nominal_positions
    bits = bitmap(seed: 2)
    [
      [0, [[2, -1], [-2, -2], [4, -2], [-5, -1]]],
      [0, [[-7, 0], [-3, -1], [2, -2], [-30, -9]]],
      [1, [[-6, -3]]],
      [2, [[0, -2]]],
      [3, [[5, -1]]]
    ].each do |template, at|
      image = decode(J.stream(bits, W, H, template: template, at: at, typical: true))
      assert_equal pixels(bits), image.data.bytes, "template #{template}, at #{at}"
    end
  end

  def test_region_composition
    a = bitmap(30, 20, seed: 3)
    b = bitmap(41, 30, density: 0.7, seed: 4)
    { 0 => ->(p, q) { p | q }, 1 => ->(p, q) { p & q }, 2 => ->(p, q) { p ^ q },
      3 => ->(p, q) { 1 ^ p ^ q }, 4 => ->(_p, q) { q } }.each do |op, combine|
      stream = J.segment(0, 48, J.page_information(W, H, override: true)) +
               J.segment(1, 38, J.generic_region(30, 20, data: J.generic_data(a, 30, 20))) +
               J.segment(2, 38, J.generic_region(41, 30, x: 20, y: 10, operator: op, data: J.generic_data(b, 41, 30)))
      expected = Array.new(W * H) do |i|
        x = i % W
        y = i / W
        p = x < 30 && y < 20 ? a[y * 30 + x] : 0
        x >= 20 && y >= 10 ? combine.call(p, b[(y - 10) * 41 + (x - 20)]) : p
      end
      assert_equal pixels(expected), decode(stream).data.bytes, "operator #{op}"
    end
  end

  def test_default_pixel_and_clipping
    b = bitmap(41, 30, seed: 5)
    stream = J.segment(0, 48, J.page_information(W, H, default_pixel: 1, operator: 2)) +
             J.segment(1, 38, J.generic_region(41, 30, x: 25, y: 15, operator: 2, data: J.generic_data(b, 41, 30)))
    expected = Array.new(W * H) do |i|
      x = i % W
      y = i / W
      x >= 25 && y >= 15 ? 1 ^ b[(y - 15) * 41 + (x - 25)] : 1
    end
    assert_equal pixels(expected), decode(stream).data.bytes
  end

  def test_striped_page_of_unknown_height
    top = bitmap(W, 20, seed: 6)
    bottom = bitmap(W, 20, density: 0.8, seed: 7)
    stream = J.segment(0, 48, J.page_information(W, 0xFFFFFFFF, stripe: 0x8000 | 20)) +
             J.segment(1, 38, J.generic_region(W, 20, data: J.generic_data(top, W, 20))) +
             J.segment(2, 50, [19].pack("N")) +
             J.segment(3, 38, J.generic_region(W, 20, y: 20, typical: true,
                                                     data: J.generic_data(bottom, W, 20, typical: true))) +
             J.segment(4, 50, [39].pack("N")) + J.segment(5, 49, "")
    assert_equal pixels(top + bottom), decode(stream).data.bytes
  end

  def test_unknown_data_length_and_globals
    bits = bitmap(seed: 8)
    region = J.generic_region(W, H, data: J.generic_data(bits, W, H)) + [H].pack("N")
    stream = J.segment(0, 48, J.page_information(W, H)) + [1, 38, 0, 1, 0xFFFFFFFF].pack("NCCCN") + region +
             J.segment(2, 49, "")
    assert_equal pixels(bits), decode(stream).data.bytes

    globals = J.segment(0, 62, "\x00\x00\x00\x01ext".b, page: 0) + J.segment(1, 53, "\x00".b * 9, page: 0)
    assert_equal pixels(bits), decode(J.stream(bits, W, H), globals: globals).data.bytes
  end

  def test_mmr_regions_and_masks
    image = PDF.images(File.binread(File.join(DIR, "writer_jbig2_mmr.pdf"))).first
    assert_equal QrReader::Formats.decode(File.binread(File.join(DIR, "src_bilevel.png"))).data, image.data

    bits = bitmap(seed: 9)
    assert_equal pixels(bits), decode(J.stream(bits, W, H), mask: true).data.bytes
  end

  def test_scanned_page_end_to_end
    page = QrReader::Formats.decode(File.binread(File.join(DIR, "src_page.png")))
    image = PDF.images(File.binread(File.join(DIR, "writer_jbig2_page.pdf"))).first
    assert_equal page.data, image.data
    assert_equal "Scanned page fixture", QrReader.decode(File.join(DIR, "writer_jbig2_page.pdf"))
  end

  def test_symbol_coding_is_unsupported
    bits = bitmap(seed: 10)
    text_region = J.segment(2, 6, "\x00".b * 30)
    error = assert_raises(QrReader::UnsupportedImageError) { decode(J.stream(bits, W, H) + text_region) }
    assert_match(/symbol coding/, error.message)
  end

  def test_damaged_streams
    stream = J.stream(bitmap(seed: 11), W, H, typical: true)
    [stream.byteslice(0, 10), stream.byteslice(0, 40), stream.byteslice(0, stream.bytesize - 20), "".b,
     stream.byteslice(30, stream.bytesize)].each do |damaged|
      PDF.images(PdfWriter.new.then do |w|
        img = w.image(width: W, height: H, data: damaged, bpc: 1, extra: { Filter: :JBIG2Decode })
        w.document([["/Im0 Do", { XObject: { Im0: img } }]])
      end)
    rescue QrReader::Error
      nil
    end
    huge = J.segment(0, 48, J.page_information(1 << 20, 1 << 20)) + J.segment(1, 38, "\x00".b * 30)
    assert_raises(QrReader::UnsupportedImageError) { decode(huge) }
  end
end
