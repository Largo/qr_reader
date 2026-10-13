# frozen_string_literal: true

require_relative "detector_test_helper"

# The detector's kernels (lib/qr_reader/kernels/{binarizer,detector}.rb):
# the optimized binarizer against a plain per-pixel reference, the finder
# scan's result layout, the texture-gated fine row scan, the dot gain
# tolerant pattern test, and - when the qr_reader-native extension is
# loaded - native against pure Ruby results.
class TestKernels < Minitest::Test
  include DetectorTestHelper

  K = QrReaderKernels
  FPF = QrReader::Detector::FinderPatternFinder

  def random_image(width, height, seed, smooth: false)
    rng = Random.new(seed)
    data = Array.new(width * height) do |i|
      if smooth
        x = i % width
        y = i / width
        (128 + 90 * Math.sin(x / 9.0) * Math.cos(y / 13.0) + rng.rand(-12..12)).clamp(0, 255).round
      else
        rng.rand(256)
      end
    end
    QrReader::Image.new(width, height, data.pack("C*"))
  end

  # The hybrid binarizer written out per block and per pixel, without the
  # kernel's shortcuts (uniform blocks, pattern rows, separable sums).
  def reference_hybrid(image)
    w = image.width
    h = image.height
    data = image.data.bytes
    sw = (w + 7) / 8
    sh = (h + 7) / 8
    lows = Array.new(sw * sh)
    highs = Array.new(sw * sh)
    sh.times do |by|
      sw.times do |bx|
        x0 = [bx * 8, w - 8].min
        y0 = [by * 8, h - 8].min
        values = (y0...y0 + 8).flat_map { |y| data[y * w + x0, 8] }
        lows[by * sw + bx], highs[by * sw + bx] = values.minmax
      end
    end
    range = QrReader::Binarizer::MIN_DYNAMIC_RANGE
    flat = ->(i) { highs[i] - lows[i] <= range }
    block = Array.new(sw * sh) { |i| flat.call(i) ? 0 : (lows[i] + highs[i]) / 2 }
    (sw * sh).times do |i|
      next unless flat.call(i)

      neighbours = []
      neighbours << i + 1 if (i % sw) < sw - 1
      neighbours << i + sw if i + sw < sw * sh
      neighbours.each do |j|
        next unless flat.call(j)

        t = if lows[j] - highs[i] > range then (highs[i] + lows[j]) / 2
            elsif lows[i] - highs[j] > range then (highs[j] + lows[i]) / 2
            end
        next unless t

        block[i] = t if block[i].zero?
        block[j] = t if block[j].zero?
      end
    end
    means = Array.new(sw * sh) do |i|
      bx = i % sw
      by = i / sw
      cx = bx.clamp(2, sw - 3)
      cy = by.clamp(2, sh - 3)
      set = (cy - 2..cy + 2).flat_map { |y| (cx - 2..cx + 2).map { |x| block[y * sw + x] } }.select(&:positive?)
      set += [block[i]] * 2 if block[i].positive?
      set.empty? ? 0 : set.sum / set.size
    end
    first = means.index(&:positive?)
    if first
      last = means[first]
      means.map! { |t| t.zero? ? last : (last = t) }
    else
      means.fill(-1)
    end
    Array.new(w * h) do |i|
      x = i % w
      y = i / w
      data[i] <= means[(y / 8) * sw + [x / 8, sw - 1].min] ? 1 : 0
    end.pack("C*")
  end

  def test_hybrid_matches_the_reference
    [[40, 40], [41, 47], [64, 48], [97, 53], [130, 81]].each_with_index do |(w, h), k|
      [random_image(w, h, k), random_image(w, h, k, smooth: true)].each do |image|
        assert_equal reference_hybrid(image), K.binarize_hybrid(image.data, w, h), "#{w}x#{h}"
      end
    end
    # Flat areas, uniform blocks on both sides of their threshold, edges on
    # the block grid.
    matrix = symbol(2)
    image = Distort.pad(render(matrix, module_size: 5, dark: 70, light: 190), 3)
    assert_equal reference_hybrid(image), K.binarize_hybrid(image.data, image.width, image.height)
    blocks = render(matrix, module_size: 8)
    assert_equal reference_hybrid(blocks), K.binarize_hybrid(blocks.data, blocks.width, blocks.height)
  end

  def test_binarizer_results_are_binary_strings_of_the_image_size
    image = random_image(83, 61, 7)
    %i[binarize_hybrid binarize_local_mean].each do |entry|
      bits = K.public_send(entry, image.data, 83, 61)
      assert_equal Encoding::BINARY, bits.encoding
      assert_equal 83 * 61, bits.bytesize
      assert_equal 83 * 61, bits.count("\x00\x01")
    end
  end

  def test_finder_scan_result_layout
    matrix = symbol(1)
    bits = QrReader::Binarizer.hybrid(render(matrix, module_size: 4))
    rows = "\x01".b * bits.height
    result = K.finder_scan(bits.bits, bits.width, bits.height, rows, [])
    values = result.size - bits.height
    assert_equal 0, values % K::FINDER_FIELDS
    assert_equal 3, values / K::FINDER_FIELDS
    hits = result.last(bits.height)
    # Every row through the middle of a finder pattern is a hit.
    assert_operator hits.sum, :>=, 3 * 3 * 4
    assert(hits.all? { |n| n >= 0 && n == n.round })
    # Earlier patterns come back first, with their counts updated.
    again = K.finder_scan(bits.bits, bits.width, bits.height, rows, result.first(values))
    assert_equal result.first(values).each_slice(5).map { |p| p.first(4) },
                 again.first(values).each_slice(5).map { |p| p.first(4) }
    assert_equal(result.first(values).each_slice(5).map { |p| 2 * p[4] }, again.first(values).each_slice(5).map { |p| p[4] })
  end

  # A small symbol on a large page: the sparse fast rows (every 27th on an
  # A4 scan at 300 dpi) miss its 3 px module top finder patterns entirely;
  # the fine rows find all three.
  def test_fast_mode_finds_small_symbols_on_large_pages
    matrix = symbol(5)
    code = render(matrix, module_size: 3, quiet: 0)
    width = 600
    height = 3508
    left = 100
    top = 27 * 40 # sparse rows are 26 + 27k: none crosses rows top...top + 21
    page = "\xff".b * (width * height)
    code.height.times do |y|
      page[(top + y) * width + left, code.width] = code.data.byteslice(y * code.width, code.width)
    end
    image = QrReader::Image.new(width, height, page)
    found = FPF.new(QrReader::Binarizer.hybrid(image)).find
    near = 3.5 * 3
    far = (matrix.width - 3.5) * 3
    [[left + near, top + near], [left + far, top + near], [left + near, top + far]].each do |x, y|
      assert(found.any? { |p| p.distance_to(x, y) < 2 }, "no pattern near (#{x}, #{y})")
    end
  end

  # Rows in textured neighbourhoods (many 1:1:3:1:1 hits per row, as in
  # binarized sensor noise) are left to try_harder.
  def test_fine_rows_skip_texture
    noise = random_image(1200, 1600, 5)
    finder = FPF.new(QrReader::Binarizer.hybrid(noise))
    finder.find
    scanned = finder.instance_variable_get(:@scanned).count("\x01")
    sparse = 1600 / ((3 * 1600) / (4 * FPF::MAX_MODULES_FAST))
    assert_operator scanned, :<=, sparse + 1
    finder.find(try_harder: true)
    assert_equal 1600, finder.instance_variable_get(:@scanned).count("\x01")
  end

  def test_gain_ratio
    scanner = K::FinderScanner.new("\x00".b, 1, 1, [])
    # Thresholded fax: 5 px modules, light rings eaten down to 2 px.
    assert scanner.finder_ratio?(8, 3, 19, 2, 8, false)
    assert QrReader::Detector::Geometry.finder_ratio?(8, 3, 19, 2, 8)
    refute scanner.finder_ratio?(8, 3, 19, 2, 30, false)
    refute scanner.finder_ratio?(8, 0, 19, 2, 8, false)
    # Tiny patterns: pixel rounding is covered by the plain test already.
    refute scanner.gain_ratio?(1, 1, 3, 1, 3)
  end

  def test_symbol_with_heavy_dot_gain
    matrix = symbol(3, level: :M)
    image = render(matrix, module_size: 7)
    # Dilate the dark modules by 2 px.
    data = image.data.bytes
    w = image.width
    out = data.each_index.map do |i|
      x = i % w
      y = i / w
      dark = (-2..2).any? { |d| (y + d).between?(0, image.height - 1) && data[(y + d) * w + x] < 128 } ||
             (-2..2).any? { |d| (x + d).between?(0, w - 1) && data[y * w + x + d] < 128 }
      dark ? 0 : 255
    end
    assert_detects(QrReader::Image.new(w, image.height, out.pack("C*")), matrix, tolerance: 4)
  end

  def test_native_kernels_match_pure_ruby
    skip "qr_reader-native not loaded" unless defined?(QrReaderNative) && QrReaderNative.respond_to?(:binarize_hybrid)

    pure = QrReader::NativeKernels.method(:pure)
    image = render(symbol(4), module_size: 3)
    %i[binarize_hybrid binarize_local_mean].each do |entry|
      assert_equal pure.call(entry).call(image.data, image.width, image.height),
                   QrReaderNative.public_send(entry, image.data, image.width, image.height).b
    end
    bits = QrReader::Binarizer.hybrid(image)
    rows = "\x01".b * bits.height
    assert_equal pure.call(:finder_scan).call(bits.bits, bits.width, bits.height, rows, []),
                 QrReaderNative.finder_scan(bits.bits, bits.width, bits.height, rows, [])
  end
end
