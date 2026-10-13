# frozen_string_literal: true

require_relative "detector_test_helper"

class TestBinarizer < Minitest::Test
  include DetectorTestHelper

  Binarizer = QrReader::Binarizer

  def uniform(width, height, value)
    QrReader::Image.new(width, height, value.chr.b * (width * height))
  end

  # Expected bits of a rendered symbol at module centres.
  def assert_module_centres(bits, matrix, module_size, quiet, tolerance: 0)
    wrong = 0
    matrix.height.times do |y|
      matrix.width.times do |x|
        px = (x + quiet) * module_size + module_size / 2
        py = (y + quiet) * module_size + module_size / 2
        wrong += 1 if bits.get(px, py) != matrix.get(x, y)
      end
    end
    assert wrong <= tolerance, "#{wrong} modules binarized wrongly"
  end

  def test_output_size_and_values
    image = render(symbol(3), module_size: 3)
    [Binarizer.hybrid(image), Binarizer.local_mean(image), Binarizer.global_histogram(image),
     Binarizer.threshold(image, 128)].each do |bits|
      assert_equal [image.width, image.height], [bits.width, bits.height]
      assert_equal image.width * image.height, bits.bits.count("\x00\x01")
    end
  end

  LOCAL = %i[hybrid local_mean].freeze

  def test_local_clean_symbol
    matrix = symbol(5)
    LOCAL.each { |m| assert_module_centres(Binarizer.public_send(m, render(matrix, module_size: 4)), matrix, 4, 4) }
  end

  def test_local_survive_strong_lighting_gradient
    matrix = symbol(4)
    image = Distort.gradient(render(matrix, module_size: 5), from: 1.0, to: 0.25, angle: 30)
    LOCAL.each { |m| assert_module_centres(Binarizer.public_send(m, image), matrix, 5, 4) }
  end

  def test_hybrid_handles_low_contrast_next_to_quiet_zone
    # local_mean whitens flat quiet zone blocks (black point min / 2), which
    # drags the thresholds of the symbol's border modules below 110.
    matrix = symbol(2)
    image = render(matrix, module_size: 4, dark: 110, light: 150)
    assert_module_centres(Binarizer.hybrid(image), matrix, 4, 4)
  end

  def test_local_large_modules_inside_dark_areas
    # 12 px modules: whole 8x8 blocks fall inside dark modules and must
    # take their neighbours' thresholds.
    matrix = symbol(1)
    LOCAL.each { |m| assert_module_centres(Binarizer.public_send(m, render(matrix, module_size: 12)), matrix, 12, 4) }
  end

  def test_local_uniform_images
    LOCAL.each do |m|
      assert_equal 0, Binarizer.public_send(m, uniform(64, 48, 255)).dark_count, m
      assert_equal 0, Binarizer.public_send(m, uniform(64, 48, 128)).dark_count, m
    end
    assert_equal 0, Binarizer.hybrid(uniform(64, 48, 0)).dark_count
    # ZXing's flat-block rule: half the minimum (0) still marks black pixels.
    assert_equal 64 * 48, Binarizer.local_mean(uniform(64, 48, 0)).dark_count
  end

  def test_hybrid_fills_flat_areas_from_nearest_threshold
    # A dark square larger than the 5x5 block window in a light image: its
    # inner blocks have no contrast nearby and inherit thresholds.
    data = "\xff".b * (120 * 120)
    20.upto(99) { |y| data[y * 120 + 20, 80] = "\x20".b * 80 }
    bits = Binarizer.hybrid(QrReader::Image.new(120, 120, data))
    assert_equal 1, bits.get(60, 60)
    assert_equal 0, bits.get(5, 5)
  end

  def test_local_odd_sizes_use_edge_blocks
    matrix = symbol(1)
    image = Distort.pad(render(matrix, module_size: 3), 3) # 87 + 6: not a multiple of 8
    refute_equal 0, image.width % 8
    LOCAL.each { |m| assert_module_centres(Binarizer.public_send(m, image), matrix, 3, 5) }
  end

  def test_small_images_fall_back_to_global
    image = render(symbol(1), module_size: 1, quiet: 2) # 25 x 25
    assert_equal Binarizer.global_histogram(image), Binarizer.hybrid(image)
    assert_equal Binarizer.global_histogram(image), Binarizer.local_mean(image)
  end

  def test_global_histogram_threshold_between_peaks
    matrix = symbol(3)
    image = render(matrix, module_size: 3, dark: 40, light: 200)
    point = Binarizer.global_black_point(image)
    assert_operator point, :>, 40
    assert_operator point, :<=, 200
    assert_module_centres(Binarizer.global_histogram(image), matrix, 3, 4)
  end

  def test_global_histogram_without_contrast_is_all_light
    assert_nil Binarizer.global_black_point(uniform(50, 50, 90))
    assert_equal 0, Binarizer.global_histogram(uniform(50, 50, 90)).dark_count
  end

  def test_threshold
    image = QrReader::Image.new(4, 1, [0, 99, 100, 255].pack("C*"))
    assert_equal "\x01\x01\x00\x00".b, Binarizer.threshold(image, 100).bits
    assert_equal "\x00\x00\x00\x00".b, Binarizer.threshold(image, 0).bits
    assert_equal "\x01\x01\x01\x01".b, Binarizer.threshold(image, 256).bits
    # Bytes that String#tr treats specially (\\, -, ^) are mapped too.
    tricky = QrReader::Image.new(3, 1, "\\-^".b)
    assert_equal "\x01\x01\x00".b, Binarizer.threshold(tricky, 94).bits
  end

  def test_degenerate_images
    [[1, 1], [3, 1000], [1000, 3], [39, 39], [40, 40], [41, 17]].each do |w, h|
      rng = Random.new(w * h)
      image = QrReader::Image.new(w, h, Array.new(w * h) { rng.rand(256) }.pack("C*"))
      %i[hybrid local_mean global_histogram].each do |method|
        bits = Binarizer.public_send(method, image)
        assert_equal [w, h], [bits.width, bits.height], "#{method} #{w}x#{h}"
      end
    end
  end
end
