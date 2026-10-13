# frozen_string_literal: true

require_relative "test_helper"

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
end
