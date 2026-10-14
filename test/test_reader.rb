# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "pathname"
require "open3"

# QrReader::Reader on images of unusual shape.
class TestReader < Minitest::Test
  # Long thin images (rules, banners, 17-row printer strips across a 600 dpi
  # page) must not be reduced through the pyramid until a side vanishes.
  def test_long_thin_images
    [[4961, 17], [17, 4961], [8000, 3], [3, 1]].each do |w, h|
      assert_empty QrReader.read_all(QrReader::Image.new(w, h, "\xFF".b * (w * h))), "#{w}x#{h}"
    end
  end

  def test_code_on_a_wide_image
    code = QrTestHelper.render(QrTestHelper.rqr_matrix("wide"), module_size: 3)
    rows = Array.new(code.height) { |y| ("\xFF".b * 3000) + code.row(y) + ("\xFF".b * 3000) }
    image = QrReader::Image.new(code.width + 6000, code.height, rows.join)
    assert_equal "wide", QrReader.decode(image)
  end

  # A String is always a file path, never image data; bytes come as an IO.
  # Image bytes passed as a String fail loudly instead of being sniffed, so
  # bytes that happen to spell a path are never read as one by mistake.
  def test_strings_are_paths_and_bytes_come_as_io
    code = QrTestHelper.render(QrTestHelper.rqr_matrix("path"), module_size: 3)
    pgm = "P5 #{code.width} #{code.height} 255\n#{Array.new(code.height) { |y| code.row(y) }.join}".b
    Dir.mktmpdir do |dir|
      path = File.join(dir, "code.pgm")
      File.binwrite(path, pgm)
      assert_equal "path", QrReader.decode(path)
      assert_equal "path", QrReader.decode(path.b)
      assert_equal "path", QrReader.decode(Pathname(path))
      File.open(path, "rb") { |file| assert_equal "path", QrReader.decode(file) }
    end
    assert_equal "path", QrReader.decode(StringIO.new(pgm))
    assert_equal ["path"], QrReader.scan(StringIO.new(pgm)).map(&:text)
    assert_equal "path", QrReader.read!(StringIO.new(pgm)).text
    blank = QrReader::Image.new(50, 50, "\xFF".b * 2500)
    error = assert_raises(QrReader::NotFoundError) { QrReader.read!(blank) }
    assert_equal "no QR code found", error.message
    out, status = Open3.capture2("ruby", "-I#{File.expand_path('../lib', __dir__)}",
                                 File.expand_path("../exe/qr_reader", __dir__), "-", stdin_data: pgm, binmode: true)
    assert_equal ["path\n", true], [out, status.success?]
    assert_equal code.width, QrReader.load_image(StringIO.new(pgm)).width

    error = assert_raises(ArgumentError) { QrReader.decode(pgm) }
    assert_match(/looks like image data.*StringIO/, error.message)
    assert_raises(ArgumentError) { QrReader.decode("\x89PNG\r\n\x1A\n\0\0".b) }
    assert_raises(Errno::ENOENT) { QrReader.decode("no/such/scan.png") }
    assert_raises(Errno::ENOENT) { QrReader.decode("not an image".b) }
    error = assert_raises(ArgumentError) { QrReader.decode(nil) }
    assert_match(/unsupported input NilClass/, error.message)
  end
end
