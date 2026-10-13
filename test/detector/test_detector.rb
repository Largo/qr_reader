# frozen_string_literal: true

require_relative "detector_test_helper"

class TestDetector < Minitest::Test
  include DetectorTestHelper

  def test_versions_1_to_40
    [1, 2, 3, 5, 7, 9, 12, 16, 20, 24, 28, 33, 37, 40].each do |version|
      matrix = symbol(version)
      ms = version > 20 ? 2 : 3
      assert_detects(render(matrix, module_size: ms), matrix, tolerance: 0, message: "v#{version}", try_harder: false)
    end
  end

  def test_two_pixel_modules
    [2, 6, 10].each do |version|
      matrix = symbol(version)
      assert_detects(render(matrix, module_size: 2), matrix, message: "v#{version}")
    end
  end

  def test_fractional_module_sizes
    [[3, 1.6], [6, 2.4], [8, 3.3]].each do |version, ms|
      matrix = symbol(version)
      image = Distort.scale(render(matrix, module_size: 6), ms / 6)
      assert_detects(image, matrix, tolerance: 6, message: "v#{version} at #{ms} px")
    end
  end

  def test_quarter_turns_and_mirror
    matrix = symbol(4)
    image = render(matrix, module_size: 3)
    [90, 180, 270].each do |deg|
      # Rotated symbols are sampled in their own orientation.
      assert_detects(image.rotate(deg), matrix, tolerance: 0, message: "#{deg} degrees")
    end
    assert_detects(image.mirror, matrix, tolerance: 0, message: "mirrored")
  end

  def test_arbitrary_rotations
    [[2, 10], [5, 33], [7, 45], [10, 160], [14, 290]].each do |version, deg|
      matrix = symbol(version)
      image = Distort.rotate(render(matrix, module_size: 4), deg)
      assert_detects(image, matrix, message: "v#{version} rotated #{deg}")
    end
  end

  def test_perspective
    [[2, 0.15, 1], [4, 0.25, 2], [8, 0.25, 3], [12, 0.2, 4]].each do |version, strength, seed|
      matrix = symbol(version)
      image = Distort.perspective_tilt(render(matrix, module_size: 5), strength: strength, seed: seed)
      assert_detects(image, matrix, tolerance: 4, message: "v#{version} tilt #{strength}")
    end
  end

  def test_steep_perspective_with_differently_sized_finders
    matrix = symbol(6)
    image = render(matrix, module_size: 5)
    w = image.width
    steep = Distort.perspective(image, [[w * 0.05, w * 0.25], [w * 0.95, 0], [w * 0.95, w], [w * 0.05, w * 0.75]], w, w)
    assert_detects(steep, matrix, tolerance: 4)
  end

  def test_curvature_and_lens_distortion
    matrix = symbol(11)
    assert_detects(Distort.barrel(render(matrix, module_size: 4), k: 0.15), matrix, tolerance: 6, message: "barrel")
    matrix = symbol(3)
    image = Distort.cylinder(render(matrix, module_size: 5), arc: 100)
    assert_detects(image, matrix, tolerance: 6, message: "cylinder")
  end

  def test_strong_cylinder_curvature_uses_timing_warp
    # Modules near the edges of a 140 degree arc are a third as wide as in
    # the middle; only the displacement field measured on the timing
    # patterns follows that.
    matrix = symbol(10)
    image = Distort.cylinder(render(matrix, module_size: 4), arc: 140, bulge: 0.0)
    detector = QrReader::Detector.new(QrReader::Binarizer.hybrid(image), image: image)
    candidate = detector.each_candidate.first
    assert_operator module_errors(candidate.bits, matrix), :>, 100
    warped = candidate.send(:warped_sample, candidate.dimension, :parallelogram)
    assert_equal 0, module_errors(warped, matrix)
    assert_includes candidate.alternatives.to_a, warped
  end

  def test_noise_and_blur
    matrix = symbol(6)
    image = render(matrix, module_size: 5)
    assert_detects(Distort.gaussian_noise(image, sigma: 40, seed: 2), matrix, tolerance: 6, message: "noise")
    assert_detects(Distort.salt_pepper(image, amount: 0.03, seed: 3), matrix, tolerance: 12, message: "salt and pepper")
    assert_detects(Distort.blur(image, 1.5), matrix, tolerance: 2, message: "blur")
    assert_detects(Distort.motion_blur(image, length: 7, angle: 30), matrix, tolerance: 6, message: "motion blur")
  end

  def test_lighting
    matrix = symbol(5)
    image = render(matrix, module_size: 4)
    assert_detects(Distort.gradient(image, from: 1.0, to: 0.3, angle: 60), matrix, message: "gradient")
    assert_detects(Distort.shadow(image, darkness: 0.6, seed: 5), matrix, tolerance: 6, message: "shadow")
    assert_detects(render(matrix, module_size: 4, dark: 100, light: 150), matrix, message: "low contrast")
  end

  def test_light_on_dark
    matrix = symbol(3)
    image = Distort.invert(render(matrix, module_size: 4))
    assert_equal Float::INFINITY, best_errors(image, matrix)
    assert_detects(image, matrix, invert: true, tolerance: 0)
  end

  def test_inverted_matrix_with_original_image
    matrix = symbol(4)
    image = Distort.invert(render(matrix, module_size: 4))
    bits = QrReader::Binarizer.hybrid(image).invert
    detector = QrReader::Detector.new(bits, image: image)
    assert detector.inverted_image?
    refute QrReader::Detector.new(QrReader::Binarizer.hybrid(image), image: image).inverted_image?
    candidate = detector.each_candidate.first
    sampler = QrReader::Detector::GridSampler
    whole = sampler.whole(candidate.dimension, candidate.send(:transform_for, candidate.dimension, candidate.mode))
    grid = sampler.sample_luminance(image, candidate.dimension, whole, candidate.module_size, inverted: true)
    assert_equal 0, module_errors(grid, matrix)
  end

  def test_global_histogram_binarization
    matrix = symbol(7)
    assert_detects(Distort.rotate(render(matrix, module_size: 4), 12), matrix, binarizer: :global_histogram)
  end

  def test_heavy_motion_blur
    matrix = symbol(8)
    image = Distort.motion_blur(render(matrix, module_size: 5), length: 9, angle: 30)
    assert_detects(image, matrix, tolerance: 4)
  end

  def test_luminance_sampling
    # Low contrast with a strong gradient: thresholding module luminances
    # against their neighbourhood reproduces the grid exactly.
    matrix = symbol(5)
    ms = 4
    image = Distort.gradient(render(matrix, module_size: ms, dark: 90, light: 160), from: 1.0, to: 0.4)
    n = matrix.width
    t = QrReader::Detector::PerspectiveTransform.quad_to_quad(
      [[0, 0], [n, 0], [n, n], [0, n]], [[16, 16], [16 + n * ms, 16], [16 + n * ms, 16 + n * ms], [16, 16 + n * ms]]
    )
    sampler = QrReader::Detector::GridSampler
    assert_equal 0, module_errors(sampler.sample_luminance(image, n, sampler.whole(n, t), ms), matrix)
    assert_equal 0, module_errors(sampler.sample_luminance(image, n, sampler.whole(n, t), 2.0), matrix)
  end

  def test_multiple_symbols
    matrices = [symbol(2), symbol(4), symbol(3)]
    images = matrices.map { |m| render(m, module_size: 3) }
    images[1] = Distort.rotate(images[1], 30)
    width = images.sum(&:width) + 40
    height = images.map(&:height).max + 20
    x = 10
    placements = images.map { |img| [img, x, 10].tap { x += img.width + 10 } }
    scene = Distort.compose(width, height, placements)
    detector = QrReader::Detector.new(QrReader::Binarizer.hybrid(scene), image: scene)
    grids = detector.each_candidate(multi: true).flat_map { |c| [c.bits, *c.alternatives.first(3)] }
    matrices.each_with_index do |m, i|
      assert(grids.any? { |g| module_errors(g, m) <= 2 }, "symbol #{i} not found")
    end
  end

  def test_multi_skips_confirmed_symbols
    matrices = [symbol(2), symbol(3)]
    images = matrices.map { |m| render(m, module_size: 3) }
    scene = Distort.compose(images.sum(&:width) + 20, images.map(&:height).max,
                            [[images[0], 0, 0], [images[1], images[0].width + 20, 0]])
    detector = QrReader::Detector.new(QrReader::Binarizer.hybrid(scene), image: scene)
    yielded = []
    detector.each_candidate(multi: true) do |candidate|
      yielded << candidate
      detector.confirm(candidate) if matrices.any? { |m| module_errors(candidate.bits, m).zero? }
    end
    exact = yielded.count { |c| matrices.any? { |m| module_errors(c.bits, m).zero? } }
    assert_equal 2, exact
    # Nothing after a confirmation reuses its finder patterns.
    yielded.each_with_index do |c, i|
      next unless matrices.any? { |m| module_errors(c.bits, m).zero? }

      yielded[i + 1..].each { |later| refute(c.finder_patterns.any? { |p| later.finder_patterns.include?(p) }) }
    end
  end

  def test_candidate_interface
    matrix = symbol(5)
    ms = 4
    image = render(matrix, module_size: ms)
    detector = QrReader::Detector.new(QrReader::Binarizer.hybrid(image), image: image)
    enum = detector.each_candidate
    assert_kind_of Enumerator, enum
    candidate = enum.first
    assert_equal matrix, candidate.bits
    assert_equal matrix.width, candidate.dimension
    near = 4 * ms
    far = (4 + matrix.width) * ms
    [[near, near], [far, near], [far, far], [near, far]].zip(candidate.points).each do |(ex, ey), (x, y)|
      assert_in_delta ex, x, 1.0
      assert_in_delta ey, y, 1.0
    end
    assert_equal 3, candidate.finder_patterns.size
    assert_kind_of Enumerator, candidate.alternatives
    candidate.alternatives.each { |g| assert_kind_of QrReader::BitMatrix, g }
    assert_equal candidate.key, detector.each_candidate.first.key
  end

  def test_detect_pure
    matrix = symbol(6)
    image = render(matrix, module_size: 3)
    [0, 90, 180, 270].each do |deg|
      bits = QrReader::Binarizer.hybrid(image.rotate(deg))
      pure = QrReader::Detector.detect_pure(bits)
      assert pure, "rotation #{deg}"
      assert_equal matrix, pure.bits, "rotation #{deg}"
      assert_equal [], pure.alternatives.to_a
    end
    mirrored = QrReader::Detector.detect_pure(QrReader::Binarizer.hybrid(image.mirror))
    assert_equal matrix.transpose, mirrored.bits
    small = render(symbol(1), module_size: 1, quiet: 1)
    assert_equal symbol(1), QrReader::Detector.detect_pure(QrReader::Binarizer.hybrid(small)).bits
  end

  def test_detect_pure_rejects_other_images
    matrix = symbol(3)
    rotated = Distort.rotate(render(matrix, module_size: 4), 20)
    assert_nil QrReader::Detector.detect_pure(QrReader::Binarizer.hybrid(rotated))
    rng = Random.new(1)
    noise = QrReader::BitMatrix.new(100, 100, Array.new(10_000) { rng.rand(2) }.pack("C*"))
    assert_nil QrReader::Detector.detect_pure(noise)
    assert_nil QrReader::Detector.detect_pure(QrReader::BitMatrix.new(50, 50))
    two = Distort.compose(300, 150, [[render(matrix, module_size: 3), 0, 0], [render(matrix, module_size: 3), 150, 0]])
    assert_nil QrReader::Detector.detect_pure(QrReader::Binarizer.hybrid(two))
  end

  def test_garbage_never_raises
    rng = Random.new(42)
    matrices = [
      QrReader::BitMatrix.new(1, 1), QrReader::BitMatrix.new(1, 1, "\x01".b),
      QrReader::BitMatrix.new(3, 1000), QrReader::BitMatrix.new(1000, 3, "\x01".b * 3000),
      QrReader::BitMatrix.new(64, 64, "\x01".b * 4096),
      QrReader::BitMatrix.new(300, 200, Array.new(60_000) { rng.rand(2) }.pack("C*")),
      QrReader::BitMatrix.new(120, 120, Array.new(14_400) { |i| ((i % 120) / 3 + i / 360).odd? ? 1 : 0 }.pack("C*")),
      QrReader::BitMatrix.new(90, 90, Array.new(8100) { |i| (i % 90).between?(30, 59) ? 1 : 0 }.pack("C*"))
    ]
    # Many finder patterns in random places, some overlapping the border.
    rows = ["#######", "#.....#", "#.###.#", "#.###.#", "#.###.#", "#.....#", "#######"]
    finder = render(QrReader::BitMatrix.from_rows(rows), module_size: 3, quiet: 1)
    scene = Distort.compose(200, 200, Array.new(12) { [finder, rng.rand(173), rng.rand(173)] })
    matrices << QrReader::Binarizer.hybrid(scene)
    matrices.each do |m|
      QrReader::Detector.detect_pure(m)
      detector = QrReader::Detector.new(m)
      [false, true].each do |hard|
        detector.each_candidate(try_harder: hard, multi: hard) do |c|
          c.bits
          c.points
          c.alternatives.to_a
        end
      end
    end
    pass
  end

  def test_garbage_images_with_luminance
    rng = Random.new(7)
    [[50, 50], [333, 211]].each do |w, h|
      image = QrReader::Image.new(w, h, Array.new(w * h) { rng.rand(256) }.pack("C*"))
      detector = QrReader::Detector.new(QrReader::Binarizer.hybrid(image), image: image)
      detector.each_candidate(try_harder: true) { |c| c.alternatives.to_a }
    end
    pass
  end
end
