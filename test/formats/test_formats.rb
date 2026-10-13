# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require_relative "../fixtures/images/format_fixtures"

class TestFormats < Minitest::Test
  include FormatFixtures::Assertions

  F = QrReader::Formats

  SAMPLES = {
    png: "png_rgb8.png", gif: "gif_global.gif", bmp: "bmp_24bit.bmp", pnm: "pnm_p6.ppm"
  }.freeze

  def test_format_of_supported_formats
    SAMPLES.each { |format, name| assert_equal format, F.format_of(FormatFixtures.read(name)), name }
    %w[pnm_p1.pbm pnm_p2.pgm pnm_p3.ppm pnm_p4.pbm pnm_p5.pgm pam_rgb.pam].each do |name|
      assert_equal :pnm, F.format_of(FormatFixtures.read(name))
    end
    assert_equal :jpeg, F.format_of("\xFF\xD8\xFF\xE0\x00\x10JFIF".b)
    assert_equal :jpeg, F.format_of("\xFF\xD8\xFF\xDB".b)
    assert_equal :gif, F.format_of("GIF87a....".b)
  end

  def test_format_of_unknown_data
    [nil, 42, "", "x", "\x89PNG".b, "\xFF\xD8".b, "GIF90a".b, "BM", "BM#{'x' * 20}", "P9 1 1", "P61 1",
     "<html>", "RIFF\x00\x00\x00\x00WEBPVP8 ".b].each do |bytes|
      assert_nil F.format_of(bytes), bytes.inspect
    end
  end

  def test_decode_dispatches_on_magic_bytes
    SAMPLES.each_value do |name|
      assert_same_image FormatFixtures.expected(name), F.decode(FormatFixtures.read(name)), name
    end
  end

  def test_decode_hands_jpeg_and_scale_to_the_jpeg_decoder
    image = QrReader::Image.new(1, 1, "\x80".b)
    jpeg = "\xFF\xD8\xFF\xE0rest".b
    calls = []
    decoder = lambda do |bytes, scale:|
      calls << [bytes, scale]
      image
    end
    F::JPEG.stub(:decode, decoder) do
      assert_same image, F.decode(jpeg, scale: 4)
      assert_same image, F.decode(jpeg)
    end
    assert_equal [[jpeg, 4], [jpeg, 1]], calls
    F::JPEG.stub(:dimensions, ->(bytes) { [bytes.bytesize, 7] }) do
      assert_equal [jpeg.bytesize, 7], F.dimensions(jpeg)
    end
  end

  def test_scale_is_ignored_by_other_formats
    SAMPLES.each_value do |name|
      assert_same_image FormatFixtures.expected(name), F.decode(FormatFixtures.read(name), scale: 8), name
    end
  end

  def test_dimensions_of_every_fixture
    FormatFixtures.manifest.each do |name, entry|
      assert_equal [entry["width"], entry["height"]], F.dimensions(FormatFixtures.read(name)), name
    end
  end

  def test_dimensions_needs_only_the_header
    { "png_rgb8.png" => 33, "bmp_24bit.bmp" => 54, "pnm_p6.ppm" => 15, "gif_global.gif" => 13 + 192 + 8 + 10 }
      .each do |name, header|
        bytes = FormatFixtures.read(name)
        assert_equal F.dimensions(bytes), F.dimensions(bytes.byteslice(0, header)), name
      end
  end

  # [name in the error message, leading bytes]
  UNSUPPORTED = [
    ["WebP", "RIFF\x24\x00\x00\x00WEBPVP8 "],
    ["HEIC", "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00"],
    ["HEIF", "\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00"],
    ["AVIF", "\x00\x00\x00\x1CftypavifX"],
    ["JPEG XL", "\xFF\x0A\xFA\x7F"],
    ["JPEG XL", "\x00\x00\x00\x0CJXL \r\n\x87\n"],
    ["PFM", "PF\n1 1\n-1.0\n"],
    ["Photoshop", "8BPS\x00\x01"],
    ["SVG", "<?xml version=\"1.0\"?><svg/>"]
  ].freeze

  def test_jpeg2000_files_and_codestreams
    dir = File.expand_path("../fixtures/jpeg2000", __dir__)
    %w[gray_53.jp2 gray_raw.j2k].each do |name|
      bytes = File.binread(File.join(dir, name))
      assert_equal :jpeg2000, F.format_of(bytes), name
      image = F.decode(bytes)
      assert_equal QrReader::Formats::JPEG2000.decode(bytes).data, image.data, name
      assert_equal [image.width, image.height], F.dimensions(bytes), name
    end
    assert_raises(QrReader::ImageError) { F.decode("\x00\x00\x00\x0CjP  \r\n\x87\n".b) }
    assert_raises(QrReader::ImageError) { F.decode("\xFF\x4F\xFF\x51\x00".b) }
  end

  def test_tiff_and_pdf_decode_to_their_first_page
    tiff = Dir[File.expand_path("../fixtures/tiff/*.tif", __dir__)].min
    pdf = Dir[File.expand_path("../fixtures/pdf/*.pdf", __dir__)].min
    { tiff => :tiff, pdf => :pdf }.each do |path, format|
      bytes = File.binread(path)
      assert_equal format, F.format_of(bytes), path
      image = F.decode(bytes)
      assert_kind_of QrReader::Image, image
      assert_equal [image.width, image.height], F.dimensions(bytes), path
    end
  end

  def test_recognised_unsupported_formats
    UNSUPPORTED.each do |name, bytes|
      error = assert_raises(QrReader::UnsupportedImageError, name) { F.decode(bytes.b) }
      assert_match(/#{name}.*not supported.*convert/, error.message)
      assert_raises(QrReader::UnsupportedImageError, name) { F.dimensions(bytes.b) }
    end
  end

  def test_unknown_data_raises_image_error
    cases = [["", /empty/], ["hello world", /unrecognised.*68656c6c6f/], ["\0\0\0\0".b, /unrecognised/]]
    cases.each do |bytes, message|
      error = assert_raises(QrReader::ImageError) { F.decode(bytes) }
      refute_kind_of QrReader::UnsupportedImageError, error
      assert_match message, error.message
    end
    assert_raises(QrReader::ImageError) { F.decode(nil) }
    assert_raises(QrReader::ImageError) { F.decode(:png) }
    assert_raises(QrReader::ImageError) { F.dimensions("nope") }
  end

  def test_strings_in_other_encodings
    bytes = FormatFixtures.read("png_palette8_trns.png")
    expected = FormatFixtures.expected("png_palette8_trns.png")
    assert_same_image expected, F.decode(bytes.dup.force_encoding(Encoding::UTF_8))
    assert_same_image expected, F.decode(bytes.dup.force_encoding(Encoding::Shift_JIS).freeze)
  end

  def test_decoders_reject_other_formats
    png = FormatFixtures.read("png_rgb8.png")
    [F::GIF, F::BMP, F::PNM].each { |decoder| assert_raises(QrReader::ImageError) { decoder.decode(png) } }
    assert_raises(QrReader::ImageError) { F::PNG.decode(FormatFixtures.read("gif_global.gif")) }
  end

  def test_random_garbage_with_valid_magic_bytes
    rng = Random.new(42)
    prefixes = ["\x89PNG\r\n\x1A\n", "GIF89a", "GIF87a", "BM", "P1 ", "P2 ", "P3\n", "P4 ", "P5 ", "P6 ", "P7\n"]
    prefixes.each do |prefix|
      200.times do
        bytes = prefix.b + rng.bytes(rng.rand(1..120))
        assert_image_or_image_error(bytes) { |b| F.decode(b) }
        begin
          F.dimensions(bytes)
        rescue QrReader::ImageError
          nil
        end
      end
    end
  end
end
