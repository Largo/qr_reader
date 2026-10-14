# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

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

  # Short Strings that are neither a file nor image data: text is taken as a
  # missing path (like File.read), binary or invalid text as bad image data.
  def test_unrecognised_short_strings
    assert_raises(Errno::ENOENT) { QrReader.decode("no/such/scan.png") }
    ["not an image".b, "\xFF\xFEjunk".dup.force_encoding(Encoding::UTF_8)].each do |data|
      error = assert_raises(QrReader::ImageError, data.inspect) { QrReader.decode(data) }
      assert_match(/unrecognised image data/, error.message)
    end
  end

  def test_binary_path_strings_still_name_files
    Dir.mktmpdir do |dir|
      path = File.join(dir, "code.pgm")
      code = QrTestHelper.render(QrTestHelper.rqr_matrix("path"), module_size: 3)
      File.binwrite(path, "P5 #{code.width} #{code.height} 255\n#{Array.new(code.height) { |y| code.row(y) }.join}")
      assert_equal "path", QrReader.decode(path.b)
    end
  end
end
