# frozen_string_literal: true

require_relative "detector_test_helper"

class TestFinderPatternFinder < Minitest::Test
  include DetectorTestHelper

  def finders(image, try_harder: true)
    bits = QrReader::Binarizer.hybrid(image)
    QrReader::Detector::FinderPatternFinder.new(bits).find(try_harder: try_harder)
  end

  # Finder centres of an axis-aligned rendering, in pixel coordinates.
  def expected_centres(dimension, module_size, quiet)
    near = (quiet + 3.5) * module_size
    far = (quiet + dimension - 3.5) * module_size
    [[near, near], [far, near], [near, far]]
  end

  def assert_centres(found, expected, tolerance)
    expected.each do |x, y|
      best = found.min_by { |f| f.distance_to(x, y) }
      assert best, "no pattern near (#{x}, #{y})"
      assert_operator best.distance_to(x, y), :<=, tolerance, "pattern near (#{x}, #{y}) is at #{best.inspect}"
    end
  end

  def test_axis_aligned_positions_and_module_size
    [[1, 2], [3, 3], [5, 4], [10, 7]].each do |version, ms|
      matrix = symbol(version)
      found = finders(render(matrix, module_size: ms))
      assert_centres(found, expected_centres(matrix.width, ms, 4), 0.6)
      found.max_by(3, &:count).each { |f| assert_in_delta ms, f.module_size, ms * 0.12 }
    end
  end

  def test_quarter_turns
    matrix = symbol(4)
    image = render(matrix, module_size: 3)
    [90, 180, 270].each do |deg|
      found = finders(image.rotate(deg))
      assert_operator found.size, :>=, 3, "rotation #{deg}"
    end
  end

  def test_rotation_compensated_module_size
    matrix = symbol(3)
    [20, 45].each do |deg|
      found = finders(Distort.rotate(render(matrix, module_size: 6), deg))
      assert_operator found.size, :>=, 3
      found.max_by(3, &:count).each { |f| assert_in_delta 6.0, f.module_size, 0.8, "#{deg} degrees: #{f.inspect}" }
    end
  end

  def test_fast_mode_finds_typical_symbols_and_is_cached
    matrix = symbol(5)
    bits = QrReader::Binarizer.hybrid(render(matrix, module_size: 4))
    finder = QrReader::Detector::FinderPatternFinder.new(bits)
    fast = finder.find(try_harder: false)
    assert_equal 3, fast.size
    fast_hits = fast.sum(&:count)
    hard = finder.find(try_harder: true)
    assert_equal 3, hard.size
    assert_operator hard.sum(&:count), :>, fast_hits
  end

  def test_tiny_modules
    matrix = symbol(2)
    found = finders(Distort.scale(render(matrix, module_size: 6), 1.5 / 6))
    assert_operator found.size, :>=, 3
  end

  def test_noisy_finder_patterns
    matrix = symbol(6)
    image = Distort.salt_pepper(render(matrix, module_size: 5), amount: 0.03, seed: 4)
    assert_operator finders(image).size, :>=, 3
  end

  def test_symbol_touching_the_image_border
    matrix = symbol(2)
    found = finders(render(matrix, module_size: 4, quiet: 0))
    assert_centres(found, expected_centres(matrix.width, 4, 0), 0.6)
  end

  def test_no_patterns_in_noise_or_uniform_images
    rng = Random.new(3)
    noise = QrReader::Image.new(200, 150, Array.new(200 * 150) { rng.rand(256) }.pack("C*"))
    assert_operator finders(noise).size, :<, 10
    assert_empty finders(QrReader::Image.new(64, 64, "\xff".b * 4096))
    assert_empty finders(QrReader::Image.new(64, 64, "\x00".b * 4096))
  end
end
