# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/pdf/pdf_writer"

# JPXDecode (JPEG 2000) images in PDFs, and reading QR codes from them.
class TestPdfJpx < Minitest::Test
  PDF = QrReader::Formats::PDF
  J2K = QrReader::Formats::JPEG2000
  PAGE = File.binread(File.expand_path("../fixtures/pdf/qr_page.jp2", __dir__)) # see generate_jpx.rb
  RGB = File.binread(File.expand_path("../fixtures/jpeg2000/rgb_97_ict.jp2", __dir__))

  # The page decoded once for all tests.
  def page_image
    self.class.instance_variable_get(:@page) || self.class.instance_variable_set(:@page, J2K.decode(PAGE))
  end

  def jpx_pdf(jpx, extra = {})
    w = PdfWriter.new
    width, height = J2K.dimensions(jpx)
    img = w.add({ Type: :XObject, Subtype: :Image, Width: width, Height: height, Filter: :JPXDecode }.merge(extra),
                stream: jpx)
    w.document([["q 612 0 0 792 0 0 cm /Im0 Do Q", { XObject: { Im0: img } }]])
  end

  def test_images_decode_with_their_own_colour_information
    [PAGE, RGB].each do |jpx|
      assert_equal [J2K.decode(jpx).data], PDF.images(jpx_pdf(jpx)).map(&:data)
    end
  end

  # /ColorSpace in the image dictionary overrides the JP2 colour boxes.
  def test_pdf_colour_space_overrides
    comps = J2K.decode_components(RGB)
    first = PDF.images(jpx_pdf(RGB, ColorSpace: :DeviceGray, BitsPerComponent: 8)).first
    # Three components under a one-component space: the first is gray.
    assert_equal comps.components[0], first.data
    inverted = PdfWriter::Hex.new((0..255).map { |v| 255 - v }.pack("C*"))
    indexed = PDF.images(jpx_pdf(PAGE, ColorSpace: [:Indexed, :DeviceGray, 255, inverted])).first
    assert_equal page_image.data.bytes.map { |v| 255 - v }, indexed.data.bytes
  end

  # A JP2 palette is part of the JP2 colour information: under a PDF
  # /Indexed colour space the codestream values are the indices.
  def test_jp2_palette_under_a_pdf_indexed_colour_space
    palette = File.binread(File.expand_path("../fixtures/jpeg2000/palette.jp2", __dir__))
    indices = J2K.decode_components(palette, palette: false).components.first
    refute J2K.decode_components(palette, palette: false).palette_applied
    table = PdfWriter::Hex.new((0..255).map { |v| [v, v, v] }.flatten.pack("C*"))
    gray_ramp = PDF.images(jpx_pdf(palette, ColorSpace: [:Indexed, :DeviceRGB, 255, table])).first
    assert_equal indices, gray_ramp.data
    assert_equal J2K.decode(palette).data, PDF.images(jpx_pdf(palette)).first.data
  end

  def test_raw_jpx_for_the_reader
    image, info = PDF.each_image(jpx_pdf(PAGE), raw_jpeg: true).first
    assert_equal [:jpx, 1700, 2200], [info[:format], info[:width], info[:height]]
    assert_equal [1700, 2200], [image.width, image.height]
    assert_equal page_image.data, image.decode.data
    assert_equal [425, 550], [image.decode(reduce: 2).width, image.decode(reduce: 2).height]
  end

  def test_qr_code_in_a_jpx_page
    pdf = jpx_pdf(PAGE)
    assert_equal "JPX page", QrReader.decode(StringIO.new(pdf))
    assert_equal [["JPX page", 0]], QrReader.read_all(StringIO.new(pdf)).map { |r| [r.text, r.page] }
    assert_equal "JPX page", QrReader.decode(StringIO.new(PAGE)) # a standalone JP2 file
  end
end
