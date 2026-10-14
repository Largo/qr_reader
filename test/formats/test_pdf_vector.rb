# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/pdf/pdf_writer"

# QR codes drawn as vector graphics (filled or stroked paths) in PDFs.
class TestPdfVector < Minitest::Test
  PDF = QrReader::Formats::PDF

  def matrix(text)
    QrTestHelper.rqr_matrix(text)
  end

  # "x y w h re" for each dark module of +m+ (or each horizontal run of
  # dark modules), +size+ points per module, bottom-left corner at x0, y0.
  def rects(m, size, x0, y0, runs: false, light: false)
    ops = []
    m.height.times do |y|
      x = 0
      while x < m.width
        if m.dark?(x, y) == light
          x += 1
          next
        end
        len = 1
        len += 1 while runs && x + len < m.width && m.dark?(x + len, y) != light
        ops << format("%.3f %.3f %.3f %.3f re", x0 + x * size, y0 + (m.height - 1 - y) * size, len * size, size)
        x += len
      end
    end
    ops
  end

  def pdf(content, resources = nil)
    PdfWriter.new.document([[content, resources]])
  end

  def test_one_rectangle_per_module
    bytes = pdf("0 0 0 rg\n#{rects(matrix('module by module'), 1.5, 100, 500).map { |r| "#{r} f" }.join("\n")}")
    assert_equal "module by module", QrReader.decode(bytes)

    pairs = PDF.each_image(bytes, vector: true).to_a
    assert_equal 1, pairs.size
    image, info = pairs.first
    assert_equal({ page: 0, name: nil, width: image.width, height: image.height, pixel_aspect: 1.0,
                   dpi: [192.0, 192.0], vector: true }, info)
    # Only raster images without vector: true.
    assert_empty PDF.images(bytes)
  end

  def test_runs_in_one_path_with_even_odd_rule_and_cmyk
    content = "q 0.2 0.1 0.3 0.9 k #{rects(matrix('runs'), 2, 50, 50, runs: true).join(' ')} f* Q"
    assert_equal "runs", QrReader.decode(pdf(content))
  end

  def test_light_modules_on_a_coloured_square
    m = matrix("light on blue")
    side = m.width * 1.2
    content = "0.43 0.67 0.84 rg 100 100 #{side} #{side} re f 1 g #{rects(m, 1.2, 100, 100, light: true).join(' ')} f"
    assert_equal "light on blue", QrReader.decode(pdf(content))
  end

  def test_rotated_and_scaled_form_xobject
    w = PdfWriter.new
    form = w.add({ Type: :XObject, Subtype: :Form, BBox: [0, 0, 100, 100], Matrix: [0, 2, -2, 0, 300, 100] },
                 stream: "0 0 1 RG 0 0 0.5 rg #{rects(matrix('turned'), 1, 10, 10).join(' ')} f")
    bytes = w.document([["q 0.5 0 0 0.5 0 0 cm /Fm Do Q", { XObject: { Fm: form } }]])
    assert_equal "turned", QrReader.decode(bytes)
  end

  def test_stroked_runs
    m = matrix("stroked")
    size = 1.5
    butt = []
    square = []
    m.height.times do |y|
      x = 0
      while x < m.width
        next x += 1 unless m.dark?(x, y)

        len = 1
        len += 1 while x + len < m.width && m.dark?(x + len, y)
        cy = 200 + (m.height - y - 0.5) * size
        butt << format("%.3f %.3f m %.3f %.3f l", 100 + x * size, cy, 100 + (x + len) * size, cy)
        square << format("%.3f %.3f m %.3f %.3f l", 100 + (x + 0.5) * size, cy, 100 + (x + len - 0.5) * size, cy)
        x += len
      end
    end
    assert_equal "stroked", QrReader.decode(pdf("#{size} w #{butt.join(' ')} S"))
    assert_equal "stroked", QrReader.decode(pdf("#{size} w 2 J #{square.join("\n")} S"))
  end

  # A circle of radius +r+ around cx, cy from four Bézier curves.
  def circle(cx, cy, r)
    k = 0.5523 * r
    format("%.3f %.3f m %.3f %.3f %.3f %.3f %.3f %.3f c %.3f %.3f %.3f %.3f %.3f %.3f c " \
           "%.3f %.3f %.3f %.3f %.3f %.3f c %.3f %.3f %.3f %.3f %.3f %.3f c h",
           cx + r, cy, cx + r, cy + k, cx + k, cy + r, cx, cy + r, cx - k, cy + r, cx - r, cy + k, cx - r, cy,
           cx - r, cy - k, cx - k, cy - r, cx, cy - r, cx + k, cy - r, cx + r, cy - k, cx + r, cy)
  end

  # "Dots" style: round modules; finder patterns as square rings (+finders:
  # :squares) or dots too.
  def dotted(m, size, x0, y0, finders:)
    finder = ->(x, y) { [[0, 0], [m.width - 7, 0], [0, m.height - 7]].any? { |fx, fy| (x - fx).between?(0, 6) && (y - fy).between?(0, 6) } }
    ops = []
    m.height.times do |y|
      m.width.times do |x|
        next unless m.dark?(x, y)

        if finders == :squares && finder.call(x, y)
          ops << format("%.3f %.3f %.3f %.3f re", x0 + x * size, y0 + (m.height - 1 - y) * size, size, size)
        else
          ops << circle(x0 + (x + 0.5) * size, y0 + (m.height - y - 0.5) * size, 0.45 * size)
        end
      end
    end
    ops.join(" ")
  end

  def test_round_dots
    m = matrix("dots and squares")
    assert_equal "dots and squares", QrReader.decode(pdf("0 g #{dotted(m, 1.5, 100, 100, finders: :squares)} f"))
    m = matrix("only dots")
    assert_equal "only dots", QrReader.decode(pdf("0 g #{dotted(m, 1.5, 100, 100, finders: :dots)} f"))
  end

  def test_two_codes_on_a_page
    content = ["0 g", *rects(matrix("left"), 1.5, 50, 600), "f", *rects(matrix("right"), 1.5, 300, 600), "f"].join(" ")
    assert_equal %w[left right], QrReader.read_all(pdf(content)).map(&:text).sort
  end

  def test_shapes_that_are_not_codes_are_not_rendered
    row = Array.new(60) { |i| "#{50 + i * 8} 700 5 5 re" }.join(" ")
    few = Array.new(10) { |i| "#{50 + i * 8} 400 5 5 re" }.join(" ")
    [row, few, "0 0 612 792 re", "50 50 m 60 60 l 70 50 l"].each do |content|
      assert_empty PDF.images(pdf("#{content} f")), content[0, 30]
      assert_empty PDF.each_image(pdf("#{content} f"), vector: true).to_a, content[0, 30]
    end
  end

  # Broken path operators neither raise nor cost the page its raster images.
  def test_garbage_paths
    garbage = ["1e999 0 m 5 5 l 9 0 l f", "re re f /X re f* h S", "0 0 0 0 re f 0 0 m S 2 J 3 3 m s",
               "1e999 0 0 1 0 0 cm 0 0 5 5 re f", "q 0 0 1e300 1e300 re f Q", "/Pattern CS /Nope cs 1 2 scn 0 0 5 5 re B",
               "0 0 m 1 1 2 2 3 3 c 4 4 v 5 5 y f", Array.new(100) { |i| "#{i} 0 m #{i} 1e300 l" }.join(" ") + " 3 w S"]
    w = PdfWriter.new
    img = w.image(width: 2, height: 1, data: "\x01\x02".b)
    garbage.each do |content|
      bytes = w.document([["#{content} q 2 0 0 1 0 0 cm /Im Do Q #{content}", { XObject: { Im: img } }]])
      assert_equal [[1, 2]], PDF.each_image(bytes, vector: true).map { |image, _| image.data.bytes }, content
      assert_nil QrReader.decode(bytes)
    end
  end

  # Painting order and colours: a white square painted over part of the
  # code hides it, clipping paths and pattern fills are ignored.
  def test_painting_order
    m = matrix("covered")
    content = "0 g #{rects(m, 2, 100, 100).join(' ')} f 1 g 100 100 #{m.width} #{m.width} re f"
    assert_nil QrReader.decode(pdf(content))
    content = "0 g #{rects(m, 2, 100, 100).join(' ')} f /Pattern cs /P0 scn 100 100 #{m.width} #{m.width} re f"
    assert_equal "covered", QrReader.decode(pdf(content))
  end
end
