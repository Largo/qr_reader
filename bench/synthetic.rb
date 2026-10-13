# frozen_string_literal: true

# Synthetic stress benchmark: a deterministic grid of QR symbols made with
# QrTestEncoder (versions 1..40, all levels, all modes) and degraded with
# Distort (rotation, perspective, curvature, blur, noise, lighting, scaling,
# JPEG, inversion, mirroring, several codes per image, corrupted codewords).
# Reports the success rate per distortion family and decode timings.
#
# Usage:
#   bundle exec ruby [--yjit] bench/synthetic.rb [options]
#
# Options:
#   --quick                 small subset (about a quarter of the grid) for CI
#   --only FAMILY[,...]     run only these families (e.g. noise,blur); may be repeated
#   --json OUT              write per-case results and the summary as JSON
#   --compare PREVIOUS.json list cases that newly pass / newly fail relative to an earlier --json run
#   --baseline [FILE]       compare with the zxing-cpp baseline (default bench/baselines/synthetic_zxcpp.json)
#   --save-failures DIR     write the input of every failing case to DIR (PNG / JPEG)
#   --verbose               print every case with its time and result
#   --list                  list the case ids and exit
#   --min-pass N            exit with status 1 when fewer than N cases pass (for CI)
#   --max-wrong N           exit with status 1 when more than N results are misreads (CI: 0)
#   --reference             decode with zxing-cpp (bench/reference/zxcpp.py) instead of qr_reader;
#                           regenerate the baseline with
#                           bundle exec ruby bench/synthetic.rb --reference --json bench/baselines/synthetic_zxcpp.json
#
# A case passes when every expected text is among the decoded results and
# nothing else was decoded. Outcomes: pass, partial (multi-code images: some
# found), fail (nothing found), wrong (a result with unexpected text: a
# misread, the worst outcome), error (exception). The ec_overload family has
# more corrupted codewords than Reed-Solomon can repair: it passes unless the
# decoder returns wrong data.
#
# Inputs are generated before timing; the reported time is QrReader.read_all
# on the in-memory image (or on JPEG bytes for the jpeg family).

require_relative "support"
require "optparse"
require "time"
require "tmpdir"
require "qr_encoder"
require "distort"
require "reference"

module SyntheticBench
  DEFAULT_BASELINE = File.expand_path("baselines/synthetic_zxcpp.json", __dir__)
  LEVELS = %i[L M Q H].freeze
  URL_CHARS = [*"a".."z", *"A".."Z", *"0".."9", "-", "_"].freeze

  # +build+ returns a Sample; it receives a Random seeded from the case id.
  Case = Data.define(:id, :family, :quick, :build)

  # input: QrReader::Image or encoded image bytes (String). expected: Array
  # of expected texts, each a String or an Array of acceptable alternatives.
  # overload: only wrong results count as failure.
  Sample = Data.define(:input, :expected, :overload) do
    def initialize(input:, expected:, overload: false)
      super
    end
  end

  Outcome = Data.define(:status, :ms, :texts, :error) do
    def pass
      status == :pass
    end
  end

  STATUSES = %i[pass partial fail wrong error].freeze

  module_function

  # --- the grid ----------------------------------------------------------------

  def all_cases
    @all_cases ||= begin
      @cases = []
      define_cases
      @cases.freeze
    end
  end

  def kase(family, name, quick: false, &build)
    @cases << Case.new(id: "#{family}/#{name}", family: family, quick: quick, build: build)
  end

  # Printable URL-like payload that nearly fills +version+ at +level+ in byte mode.
  def payload(rng, version, level, fill: 0.8)
    capacity = (QrTestEncoder.capacity_bits(version, level) - 4 - (version < 10 ? 8 : 16)) / 8
    length = [(capacity * (fill + (1 - fill) * rng.rand)).floor, 12].max
    "https://qr.test/#{Array.new(length) { URL_CHARS[rng.rand(URL_CHARS.size)] }.join}"[0, [length, capacity].min]
  end

  # A symbol of exactly +version+ with a random payload; returns [Encoded, text].
  def symbol(rng, version, level, mask: nil, **options)
    text = payload(rng, version, level)
    [QrTestEncoder.build(text, version: version, level: level, mask: mask, **options), text]
  end

  # A single symbol of +version+/+level+, rendered and passed through
  # +transform+ (called with the image and the case's Random).
  def image_case(family, name, version, level, module_size: 4, quick: false, &transform)
    kase(family, name, quick: quick) do |rng|
      sym, text = symbol(rng, version, level)
      Sample.new(input: transform.call(sym.to_image(module_size: module_size), rng), expected: [text])
    end
  end

  def define_cases
    define_clean
    define_geometry
    define_photometric
    define_formats
    define_content
    define_scenes
  end

  def define_clean
    [1, 2, 3, 4, 5, 7, 10, 13, 17, 21, 25, 30, 35, 40].each_with_index do |v, i|
      level = LEVELS[i % 4]
      size = v >= 25 ? 3 : 4
      image_case("clean", "v#{v}-#{level}-m#{size}", v, level, module_size: size, quick: [1, 5, 10, 25, 40].include?(v)) { |img| img }
    end
    [2, 6, 12, 20].each_with_index do |v, i|
      [1.5, 2.0, 2.5, 3.0].each do |pm|
        level = LEVELS[(i + pm.to_i) % 4]
        image_case("scale", "v#{v}-#{level}-#{pm}px", v, level, module_size: 6, quick: v == 6 && pm <= 2.0) do |img|
          Distort.scale(img, pm / 6.0)
        end
      end
    end
  end

  def define_geometry
    [[3, :M], [12, :Q]].each do |v, level|
      [90, 180, 270].each do |deg|
        image_case("rotation", "v#{v}-#{deg}", v, level, quick: deg == 90) { |img| img.rotate(deg) }
      end
    end
    [5, 15, 30, 45, 60, 75, 120, 200, 315].each_with_index do |deg, i|
      v = [4, 10][i % 2]
      image_case("rotation", "v#{v}-#{deg}deg", v, LEVELS[i % 4], quick: [30, 45].include?(deg)) { |img| Distort.rotate(img, deg) }
    end
    [0.1, 0.2, 0.3].each_with_index do |strength, i|
      [3, 8, 15].each_with_index do |v, j|
        image_case("perspective", "v#{v}-s#{strength}", v, LEVELS[(i + j) % 4], quick: j == 1) do |img, rng|
          Distort.perspective_tilt(img, strength: strength, seed: rng.rand(1 << 30))
        end
      end
    end
    [[5, 25], [9, -40]].each do |v, deg|
      image_case("perspective", "v#{v}-tilt-rot#{deg}", v, :M) do |img, rng|
        Distort.rotate(Distort.perspective_tilt(img, strength: 0.2, seed: rng.rand(1 << 30)), deg)
      end
    end
    image_case("perspective", "v6-steep", 6, :Q) do |img|
      w = img.width
      Distort.perspective(img, [[w * 0.05, w * 0.25], [w * 0.95, 0], [w * 0.95, w], [w * 0.05, w * 0.75]], w, w,
                          supersample: 2)
    end
    [[60, 3], [100, 3], [140, 10], [170, 10]].each do |arc, v|
      image_case("curvature", "cylinder#{arc}-v#{v}", v, :M, quick: arc == 100) { |img| Distort.cylinder(img, arc: arc) }
    end
    [[0.08, 4], [0.15, 4], [0.25, 11], [-0.1, 11]].each do |k, v|
      image_case("curvature", "barrel#{k}-v#{v}", v, :Q, quick: k == 0.15) { |img| Distort.barrel(img, k: k) }
    end
    [[2, :L], [7, :M], [20, :Q]].each do |v, level|
      image_case("mirrored", "v#{v}", v, level, quick: v == 7) { |img| Distort.mirror(img) }
      image_case("mirrored", "v#{v}-rot30", v, level) { |img| Distort.rotate(Distort.mirror(img), 30) }
    end
  end

  def define_photometric
    [10, 25, 40, 60].each_with_index do |sigma, i|
      v = [4, 10][i % 2]
      image_case("noise", "gauss#{sigma}-v#{v}", v, LEVELS[i], quick: sigma == 25) do |img, rng|
        Distort.gaussian_noise(img, sigma: sigma, seed: rng.rand(1 << 30))
      end
    end
    [0.005, 0.01, 0.02, 0.04].each_with_index do |amount, i|
      v = [4, 10][i % 2]
      image_case("noise", "saltpepper#{amount}-v#{v}", v, LEVELS[i], quick: amount == 0.01) do |img, rng|
        Distort.salt_pepper(img, amount: amount, seed: rng.rand(1 << 30))
      end
    end
    [1.0, 1.5, 2.0, 2.5, 3.0].each_with_index do |sigma, i|
      v = [3, 8][i % 2]
      image_case("blur", "gauss#{sigma}-v#{v}-m5", v, LEVELS[i % 4], module_size: 5, quick: sigma == 2.0) do |img|
        Distort.blur(img, sigma)
      end
    end
    [[5, 0], [9, 30], [13, 75], [9, 135]].each_with_index do |(length, angle), i|
      v = [3, 8][i % 2]
      image_case("blur", "motion#{length}-#{angle}-v#{v}-m5", v, :M, module_size: 5, quick: length == 9 && angle == 30) do |img|
        Distort.motion_blur(img, length: length, angle: angle)
      end
    end
    lighting = {
      "gradient0.5" => ->(img, _) { Distort.gradient(img, from: 1.0, to: 0.5, angle: 20) },
      "gradient0.3" => ->(img, _) { Distort.gradient(img, from: 1.0, to: 0.3, angle: 110) },
      "gradient0.15" => ->(img, _) { Distort.gradient(img, from: 0.9, to: 0.15, angle: 225) },
      "vignette0.5" => ->(img, _) { Distort.vignette(img, strength: 0.5) },
      "vignette0.8" => ->(img, _) { Distort.vignette(img, strength: 0.8) },
      "shadow0.4-soft" => ->(img, rng) { Distort.shadow(img, darkness: 0.4, softness: 0.2, seed: rng.rand(1 << 30)) },
      "shadow0.6" => ->(img, rng) { Distort.shadow(img, darkness: 0.6, softness: 0.05, seed: rng.rand(1 << 30)) },
      "shadow0.75-hard" => ->(img, rng) { Distort.shadow(img, darkness: 0.75, softness: 0.01, seed: rng.rand(1 << 30)) },
      "contrast60-190" => ->(img, _) { Distort.contrast(img, low: 60, high: 190) },
      "contrast100-150" => ->(img, _) { Distort.contrast(img, low: 100, high: 150) },
      "dark0-80" => ->(img, _) { Distort.contrast(img, low: 0, high: 80) },
      "bright180-255" => ->(img, _) { Distort.contrast(img, low: 180, high: 255) },
      "gamma2.2" => ->(img, _) { Distort.gamma(img, 2.2) },
      "gradient-noise" => ->(img, rng) { Distort.gaussian_noise(Distort.gradient(img, to: 0.3), sigma: 12, seed: rng.rand(1 << 30)) }
    }
    lighting.each_with_index do |(name, fn), i|
      v = [5, 9, 14][i % 3]
      image_case("lighting", "#{name}-v#{v}", v, LEVELS[i % 4], quick: i.even? && i < 8) { |img, rng| fn.call(img, rng) }
    end
    [[2, :L, 4], [7, :M, 4], [20, :Q, 3]].each do |v, level, size|
      image_case("inverted", "v#{v}", v, level, module_size: size, quick: v == 7) { |img| Distort.invert(img) }
      image_case("inverted", "v#{v}-rot20-noise", v, level, module_size: size) do |img, rng|
        Distort.gaussian_noise(Distort.invert(Distort.rotate(img, 20)), sigma: 10, seed: rng.rand(1 << 30))
      end
    end
  end

  def define_formats
    return warn("ImageMagick not found: skipping the jpeg family") unless Distort.jpeg_available?

    [[10, false], [20, false], [35, false], [50, false], [75, false], [95, false],
     [20, true], [50, true], [90, true]].each_with_index do |(quality, color), i|
      v = [5, 15][i % 2]
      name = "q#{quality}#{color ? '-color' : ''}-v#{v}"
      image_case("jpeg", name, v, LEVELS[i % 4], quick: [20, 50].include?(quality) && !color) do |img|
        Distort.jpeg_bytes(img, quality: quality, color: color)
      end
    end
    image_case("jpeg", "q50-progressive-v8", 8, :M) { |img| Distort.jpeg_bytes(img, quality: 50, progressive: true) }
  end

  def define_content
    [[2, :L], [5, :M], [10, :Q], [20, :H], [30, :M]].each_with_index do |(v, level), i|
      kase("ec", "max-v#{v}-#{level}", quick: i.even?) do |rng|
        sym, text = symbol(rng, v, level, corrupt_per_block: :max, seed: rng.rand(1 << 30))
        Sample.new(input: sym.to_image, expected: [text])
      end
      kase("ec", "modules-v#{v}-#{level}") do |rng|
        sizes, ecc = QrTestEncoder.block_sizes(v, level)
        sym, text = symbol(rng, v, level, corrupt_modules: sizes.size * ecc / 4, seed: rng.rand(1 << 30))
        Sample.new(input: sym.to_image, expected: [text])
      end
    end
    (1..10).each do |v|
      level = LEVELS[v % 4]
      kase("ec_overload", "v#{v}-#{level}", quick: v <= 3) do |rng|
        _, ecc = QrTestEncoder.block_sizes(v, level)
        sym, text = symbol(rng, v, level, corrupt_per_block: ecc / 2 + 1, seed: rng.rand(1 << 30))
        Sample.new(input: sym.to_image, expected: [text], overload: true)
      end
    end

    content = {
      "numeric" => [["31415926535897932384626433832795028841971693993751"], {}, "31415926535897932384626433832795028841971693993751"],
      "alphanumeric" => [["HTTPS://QR.TEST/ALNUM-0123456789 $%*+-./:"], {}, "HTTPS://QR.TEST/ALNUM-0123456789 $%*+-./:"],
      "utf8" => [[[:byte, "Grüße aus Zürich – 😀"]], {}, "Grüße aus Zürich – 😀"],
      "sjis-guess" => [[[:byte, "日本語のテキストです".encode("Shift_JIS")]], {}, "日本語のテキストです"],
      "kanji" => [[[:kanji, "漢字モードの試験"]], {}, "漢字モードの試験"],
      "hanzi" => [[[:hanzi, "中文汉字测试"]], {}, "中文汉字测试"],
      "mixed" => [[[:numeric, "2024"], [:alphanumeric, " QR-CODE "], [:byte, "mixed é"], [:kanji, "漢字"]], {},
                  "2024 QR-CODE mixed é漢字"],
      "eci-utf8" => [[[:byte, "Ελληνικά € ✓"]], { eci: 26 }, "Ελληνικά € ✓"],
      "eci-latin1" => [[[:byte, "Ça coûte 5 €".encode("ISO-8859-15")]], { eci: 17 }, "Ça coûte 5 €"],
      "eci-latin2" => [[[:byte, "Zażółć gęślą jaźń".encode("ISO-8859-2")]], { eci: 4 }, "Zażółć gęślą jaźń"],
      "eci-sjis" => [[[:byte, "テスト".encode("Shift_JIS")]], { eci: 20 }, "テスト"],
      "gs1" => [[[:numeric, "01095011015300031"], [:alphanumeric, "7160430"], [:byte, "10ABC"]], { fnc1: :first },
                "01095011015300031716043010ABC"],
      "fnc1-second" => [[[:byte, "hello"]], { fnc1: [:second, 37] }, ["37hello", "hello"]]
    }
    content.each_with_index do |(name, (segments, options, expected)), i|
      kase("modes", name, quick: i.odd?) do
        sym = QrTestEncoder.build(segments, level: LEVELS[i % 4], **options)
        Sample.new(input: sym.to_image(module_size: 4), expected: [expected])
      end
    end
    kase("modes", "structured-append-3", quick: true) do
      text = "Structured append: one message split over three symbols."
      series = QrTestEncoder.structured_append_series(text, 3, level: :M)
      parts = series.map { |s| s.segments.last.data.dup.force_encoding(Encoding::UTF_8) }
      Sample.new(input: side_by_side(series.map { |s| s.to_image(module_size: 4) }), expected: parts)
    end
  end

  def define_scenes
    [2, 3, 4, 6].each do |count|
      kase("multi", "#{count}-codes", quick: count == 3) do |rng|
        symbols = Array.new(count) { |k| symbol(rng, [2, 4, 6, 9][k % 4], LEVELS[k % 4]) }
        images = symbols.each_with_index.map do |(sym, _), k|
          img = sym.to_image(module_size: 4)
          k.odd? ? Distort.rotate(img, 15 + 40 * k) : img
        end
        Sample.new(input: grid(images, rng), expected: symbols.map(&:last))
      end
    end
    kase("multi", "2-codes-inverted-pair") do |rng|
      a, ta = symbol(rng, 3, :M)
      b, tb = symbol(rng, 5, :Q)
      Sample.new(input: side_by_side([a.to_image, Distort.invert(b.to_image)]), expected: [ta, tb])
    end
    [1, 2, 3, 4].each do |k|
      kase("clutter", "v#{2 + k}-#{k}", quick: k == 2) do |rng|
        sym, text = symbol(rng, 2 + k, LEVELS[k % 4])
        Sample.new(input: clutter(sym.to_image(module_size: 4), rng), expected: [text])
      end
    end
    6.times do |k|
      v = [3, 6, 10][k % 3]
      kase("photo", "v#{v}-#{k}", quick: k < 2) do |rng|
        sym, text = symbol(rng, v, LEVELS[k % 4])
        img = Distort.perspective_tilt(sym.to_image(module_size: 6), strength: 0.15, seed: rng.rand(1 << 30))
        img = Distort.gradient(img, from: 1.0, to: 0.45, angle: rng.rand(360))
        img = Distort.blur(img, 0.7 + 0.8 * rng.rand)
        img = Distort.gaussian_noise(img, sigma: 8, seed: rng.rand(1 << 30))
        input = Distort.jpeg_available? ? Distort.jpeg_bytes(img, quality: 40 + 10 * k, color: k.odd?) : img
        Sample.new(input: input, expected: [text])
      end
    end
    # Heavier blur on smaller modules: beyond what zxing-cpp reads reliably.
    4.times do |k|
      v = [3, 6][k % 2]
      kase("photo_hard", "v#{v}-#{k}") do |rng|
        sym, text = symbol(rng, v, LEVELS[k % 4])
        img = Distort.perspective_tilt(sym.to_image(module_size: 5), strength: 0.15, seed: rng.rand(1 << 30))
        img = Distort.gradient(img, from: 1.0, to: 0.45, angle: rng.rand(360))
        img = Distort.blur(img, 1.5 + 0.5 * rng.rand)
        img = Distort.gaussian_noise(img, sigma: 8, seed: rng.rand(1 << 30))
        input = Distort.jpeg_available? ? Distort.jpeg_bytes(img, quality: 45, color: k.odd?) : img
        Sample.new(input: input, expected: [text])
      end
    end
    kase("large", "v40-m3-rot10") do |rng|
      sym, text = symbol(rng, 40, :L)
      Sample.new(input: Distort.rotate(sym.to_image(module_size: 3), 10), expected: [text])
    end
    kase("large", "v4-in-1600x1200") do |rng|
      sym, text = symbol(rng, 4, :M)
      Sample.new(input: Distort.compose(1600, 1200, [[sym.to_image(module_size: 5), 900, 500]]), expected: [text])
    end
  end

  # --- scene helpers -----------------------------------------------------------

  def side_by_side(images, gap: 20)
    width = images.sum(&:width) + gap * (images.size + 1)
    height = images.map(&:height).max + 2 * gap
    x = gap
    placements = images.map { |img| [img, x, gap].tap { x += img.width + gap } }
    Distort.compose(width, height, placements)
  end

  # Images on a 2-column grid with random jitter inside their cells.
  def grid(images, rng, gap: 30)
    cols = 2
    cell = images.map { |img| [img.width, img.height].max }.max + gap
    rows = (images.size + cols - 1) / cols
    placements = images.each_with_index.map do |img, k|
      x = (k % cols) * cell + rng.rand(gap)
      y = (k / cols) * cell + rng.rand(gap)
      [img, x, y]
    end
    Distort.compose(cols * cell + gap, rows * cell + gap, placements)
  end

  # Places the code among random dark rectangles and bars (false finder
  # pattern candidates) on a larger canvas.
  def clutter(code, rng)
    w = code.width * 2 + 40
    h = code.height + 120
    cx = rng.rand(w - code.width)
    cy = 60
    blocks = Array.new(40) do
      bw = rng.rand(4..40)
      bh = rng.rand(4..40)
      [QrReader::Image.new(bw, bh, rng.rand(0..120).chr.b * (bw * bh)), rng.rand(w - bw), rng.rand(h - bh)]
    end
    blocks.reject! { |img, x, y| x + img.width > cx - 8 && x < cx + code.width + 8 && y + img.height > cy - 8 && y < cy + code.height + 8 }
    Distort.compose(w, h, blocks + [[code, cx, cy]])
  end

  # --- running -----------------------------------------------------------------

  def parse_options(argv)
    options = { only: [] }
    parser = OptionParser.new do |o|
      o.banner = "Usage: bundle exec ruby [--yjit] bench/synthetic.rb [options]"
      o.on("--quick") { options[:quick] = true }
      o.on("--only LIST") { |v| options[:only].concat(v.split(",")) }
      o.on("--json OUT") { |v| options[:json] = v }
      o.on("--compare PREVIOUS") { |v| options[:compare] = v }
      o.on("--baseline [FILE]") { |v| options[:baseline] = v || DEFAULT_BASELINE }
      o.on("--save-failures DIR") { |v| options[:save_failures] = v }
      o.on("--verbose") { options[:verbose] = true }
      o.on("--list") { options[:list] = true }
      o.on("--reference") { options[:reference] = true }
      o.on("--min-pass N", Integer) { |v| options[:min_pass] = v }
      o.on("--max-wrong N", Integer) { |v| options[:max_wrong] = v }
    end
    BenchSupport.parse!(parser, argv)
    options
  end

  def select_cases(options)
    cases = all_cases
    cases = cases.select(&:quick) if options[:quick]
    cases = cases.select { |c| options[:only].include?(c.family) } unless options[:only].empty?
    cases
  end

  def run(argv)
    options = parse_options(argv)
    cases = select_cases(options)
    abort "no cases selected (families: #{all_cases.map(&:family).uniq.join(', ')})" if cases.empty?
    return cases.each { |c| puts c.id } if options[:list]

    decoder = options[:reference] ? QrReference.version : "qr_reader #{QrReader::VERSION}"
    puts "Synthetic grid: #{cases.size} cases#{options[:quick] ? ' (quick)' : ''} -- " \
         "#{decoder}#{options[:reference] ? '' : ", #{BenchSupport.runtime}"}"
    samples, gen_ms = generate(cases)
    outcomes = options[:reference] ? run_reference(cases, samples) : run_qr_reader(cases, samples, options)
    cases.each { |c| log(c.id, outcomes[c.id]) } if options[:verbose] && options[:reference]

    report(cases, outcomes, gen_ms)
    save_failures(cases, samples, outcomes, options[:save_failures]) if options[:save_failures]
    json = to_json(cases, outcomes, options, decoder)
    BenchSupport.write_json(options[:json], json) if options[:json]
    BenchSupport.compare_reports(options[:compare], json, "vs #{options[:compare]}") if options[:compare]
    BenchSupport.compare_reports(options[:baseline], json, "vs zxing-cpp baseline", baseline: true) if options[:baseline]
    wrong = outcomes.count { |_, o| o.status == :wrong }
    BenchSupport.check_limits(json["summary"]["passed"], min_pass: options[:min_pass], wrong: wrong, max_wrong: options[:max_wrong])
  end

  def generate(cases)
    samples = {}
    times = []
    cases.each do |c|
      sample, elapsed = BenchSupport.measure { c.build.call(Random.new(Zlib.crc32(c.id))) }
      samples[c.id] = sample
      times << elapsed
    end
    [samples, times]
  end

  def run_qr_reader(cases, samples, options)
    outcomes = {}
    cases.each do |c|
      sample = samples[c.id]
      outcomes[c.id] = begin
        results, elapsed = BenchSupport.measure { QrReader.read_all(sample.input) }
        classify(sample, results.map(&:text), elapsed)
      rescue *BenchSupport::CASE_ERRORS => e
        Outcome.new(status: :error, ms: nil, texts: [], error: "#{e.class}: #{e.message}")
      end
      log(c.id, outcomes[c.id]) if options[:verbose]
    rescue Interrupt
      warn "\ninterrupted -- reporting the cases done so far"
      break
    end
    outcomes
  end

  def run_reference(cases, samples)
    Dir.mktmpdir do |dir|
      paths = cases.map { |c| write_input(samples[c.id].input, File.join(dir, c.id.tr("/", "_"))) }
      results = QrReference.decode(paths, text_mode: "Plain")
      cases.zip(results).to_h do |c, result|
        next [c.id, Outcome.new(status: :error, ms: nil, texts: [], error: "zxing-cpp: #{result['error']}")] if result["error"]

        [c.id, classify(samples[c.id], result["results"].map { |r| r["text"] }, result["ms"])]
      end
    end
  end

  def classify(sample, texts, ms)
    accepted = ->(t) { sample.expected.any? { |e| Array(e).include?(t) } }
    wrong = texts.reject(&accepted)
    found = sample.expected.count { |e| Array(e).intersect?(texts) }
    status = if !wrong.empty? then :wrong
             elsif sample.overload || found == sample.expected.size then :pass
             elsif found.positive? then :partial
             else :fail
             end
    Outcome.new(status: status, ms: ms, texts: texts, error: nil)
  end

  # Writes a sample input as PNG (images) or JPEG (bytes); returns the path.
  def write_input(input, base)
    if input.is_a?(QrReader::Image)
      path = "#{base}.png"
      File.binwrite(path, BenchSupport.png_bytes(input))
    else
      path = "#{base}.jpg"
      File.binwrite(path, input)
    end
    path
  end

  def log(id, outcome)
    detail = outcome.error || (outcome.pass ? "" : "got [#{BenchSupport.preview(outcome.texts)}]")
    puts format("%-36s %-7s %9s  %s", id, outcome.status, BenchSupport.ms(outcome.ms), detail)
  end

  def report(cases, outcomes, gen_ms)
    headers = ["family", "cases", *STATUSES.map(&:to_s), "rate", "mean", "p95"]
    rows = cases.group_by(&:family).map { |family, list| summary_row(family, list, outcomes) }
    rows << summary_row("total", cases, outcomes)
    puts
    puts BenchSupport.table(headers, rows)
    puts
    puts BenchSupport.time_line("decode:", outcomes.values.filter_map(&:ms))
    puts format("input generation %.1f s (not included above)", gen_ms.sum / 1000.0)
    errors = outcomes.values.select(&:error)
    return if errors.empty?

    puts
    puts "#{errors.size} cases raised errors:"
    errors.group_by(&:error).first(5).each { |message, group| puts "  #{group.size} x #{message[0, 200]}" }
  end

  def summary_row(label, cases, outcomes)
    done = cases.filter_map { |c| outcomes[c.id] }
    counts = STATUSES.map { |s| done.count { |o| o.status == s } }
    times = BenchSupport.stats(done.filter_map(&:ms))
    rate = done.empty? ? "-" : format("%.1f%%", 100.0 * counts.first / done.size)
    [label, done.size, *counts, rate, BenchSupport.ms(times[:mean]), BenchSupport.ms(times[:p95])]
  end

  def save_failures(cases, samples, outcomes, dir)
    require "fileutils"
    FileUtils.mkdir_p(dir)
    failed = cases.reject { |c| outcomes[c.id]&.pass }
    failed.each { |c| write_input(samples[c.id].input, File.join(dir, c.id.tr("/", "_"))) }
    warn "saved #{failed.size} failing inputs to #{dir}"
  end

  def to_json(cases, outcomes, options, decoder)
    families = cases.group_by(&:family).transform_values do |list|
      done = list.filter_map { |c| outcomes[c.id] }
      STATUSES.to_h { |s| [s.to_s, done.count { |o| o.status == s }] }.merge("cases" => done.size)
    end
    times = outcomes.values.filter_map(&:ms)
    {
      "meta" => {
        "decoder" => decoder, "runtime" => options[:reference] ? nil : BenchSupport.runtime,
        "quick" => options[:quick] ? true : false, "created" => Time.now.utc.iso8601
      }.compact,
      "summary" => {
        "passed" => outcomes.count { |_, o| o.pass }, "total" => outcomes.size, "families" => families,
        "decode_ms" => BenchSupport.stats(times).transform_keys(&:to_s).transform_values { |v| v.is_a?(Float) ? v.round(3) : v }
      },
      "cases" => outcomes.to_h do |id, o|
        [id, { "pass" => o.pass, "status" => o.status.to_s, "ms" => o.ms&.round(3),
               "texts" => o.texts.map { |t| BenchSupport.utf8(t) }, "error" => o.error && BenchSupport.utf8(o.error) }.compact]
      end
    }
  end
end

SyntheticBench.run(ARGV) if $PROGRAM_NAME == __FILE__
