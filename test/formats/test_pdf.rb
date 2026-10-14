# frozen_string_literal: true

require "test_helper"

# PDF image extraction on documents written by real tools (ImageMagick,
# Ghostscript, qpdf; see test/fixtures/pdf/generate.rb).
class TestPdf < Minitest::Test
  DIR = File.expand_path("../fixtures/pdf", __dir__)
  PDF = QrReader::Formats::PDF
  MULTIPAGE = %w[magick_multipage gs_multipage qpdf_objstm qpdf_linearized qpdf_rc4_40 qpdf_rc4_128
                 qpdf_aes_128 qpdf_aes_256 qpdf_aes_256_r5].freeze

  def fixture(name)
    File.binread(File.join(DIR, name))
  end

  def source(name)
    @sources ||= {}
    @sources[name] ||= QrReader::Formats.decode(fixture(name))
  end

  def only_image(name)
    images = PDF.images(fixture("#{name}.pdf"))
    assert_equal 1, images.size, name
    images.first
  end

  def assert_pixels(expected, actual, message = nil, max: 0, mean: 0.0)
    assert_equal [expected.width, expected.height], [actual.width, actual.height], message
    diffs = expected.data.bytes.zip(actual.data.bytes).map { |a, b| (a - b).abs }
    assert_operator diffs.max, :<=, max, "#{message}: max difference"
    assert_operator diffs.sum.fdiv(diffs.size), :<=, mean, "#{message}: mean difference" if mean.positive?
  end

  def test_lossless_gray_filters
    %w[zip lzw rle none].each do |filter|
      assert_pixels source("src_gray.png"), only_image("magick_gray_#{filter}"), filter
    end
  end

  def test_gray_jpeg
    assert_pixels source("src_gray.png"), only_image("magick_gray_jpeg"), max: 40, mean: 3.0
  end

  def test_bilevel_ccitt_group4_group3_and_flate
    %w[group4 fax zip].each do |filter|
      assert_pixels source("src_bilevel.png"), only_image("magick_bilevel_#{filter}"), filter
    end
  end

  def test_scanned_a4_page_with_group4
    image = only_image("magick_page_group4")
    assert_pixels source("src_page.png"), image
  end

  def test_colour_images_become_luminance
    rgb = source("src_rgb.png")
    assert_pixels rgb, only_image("magick_rgb_zip"), "indexed"
    assert_pixels rgb, only_image("magick_cmyk_zip"), "cmyk", max: 1
    assert_pixels rgb, only_image("magick_rgb_jpeg"), "rgb jpeg", max: 40, mean: 2.0
    assert_pixels rgb, only_image("magick_cmyk_jpeg"), "Adobe cmyk jpeg", max: 40, mean: 2.0
    assert_pixels rgb, only_image("magick_palette_zip"), "16 colour palette", max: 30, mean: 3.0
  end

  # Ghostscript's conversion of a PostScript page that prints the image in
  # four bands: the bands are joined again.
  def test_image_bands_are_joined
    pairs = PDF.each_image(fixture("gs_bands.pdf")).to_a
    assert_equal 1, pairs.size
    assert_pixels source("src_gray.png"), pairs.first[0]
    assert_equal({ page: 0, name: "R7", width: 150, height: 140, pixel_aspect: 1.0, dpi: [48.0, 48.0] }, pairs.first[1])
  end

  def test_jpeg_data_is_decoded_unchanged
    expected = QrReader::Formats::JPEG.decode(fixture("src_scan.jpg"))
    assert_pixels expected, only_image("writer_jpeg")
  end

  def test_multipage_documents_in_all_structural_variants
    expected = [source("src_gray.png"), source("src_bilevel.png"), source("src_rgb.png")]
    MULTIPAGE.each do |name|
      pairs = PDF.each_image(fixture("#{name}.pdf")).to_a
      assert_equal [0, 1, 2], pairs.map { |_image, info| info[:page] }, name
      pairs.zip(expected).each do |(image, info), want|
        assert_pixels want, image, "#{name} page #{info[:page]}"
        assert_equal [image.width, image.height], [info[:width], info[:height]]
        assert_kind_of String, info[:name]
      end
    end
  end

  def test_each_image_yields_info_and_returns_an_enumerator_without_block
    enum = PDF.each_image(fixture("magick_multipage.pdf"))
    assert_kind_of Enumerator, enum
    image, info = enum.first
    assert_kind_of QrReader::Image, image
    assert_equal({ page: 0, name: "Im0", width: 150, height: 140, pixel_aspect: 1.0, dpi: [72.0, 72.0] }, info)
    seen = []
    assert_nil(PDF.each_image(fixture("magick_multipage.pdf")) { |_img, i| seen << i[:name] })
    assert_equal %w[Im0 Im1 Im2], seen
  end

  def test_breaking_out_of_each_image
    count = 0
    PDF.each_image(fixture("magick_multipage.pdf")) do
      count += 1
      break
    end
    assert_equal 1, count
  end

  # The palette is a string, which encrypted documents encrypt separately.
  def test_encrypted_strings
    palette = (0..255).map { |i| (i * 37 + 11) % 256 }
    expected = (0...(64 * 48)).map { |i| palette[(i * 7 + i / 64) % 256] }
    %w[writer_indexed qpdf_indexed_rc4 qpdf_indexed_aes128 qpdf_indexed_aes256].each do |name|
      assert_equal expected, only_image(name).data.bytes, name
    end
  end

  def test_password_protected_documents_are_unsupported
    error = assert_raises(QrReader::UnsupportedImageError) { PDF.images(fixture("qpdf_user_password.pdf")) }
    assert_match(/password/, error.message)
  end

  def test_reader_reads_codes_from_all_pages
    results = QrReader.read_all(File.join(DIR, "magick_multipage.pdf"))
    assert_equal ["PDF gray fixture", "PDF bilevel fixture", "PDF rgb fixture"], results.map(&:text)
    assert_equal [0, 1, 2], results.map(&:page)
    assert_equal "Scanned page fixture", QrReader.decode(File.join(DIR, "magick_page_group4.pdf"))
    assert_equal "JPEG scan fixture", QrReader.decode(StringIO.new(fixture("writer_jpeg.pdf")))
    assert_equal "PDF rgb fixture", QrReader.decode_all(File.join(DIR, "qpdf_aes_256.pdf")).last
  end

  def test_not_a_pdf
    assert_raises(QrReader::ImageError) { PDF.images("GIF89a not a pdf".b) }
    assert_raises(QrReader::ImageError) { PDF.images("".b) }
    assert_raises(QrReader::ImageError) { PDF.images(nil) }
  end
end
