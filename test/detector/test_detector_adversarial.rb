# frozen_string_literal: true

require_relative "detector_test_helper"
require "zlib"

# Adversarial tests for the detector: inputs built to break specific
# assumptions (edges on the binarizer's block grid, non-square pixels, ink
# bleed, sheets of labels, extreme transforms, garbage), checked against
# independent references: rqrcode_core matrices, a fax page rendered by
# ScanSim through ImageMagick, and plain Float reimplementations.
class TestDetectorAdversarial < Minitest::Test
  include DetectorTestHelper

  Binarizer = QrReader::Binarizer
  Detector = QrReader::Detector
  GridSampler = QrReader::Detector::GridSampler
  PerspectiveTransform = QrReader::Detector::PerspectiveTransform
  FIXTURES = File.expand_path("fixtures", __dir__)

  # Payload of the ScanSim fax fixture (a Swiss QR-bill header).
  FAX_TEXT = "SPC\n0200\n1\nCH4431999123000889012\nS\nRobert Schneider AG\nRue du Lac\n1268\n2501\nBiel\nCH\n" \
             "\n\n\n\n\n\n1954.75\nCHF"

  def gray(width, height)
    QrReader::Image.new(width, height, Array.new(width * height) { |i| yield(i % width, i / width) }.pack("C*"))
  end

  # --- binarizer ----------------------------------------------------------

  def test_hybrid_module_edges_on_the_block_grid
    # Module sizes that are multiples of 8 with a 4 module quiet zone put
    # every edge exactly on the 8x8 block grid, so no block has contrast
    # of its own (this used to binarize to all light).
    matrix = symbol(2)
    [8, 16, 24, 40].each do |ms|
      image = render(matrix, module_size: ms)
      bits = Binarizer.hybrid(image)
      assert_equal image.data.count("\x00"), bits.dark_count, "#{ms} px modules"
      assert_equal matrix, Detector.detect_pure(bits)&.bits, "pure path at #{ms} px"
    end
  end

  def test_hybrid_low_contrast_edges_on_the_block_grid
    matrix = symbol(3)
    image = render(matrix, module_size: 8, dark: 90, light: 150)
    assert_equal matrix, Detector.detect_pure(Binarizer.hybrid(image))&.bits
  end

  def test_hybrid_step_on_a_block_boundary
    image = gray(64, 48) { |x, _| x < 32 ? 40 : 200 }
    bits = Binarizer.hybrid(image)
    assert_equal 32 * 48, bits.dark_count
    assert_equal 1, bits.get(31, 20)
    assert_equal 0, bits.get(32, 20)
  end

  def test_hybrid_does_not_invent_edges_in_smooth_gradients
    # Neighbouring flat blocks of a ramp of up to 3 grey levels per pixel
    # have touching luminance ranges: no edge, nothing turns dark.
    [1, 2, 3].each do |slope|
      [gray(80, 48) { |x, _| 250 - slope * x }, gray(48, 80) { |_, y| 250 - slope * y },
       gray(80, 80) { |x, y| 250 - slope * (x + y) / 2 }].each do |image|
        assert_equal 0, Binarizer.hybrid(image).dark_count, "slope #{slope}"
      end
    end
  end

  # --- non-square pixels: fax pages --------------------------------------

  def test_fax_standard_resolution
    # 204 x 98 dpi: modules about twice as wide as tall, skewed on the
    # glass; turned by 90 degrees they are twice as tall as wide.
    [[3, 0], [5, 2.5], [7, -4], [10, 6]].each do |version, skew|
      matrix = symbol(version, level: :M)
      base = render(matrix, module_size: 8)
      skewed = skew.zero? ? base : Distort.rotate(base, skew)
      image = Distort.resize(skewed, skewed.width, (skewed.height * 98 / 204.0).round)
      assert_detects(image, matrix, tolerance: 2, message: "v#{version} skew #{skew}")
      assert_detects(image.rotate(90), matrix, tolerance: 2, message: "v#{version} skew #{skew} turned")
    end
  end

  def test_fax_page_rendered_by_the_scan_simulator
    # Crop of a ScanSim page: printed, scanned at 204 x 98 dpi, skewed by
    # 2.84 degrees, thresholded, Group 3 coded; modules 4.05 x 1.95 px
    # with ink bleed (one pixel light rings that must not be taken for
    # noise). zxing-cpp reads it.
    pgm = Zlib.gunzip(File.binread(File.join(FIXTURES, "fax-204x98-skewed.pgm.gz")))
    image = Distort.parse_pgm(pgm)
    assert_detects(image, rqr_matrix(FAX_TEXT, level: :m), tolerance: 0)
  end

  def test_thin_modules_with_ink_bleed
    # Blurred and thresholded on the dark side: a 2 px light ring shrinks
    # to a single pixel.
    matrix = rqr_matrix(FAX_TEXT[0, 47], level: :m)
    base = render(matrix, module_size: 8)
    [[4.05, 1.95, 150], [4.0, 2.2, 170]].each do |mx, my, threshold|
      image = Distort.blur(Distort.resize(base, (base.width * mx / 8).round, (base.height * my / 8).round), 0.6)
      image = Distort.lut(image, Array.new(256) { |v| v < threshold ? 0 : 255 })
      assert_detects(image, matrix, tolerance: 0, message: "#{mx} x #{my} px, threshold #{threshold}")
    end
  end

  def test_vote_offsets_follow_the_module_shape
    square = PerspectiveTransform.quad_to_quad([[0, 0], [1, 0], [1, 1], [0, 1]], [[0, 0], [8, 0], [8, 8], [0, 8]])
    assert_equal [2, 2], GridSampler.vote_offsets(square, 25)
    wide = PerspectiveTransform.quad_to_quad([[0, 0], [1, 0], [1, 1], [0, 1]], [[0, 0], [4, 0], [4, 2.2], [0, 2.2]])
    assert_equal [1, 0], GridSampler.vote_offsets(wide, 25)
    tall = PerspectiveTransform.quad_to_quad([[0, 0], [1, 0], [1, 1], [0, 1]], [[0, 0], [2.2, 0], [2.2, 4], [0, 4]])
    assert_equal [0, 1], GridSampler.vote_offsets(tall, 25)
    s = 8 / Math.sqrt(2)
    diamond = PerspectiveTransform.quad_to_quad([[0, 0], [1, 0], [1, 1], [0, 1]], [[50, 0], [50 + s, s], [50, 2 * s], [50 - s, s]])
    # The horizontal chord through a 45 degree module is its diagonal.
    assert_equal [3, 3], GridSampler.vote_offsets(diamond, 25)
  end

  # --- many symbols: sheets of labels ------------------------------------

  # Symbols laid out on a regular grid (a sheet of labels): the finder
  # patterns of neighbouring symbols form perfect isosceles right
  # triangles too.
  def label_sheet(cols, rows, version: 2, module_size: 3, gap: 0)
    matrices = Array.new(cols * rows) { |i| rqr_matrix("label #{i}", level: :m, size: version) }
    images = matrices.map { |m| render(m, module_size: module_size) }
    step = images.first.width + gap
    placements = images.each_with_index.map { |img, i| [img, (i % cols) * step + 5, (i / cols) * step + 5] }
    [Distort.compose(cols * step + 10, rows * step + 10, placements), matrices]
  end

  def sampled_grids(scene, multi:, try_harder: true)
    detector = Detector.new(Binarizer.hybrid(scene), image: scene)
    detector.each_candidate(try_harder: try_harder, multi: multi).flat_map { |c| [c.bits, *c.alternatives.first(2)] }
  end

  def test_sheet_of_labels_multi
    [[4, 4, 0], [4, 4, 12], [5, 5, 0]].each do |cols, rows, gap|
      scene, matrices = label_sheet(cols, rows, gap: gap)
      grids = sampled_grids(scene, multi: true)
      missing = matrices.each_index.reject { |i| grids.any? { |g| module_errors(g, matrices[i]).zero? } }
      assert_empty missing, "#{cols}x#{rows} gap #{gap}: labels not found"
    end
  end

  def test_sheet_with_more_finder_patterns_than_the_single_symbol_limit
    # 48 symbols = 144 finder patterns, three times MAX_PATTERNS.
    scene, matrices = label_sheet(8, 6)
    grids = sampled_grids(scene, multi: true, try_harder: false)
    found = matrices.count { |m| grids.any? { |g| module_errors(g, m).zero? } }
    assert_equal 48, found
  end

  def test_sheet_of_labels_single_symbol_mode
    # Reading one symbol of a sheet: the fast mode alone must find one.
    [[4, 4, 0, 2], [4, 4, 12, 2], [5, 5, 0, 2], [4, 4, 0, 5]].each do |cols, rows, gap, version|
      scene, matrices = label_sheet(cols, rows, gap: gap, version: version)
      grids = sampled_grids(scene, multi: false, try_harder: false)
      assert(grids.any? { |g| matrices.any? { |m| module_errors(g, m).zero? } }, "#{cols}x#{rows} gap #{gap} v#{version}")
    end
  end

  def test_multi_confirm_skips_used_patterns_on_a_sheet
    scene, matrices = label_sheet(3, 3)
    detector = Detector.new(Binarizer.hybrid(scene), image: scene)
    confirmed = []
    detector.each_candidate(multi: true) do |candidate|
      next unless matrices.any? { |m| module_errors(candidate.bits, m).zero? }

      refute(confirmed.any? { |c| c.finder_patterns.intersect?(candidate.finder_patterns) })
      confirmed << candidate
      detector.confirm(candidate)
    end
    assert_equal 9, confirmed.size
  end

  def test_confirm_accepts_results_and_quads
    scene, matrices = label_sheet(3, 1)
    bits = Binarizer.hybrid(scene)
    all = Detector.new(bits, image: scene).each_candidate(multi: true).select do |c|
      matrices.any? { |m| module_errors(c.bits, m).zero? }
    end
    assert_equal 3, all.size
    # What another pass decoded (a Result with points) and a bare quad.
    result = QrReader::Result.new(text: "x", raw_bytes: "x".b, version: 2, ec_level: :m, mask: 0, points: all[0].points)
    detector = Detector.new(bits, image: scene)
    # Malformed quads are ignored.
    assert_same detector, detector.confirm(result).confirm(all[1].points).confirm([[Float::NAN, 0]] * 4).confirm(%w[a b c d])
    rest = detector.each_candidate(multi: true).select { |c| matrices.any? { |m| module_errors(c.bits, m).zero? } }
    assert_equal [all[2].finder_patterns], rest.map(&:finder_patterns).uniq
  end

  def test_pattern_set_partition
    fp = ->(x, y) { QrReader::Detector::FinderPattern.new(x.to_f, y.to_f, 3.0) }
    sets = QrReader::Detector::PatternSets
    # Two symbols side by side, 18 modules between finder centres, 4
    # module quiet zones.
    a = [fp.(10, 10), fp.(64, 10), fp.(10, 64)]
    b = [fp.(109, 10), fp.(163, 10), fp.(109, 64)]
    patterns = a + b
    by_x = patterns.sort_by(&:x)
    xs = by_x.map(&:x)
    clean, = sets.partition_clean(sets.neighbourhood(patterns, 8), patterns)
    ids = ->(triple) { triple.patterns.map(&:object_id).sort }
    [a, b].each { |s| assert_includes clean.map(&ids), s.map(&:object_id).sort }
    refute sets.foreign?(sets.evaluate(*a), by_x, xs)
    # A perfect isosceles right triangle of finders of different symbols:
    # a's other finders and b's bottom-left one lie on its edges.
    across = sets.evaluate(a[0], b[0], fp.(10, 109))
    assert_equal 0.0, across.score
    assert_equal 3, sets.foreign_count(across, by_x, xs)
    assert sets.foreign?(across, by_x, xs)
    # One false pattern in a symbol's data area does not make it foreign;
    # patterns of a very different size do not count at all.
    stray = fp.(40, 40)
    tiny = fp.(30, 30)
    tiny.instance_variable_set(:@module_size, 0.5)
    more = (patterns + [stray, tiny]).sort_by(&:x)
    assert_equal 1, sets.foreign_count(sets.evaluate(*a), more, more.map(&:x))
    refute sets.foreign?(sets.evaluate(*a), more, more.map(&:x))
  end

  # --- grid sampling -------------------------------------------------------

  # Straightforward Float reference of GridSampler.sample without voting.
  def reference_sample(matrix, d, transform)
    m = transform.m
    out = QrReader::BitMatrix.new(d)
    d.times do |my|
      d.times do |mx|
        u = mx + 0.5
        v = my + 0.5
        den = m[6] * u + m[7] * v + m[8]
        next if den.abs < 1e-9

        x = (m[0] * u + m[1] * v + m[2]) / den
        y = (m[3] * u + m[4] * v + m[5]) / den
        next unless x >= 0 && y >= 0 && x < matrix.width && y < matrix.height

        out.set(mx, my) if matrix.dark?(x.floor, y.floor)
      end
    end
    out
  end

  def test_fixed_point_sampling_matches_float_reference
    rng = Random.new(11)
    matrix = QrReader::BitMatrix.new(300, 200, Array.new(60_000) { rng.rand(2) }.pack("C*"))
    differing = total = 0
    200.times do
      d = [21, 45, 177].sample(random: rng)
      quad = Array.new(4) { [rng.rand(-200.0..500.0), rng.rand(-200.0..400.0)] }
      t = PerspectiveTransform.quad_to_quad([[0, 0], [d, 0], [d, d], [0, d]], quad)
      next unless t&.regular_over?(0, 0, d, d)

      expected = reference_sample(matrix, d, t)
      actual = GridSampler.sample(matrix, d, GridSampler.whole(d, t))
      total += d * d
      differing += expected.bits.bytes.zip(actual.bits.bytes).count { |a, b| a != b }
    end
    assert_operator total, :>, 100_000
    # Only modules whose centre lies within rounding error of a pixel edge.
    assert_operator differing, :<=, total / 10_000
  end

  def test_sampling_extreme_transforms
    matrix = QrReader::BitMatrix.new(50, 40, "\x01".b * 2000)
    [1e-300, 1e-9, 1e9, 1e300].each do |k|
      t = PerspectiveTransform.new([3 * k, 0.1 * k, 20 * k, 0.2 * k, 3 * k, 10 * k, 1e-4 * k, 2e-4 * k, k])
      assert_equal reference_sample(matrix, 21, t), GridSampler.sample(matrix, 21, GridSampler.whole(21, t))
      GridSampler.sample(matrix, 21, GridSampler.whole(21, t), offset: [2, 1])
    end
    # Modules mapped far outside the image (beyond the fixed-point range)
    # read as light.
    far = PerspectiveTransform.new([1e12, 0.0, 1e15, 0.0, 1e12, 1e15, 0.0, 0.0, 1.0])
    assert_equal 0, GridSampler.sample(matrix, 21, GridSampler.whole(21, far)).dark_count
    near_horizon = PerspectiveTransform.new([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, -10.5])
    GridSampler.sample(matrix, 21, GridSampler.whole(21, near_horizon), offset: 1)
  end

  # --- candidates and modes ------------------------------------------------

  def test_fast_mode_yields_only_likely_candidates
    rng = Random.new(5)
    image = gray(320, 240) { rng.rand < 0.5 ? 30 : 220 }
    detector = Detector.new(Binarizer.hybrid(image), image: image)
    assert(detector.each_candidate(try_harder: false).all?(&:likely?))
    hard = detector.each_candidate(try_harder: true).map(&:likely?)
    # Likely candidates come first.
    assert_equal hard.sort_by { |l| l ? 0 : 1 }, hard
  end

  def test_image_of_another_size_is_ignored
    matrix = symbol(5)
    image = render(matrix, module_size: 4)
    small = image.crop(0, 0, image.width - 1, image.height)
    detector = Detector.new(Binarizer.hybrid(image), image: small)
    assert_nil detector.image
    refute detector.inverted_image?
    candidate = detector.each_candidate.first
    assert_equal matrix, candidate.bits
    candidate.alternatives.each { |g| assert_kind_of QrReader::BitMatrix, g }
  end

  def test_large_modules
    # Blocks deep inside modules have no contrast anywhere near them.
    [[1, 60], [3, 80]].each do |version, ms|
      matrix = symbol(version)
      assert_detects(render(matrix, module_size: ms), matrix, tolerance: 0, message: "v#{version} at #{ms} px")
    end
    matrix = symbol(2)
    assert_detects(Distort.rotate(render(matrix, module_size: 30), 2), matrix, tolerance: 0, message: "rotated")
  end

  def test_finder_pattern_limit
    rng = Random.new(2)
    image = gray(400, 300) { rng.rand(256) }
    finder = QrReader::Detector::FinderPatternFinder.new(Binarizer.hybrid(image))
    assert_operator finder.find(try_harder: true, limit: 5).size, :<=, 5
    assert_operator finder.find(try_harder: true).size, :<=, QrReader::Detector::FinderPatternFinder::MAX_PATTERNS
  end

  def test_alignment_search_in_dark_areas
    finder = QrReader::Detector::AlignmentPatternFinder.new(QrReader::BitMatrix.new(400, 400, "\x01".b * 160_000))
    assert_nil finder.find(200.0, 200.0, 50.0, 4.0, 0.0, 0.0, 4.0)
    assert_nil finder.find(Float::NAN, 1.0, 5.0, 1.0, 0.0, 0.0, 1.0)
    assert_nil finder.find(1e300, -1e300, 5.0, 1.0, 0.0, 0.0, 1.0)
  end

  # --- garbage -------------------------------------------------------------

  def run_everything(matrix, image = nil)
    Detector.detect_pure(matrix)
    detector = Detector.new(matrix, image: image)
    [[false, false], [true, false], [false, true], [true, true]].each do |hard, multi|
      detector.each_candidate(try_harder: hard, multi: multi) do |c|
        c.bits
        c.points.flatten.each { |v| assert v.finite? }
        c.alternatives.to_a
        detector.confirm(c) if multi
      end
    end
  end

  def test_structured_garbage_never_raises
    rng = Random.new(2024)
    finder = render(QrReader::BitMatrix.from_rows(["#######", "#.....#", "#.###.#", "#.###.#", "#.###.#",
                                                   "#.....#", "#######"]), module_size: 2, quiet: 1)
    24.times do |i|
      w = [1, 3, 21, 40, 63, 160].sample(random: rng)
      h = [1, 3, 21, 40, 63, 160].sample(random: rng)
      matrix, image =
        case i % 6
        when 0 then [QrReader::BitMatrix.new(w, h, Array.new(w * h) { rng.rand < 0.3 ? 1 : 0 }.pack("C*"))]
        when 1 then [QrReader::BitMatrix.new(w, h, Array.new(w * h) { |k| ((k % w) / 3).odd? ? 1 : 0 }.pack("C*"))]
        when 2
          scene = Distort.compose(160, 160, Array.new(10) { [finder, rng.rand(0..142), rng.rand(0..142)] })
          [Binarizer.hybrid(scene), scene]
        when 3
          img = render(symbol(rng.rand(1..8)), module_size: rng.rand(1..3), quiet: rng.rand(0..2))
          cw = rng.rand(1..img.width)
          ch = rng.rand(1..img.height)
          img = img.crop(rng.rand(0..img.width - cw), rng.rand(0..img.height - ch), cw, ch)
          [Binarizer.hybrid(img), img]
        when 4 then [QrReader::BitMatrix.new(w, h, Array.new(w * h) { |k| ((k % w) / 2 + k / w / 2).odd? ? 1 : 0 }.pack("C*"))]
        else
          img = gray(w, h) { rng.rand(256) }
          [Binarizer.global_histogram(img), img]
        end
      run_everything(matrix, image)
    end
    run_everything(QrReader::BitMatrix.new(0, 0))
  end
end
