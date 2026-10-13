# frozen_string_literal: true

require_relative "test_helper"
require "qr_encoder"
require "distort"
require "reference"
require "tmpdir"
require_relative "../bench/support"
require_relative "../bench/corpus"
require_relative "../bench/synthetic"

# Adversarial tests for the testkit (test encoder, distortions, bench
# helpers): edge cases, garbage parameters and cross-checks against
# references that share no code with it (zint via zxing-cpp's writer,
# zxing-cpp's reader, plain re-implementations of the spec formulas,
# QrTestHelper).
class TestTestkitAdversarial < Minitest::Test
  LEVELS = %i[L M Q H].freeze

  def gray(width, height, value)
    QrReader::Image.new(width, height, value.chr.b * (width * height))
  end

  # --- QrTestEncoder: structured append ------------------------------------

  def test_structured_append_series_always_has_count_symbols
    rng = Random.new(1)
    40.times do
      count = rng.rand(2..16)
      text = Array.new(rng.rand(count..count * 5)) { (97 + rng.rand(26)).chr }.join
      series = QrTestEncoder.structured_append_series(text, count, level: :L)
      assert_equal count, series.size, "#{text.size} chars in #{count} symbols"
      headers = series.map { |s| s.segments.first.data }
      assert_equal (0...count).to_a, headers.map(&:first)
      assert_equal [count], headers.map { |h| h[1] }.uniq
      parts = series.map { |s| s.segments.last.data }
      assert_equal text, parts.join
      assert_operator parts.map(&:size).minmax.reduce(:-).abs, :<=, 1
    end
  end

  def test_structured_append_parity_uses_transmitted_bytes
    # Parity = XOR of the message as transmitted in 8-bit form (§8.3.12):
    # Shift_JIS for Kanji, GB2312 for Hanzi, not the UTF-8 source bytes.
    kanji = "漢字テスト点茗"
    series = QrTestEncoder.structured_append_series(kanji, 3, mode: :kanji)
    assert_equal [kanji.encode("Shift_JIS").bytes.reduce(:^)], series.map { |s| s.segments.first.data[2] }.uniq
    hanzi = "中文汉字测试"
    series = QrTestEncoder.structured_append_series(hanzi, 2, mode: :hanzi)
    assert_equal [hanzi.encode("GB2312").bytes.reduce(:^)], series.map { |s| s.segments.first.data[2] }.uniq
    # The default parity of a single symbol, too.
    e = QrTestEncoder.build([[:kanji, "点茗"]], structured_append: [0, 2, nil])
    assert_equal "点茗".encode("Shift_JIS").bytes.reduce(:^), e.segments.first.data[2]
    e = QrTestEncoder.build([[:numeric, "12"], [:hanzi, "中"]], structured_append: [1, 2, nil])
    assert_equal ("12".b + "中".encode("GB2312").b).bytes.reduce(:^), e.segments.first.data[2]
  end

  # --- QrTestEncoder: hostile content and options ---------------------------

  def test_strings_with_invalid_or_foreign_encodings
    invalid = "\xFF\xFE AB".dup.force_encoding(Encoding::UTF_8)
    e = QrTestEncoder.build(invalid)
    assert_equal [:byte], e.segments.map(&:mode)
    assert_equal invalid.b, e.segments.first.data
    assert_equal [:byte], QrTestEncoder.build(["\xC3(".dup.force_encoding(Encoding::UTF_8)]).segments.map(&:mode)
    # UTF-16 text: auto mode uses its bytes; explicit numeric/alphanumeric read the characters.
    utf16 = "123".encode("UTF-16LE")
    assert_equal [:byte], QrTestEncoder.build(utf16).segments.map(&:mode)
    assert_equal QrTestEncoder.build([[:numeric, "123"]], version: 1, mask: 0).matrix,
                 QrTestEncoder.build([[:numeric, utf16]], version: 1, mask: 0).matrix
    assert_equal QrTestEncoder.build([[:alphanumeric, "AB-1"]], version: 1, mask: 0).matrix,
                 QrTestEncoder.build([[:alphanumeric, "AB-1".encode("UTF-16BE")]], version: 1, mask: 0).matrix
    [
      [[:numeric, invalid]], [[:alphanumeric, invalid]], [[:alphanumeric, "ab"]], [[:numeric, "１２"]],
      [[:kanji, invalid]], [[:hanzi, "\xA2\x40".dup.force_encoding("GB2312")]], [[:kanji, "\x93\x5F".b]]
    ].each do |content|
      assert_raises(QrTestEncoder::Error, content.inspect) { QrTestEncoder.build(content) }
    end
  end

  def test_bad_option_values_raise_encoder_errors
    {
      corrupt_codewords: [nil, "3", -1, 1.5], corrupt_per_block: [nil, :foo, -1, "2"],
      corrupt_modules: [nil, -2, 0.5], seed: [nil, "abc", 1.5], mask: [-1, 8, "1", 2.0],
      level: [nil, :X, 3, "MQ"], version: [0, 41, "3", 2.0]
    }.each do |option, values|
      values.each do |value|
        assert_raises(QrTestEncoder::Error, "#{option}: #{value.inspect}") { QrTestEncoder.build("x", option => value) }
      end
    end
    [
      -> { QrTestEncoder.block_sizes(5, :X) }, -> { QrTestEncoder.block_sizes(41, :M) },
      -> { QrTestEncoder.capacity_bits(5, nil) }, -> { QrTestEncoder.data_codeword_count(0, :L) },
      -> { QrTestEncoder.format_bits(:X, 0) }, -> { QrTestEncoder.format_bits(:M, 8) },
      -> { QrTestEncoder.structured_append_series(nil, 2) }, -> { QrTestEncoder.structured_append_series("abc", "2") },
      -> { QrTestEncoder.structured_append_series("abc", 17) }, -> { QrTestEncoder.structured_append_series("ab", 3) },
      -> { QrTestEncoder.structured_append_series("ab", 2, mode: :kanji) }
    ].each { |call| assert_raises(QrTestEncoder::Error) { call.call } }
  end

  def test_lowercase_levels_are_accepted_everywhere
    assert_equal QrTestEncoder.block_sizes(12, :Q), QrTestEncoder.block_sizes(12, :q)
    assert_equal QrTestEncoder.capacity_bits(7, :H), QrTestEncoder.capacity_bits(7, "h")
    assert_equal QrTestEncoder.format_bits(:L, 3), QrTestEncoder.format_bits(:l, 3)
  end

  # Random specifications, including garbage, never raise anything but
  # QrTestEncoder::Error and never hang.
  def test_fuzzed_specifications
    rng = Random.new(42)
    atoms = [nil, 0, -1, 7, 2**70, 1.5, Float::NAN, "", "123", "ABC", "abc", "\xFF".b, "点", :numeric, :alphanumeric,
             :byte, :kanji, :hanzi, :eci, :fnc1_first, :fnc1_second, :structured_append, :bogus, [], {}, Object.new]
    300.times do
      content = Array.new(rng.rand(0..4)) { Array.new(rng.rand(0..4)) { atoms.sample(random: rng) } }
      content = atoms.sample(random: rng) if rng.rand(4).zero?
      options = {}
      options[:version] = atoms.sample(random: rng) if rng.rand(3).zero?
      options[:eci] = atoms.sample(random: rng) if rng.rand(4).zero?
      options[:fnc1] = [:first, [:second, atoms.sample(random: rng)], atoms.sample(random: rng)].sample(random: rng) if rng.rand(4).zero?
      options[:structured_append] = Array.new(3) { atoms.sample(random: rng) } if rng.rand(4).zero?
      begin
        e = QrTestEncoder.build(content, **options)
        assert_kind_of QrReader::BitMatrix, e.matrix
      rescue QrTestEncoder::Error
        nil
      end
    end
  end

  # --- QrTestEncoder: spec numbers and independent encoders ------------------

  # ISO/IEC 18004:2015 Table 7: characters per mode (numeric, alphanumeric,
  # byte, Kanji) at the largest version that still holds them.
  TABLE7 = {
    [1, :L] => [41, 25, 17, 10], [1, :M] => [34, 20, 14, 8], [1, :Q] => [27, 16, 11, 7], [1, :H] => [17, 10, 7, 4],
    [2, :L] => [77, 47, 32, 20], [9, :L] => [552, 335, 230, 141], [10, :L] => [652, 395, 271, 167],
    [10, :H] => [288, 174, 119, 74], [26, :L] => [3283, 1990, 1367, 842], [27, :L] => [3517, 2132, 1465, 902],
    [40, :L] => [7089, 4296, 2953, 1817], [40, :H] => [3057, 1852, 1273, 784]
  }.freeze

  def test_table7_capacities_at_version_boundaries
    modes = [[:numeric, "7"], [:alphanumeric, "Z"], [:byte, "a"], [:kanji, "漢"]]
    TABLE7.each do |(version, level), capacities|
      modes.zip(capacities).each do |(mode, char), capacity|
        assert_equal version, QrTestEncoder.version_for([[mode, char * capacity]], level: level), "#{version}-#{level} #{mode}"
        bigger = begin
          QrTestEncoder.version_for([[mode, char * (capacity + 1)]], level: level)
        rescue QrTestEncoder::Error
          41
        end
        assert_operator bigger, :>, version, "#{version}-#{level} #{mode} + 1"
      end
    end
  end

  # Plain transcription of §7.8.3.1 (rules N1..N4; N3 counts a 1:1:3:1:1
  # pattern once when 4 light modules precede or follow it, the area outside
  # the symbol being light).
  def reference_penalty(cells, n)
    cell = ->(x, y) { cells.getbyte(y * n + x) }
    lines = Array.new(n) { |y| Array.new(n) { |x| cell.(x, y) } } + Array.new(n) { |x| Array.new(n) { |y| cell.(x, y) } }
    score = 0
    lines.each do |line|
      line.chunk_while { |a, b| a == b }.each { |run| score += run.size - 2 if run.size >= 5 }
      (0..n - 7).each do |i|
        next unless line[i, 7] == [1, 0, 1, 1, 1, 0, 1]

        before = (i - 4...i).all? { |k| k.negative? || line[k].zero? }
        after = (i + 7...i + 11).all? { |k| k >= n || line[k].zero? }
        score += 40 if before || after
      end
    end
    (0...n - 1).each do |y|
      (0...n - 1).each do |x|
        v = cell.(x, y)
        score += 3 if v == cell.(x + 1, y) && v == cell.(x, y + 1) && v == cell.(x + 1, y + 1)
      end
    end
    score + 10 * ((cells.count("\x01") * 2 - n * n).abs * 10 / (n * n))
  end

  def test_penalty_matches_plain_reference
    rng = Random.new(8)
    [21, 25, 45, 57, 101].each_with_index do |n, i|
      density = [50, 30, 70, 45, 60][i]
      cells = Array.new(n * n) { rng.rand(100) < density ? 1 : 0 }.pack("C*")
      assert_equal reference_penalty(cells, n), QrTestEncoder.penalty(QrReader::BitMatrix.new(n, n, cells)), "random #{n}"
    end
    [[1, :L], [7, :Q], [12, :H]].each do |version, level|
      8.times do |mask|
        m = QrTestEncoder.encode("penalty #{version}", version: version, level: level, mask: mask)
        assert_equal reference_penalty(m.bits, m.width), QrTestEncoder.penalty(m), "#{version}-#{level} mask #{mask}"
      end
    end
  end

  # zint (zxing-cpp's writer) is a third encoder, independent of both
  # QrTestEncoder and rqrcode_core: same symbol for its version/level/mask,
  # and the same automatic mask choice.
  def test_symbols_and_mask_choice_match_zint
    skip "zxing-cpp reference venv not available" unless QrReference.available?

    rng = Random.new(5)
    requests = Array.new(48) do |i|
      length = rng.rand(1..300)
      text = case i % 3
             when 0 then Array.new(length) { rng.rand(10).to_s }.join
             when 1 then Array.new(length) { "ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"[rng.rand(35)] }.join
             else Array.new(length) { (97 + rng.rand(26)).chr }.join
             end
      [text, LEVELS[i % 4]]
    end
    QrReference.encode(requests).zip(requests).each do |rows, (text, level)|
      refute_nil rows, text
      theirs = QrReader::BitMatrix.from_rows(rows)
      version = (theirs.width - 17) / 4
      read_level, mask = QrTestEncoder.read_format(theirs)
      assert_equal level, read_level
      assert_equal theirs, QrTestEncoder.encode(text, version: version, level: level, mask: mask), "#{version}-#{level}"
      assert_equal mask, QrTestEncoder.build(text, version: version, level: level).mask, "auto mask #{version}-#{level}"
    end
  end

  # zxing-cpp's Plain text (character set decoding included) for symbols
  # whose bytes the HexECI test already checks.
  def test_zxing_cpp_reads_the_intended_text
    skip "zxing-cpp reference venv not available" unless QrReference.available?

    cases = {
      [[:kanji, "点茗漢字テスト"]] => [{}, "点茗漢字テスト"],
      [[:hanzi, "中文汉字测试"]] => [{}, "中文汉字测试"],
      [[:byte, "Grüße €"]] => [{ eci: 26 }, "Grüße €"],
      [[:byte, "café".encode("ISO-8859-1")]] => [{ eci: 3 }, "café"],
      [[:byte, "Zażółć".encode("ISO-8859-2")]] => [{ eci: 4 }, "Zażółć"],
      [[:numeric, "2024"], [:alphanumeric, " QR "], [:byte, "ok"], [:kanji, "漢字"]] => [{}, "2024 QR ok漢字"],
      [[:alphanumeric, "10ABC\x1D21XYZ%"]] => [{ fnc1: :first }, "10ABC\x1D21XYZ%"],
      [[:numeric, "0123456789" * 30]] => [{ structured_append: [3, 5, 7] }, "0123456789" * 30]
    }
    Dir.mktmpdir do |dir|
      paths = cases.each_with_index.map do |(content, (options, _)), i|
        path = File.join(dir, "text#{i}.png")
        QrTestHelper.write_png(QrTestEncoder.build(content, level: LEVELS[i % 4], **options).to_image(module_size: 3), path)
        path
      end
      QrReference.decode(paths, text_mode: "Plain").zip(cases.values).each do |result, (_, text)|
        assert_equal [text], result["results"].map { |r| r["text"] }
      end
    end
  end

  # --- Distort ----------------------------------------------------------------

  def test_photometric_results_are_clamped_not_wrapped
    white = gray(21, 21, 255)
    mid = gray(21, 21, 200)
    over = Distort.vignette(white, strength: 1.5)
    assert_equal 0, over[0, 0]
    assert_equal 255, over[10, 10]
    under = Distort.vignette(mid, strength: -0.5)
    assert_equal 255, under[0, 0]
    assert_equal 200, under[10, 10]
    # Darkening never brightens a pixel and vice versa.
    [0.0, 0.3, 1.0, 2.0].each do |strength|
      v = Distort.vignette(mid, strength: strength)
      assert v.data.bytes.all? { |b| b <= 200 }, "vignette #{strength}"
    end
    dark = Distort.shadow(mid, darkness: 1.5, softness: 0.01, seed: 1).data.bytes
    assert_equal [0, 200], dark.minmax
    light = Distort.shadow(mid, darkness: -0.5, softness: 0.01, seed: 1).data.bytes
    assert_equal [200, 255], light.minmax
    assert_equal [255], Distort.gamma(gray(2, 2, 0), -1).data.bytes.uniq # 0 ** -1 = Infinity, clamped
  end

  def test_motion_blur_kernels_have_no_holes
    impulse = ->(w, h) { QrReader::Image.new(w, h, "\0".b * (w * h)).tap { |img| img.data.setbyte((h / 2) * w + w / 2, 255) } }
    (2..12).each do |length|
      row = Distort.motion_blur(impulse.(31, 1), length: length, angle: 0).data.bytes
      lit = row.each_index.select { |i| row[i].positive? }
      assert_equal length, lit.size, "length #{length}"
      assert_equal (lit.first..lit.last).to_a, lit, "length #{length} is contiguous"
      assert_includes lit, 15
      col = Distort.motion_blur(impulse.(1, 31), length: length, angle: 90).data.bytes
      assert_equal row, col, "length #{length} vertical"
    end
  end

  def test_motion_blur_with_absurd_length_stays_bounded
    img = QrReader::Image.new(30, 20, (0...600).map { |i| (i * 37) % 256 }.pack("C*"))
    started = BenchSupport.now
    blurred = Distort.motion_blur(img, length: 200_000, angle: 33)
    assert_operator BenchSupport.now - started, :<, 5
    assert_equal [30, 20], [blurred.width, blurred.height]
  end

  def test_box_blur_with_large_radius_matches_reference_and_is_fast
    img = QrReader::Image.new(9, 7, (0...63).map { |i| (i * 53) % 256 }.pack("C*"))
    [8, 9, 15, 40].each do |r|
      diff = Distort.box_blur(img, r).data.bytes.zip(QrTestHelper.blur(img, r).data.bytes).map { |a, b| (a - b).abs }.max
      assert_operator diff, :<=, 1, "radius #{r}"
    end
    started = BenchSupport.now
    Distort.box_blur(gray(30, 30, 9), 1_000_000)
    assert_operator BenchSupport.now - started, :<, 0.5
  end

  def test_cylinder_extremes
    ramp = QrReader::Image.new(40, 10, Array.new(400) { |i| (i % 40) * 6 }.pack("C*"))
    assert_equal ramp.data, Distort.cylinder(ramp, arc: 0).data
    full = Distort.cylinder(gray(100, 10, 0), arc: 360, bulge: 0)
    visible = full.row(5).bytes.count(0)
    assert_in_delta 100 / Math::PI, visible, 2 # the front half of a cylinder 100 px round
    # Past 180 degrees the whole front side stays visible (no blank band).
    wide = Distort.cylinder(gray(100, 10, 0), arc: 200, bulge: 0)
    assert_in_delta 100 / (200 * Math::PI / 360), wide.row(5).bytes.count(0), 2
    assert_raises(ArgumentError) { Distort.cylinder(ramp, arc: 400) }
    assert_raises(ArgumentError) { Distort.cylinder(ramp, arc: -5) }
  end

  def test_perspective_matches_qr_test_helper_on_random_quads
    img = QrTestEncoder.build("RANDOM QUADS", version: 2, mask: 1).to_image(module_size: 3)
    rng = Random.new(17)
    6.times do
      corners = [[0, 0], [1, 0], [1, 1], [0, 1]].map { |x, y| [x * 120 + rng.rand(-25.0..25.0) + 30, y * 120 + rng.rand(-25.0..25.0) + 30] }
      ours = Distort.perspective(img, corners, 180, 180, supersample: 2)
      theirs = QrTestHelper.warp(img, corners, 180, 180)
      diff = ours.data.bytes.zip(theirs.data.bytes).map { |a, b| (a - b).abs }.max
      assert_operator diff, :<=, 1, corners.inspect
    end
  end

  def test_parameter_validation
    img = gray(8, 8, 100)
    [
      -> { Distort.lut(img, [0, 1, 2]) }, -> { Distort.lut(img, Array.new(256, Float::NAN)) },
      -> { Distort.scale(img, 0) }, -> { Distort.scale(img, -1) }, -> { Distort.scale(img, Float::NAN) },
      -> { Distort.resize(img, 0, 4) }, -> { Distort.resize(img, 4, 2.5) },
      -> { Distort.blur(img, Float::NAN) }, -> { Distort.apply(img, [:nope]) }, -> { Distort.apply(img, [:square_to_quad]) }
    ].each { |call| assert_raises(ArgumentError) { call.call } }
    assert_equal [255], Distort.lut(img, Array.new(256, Float::INFINITY)).data.bytes.uniq
    started = BenchSupport.now
    sp = Distort.salt_pepper(img, amount: 1e12, seed: 1) # clamped to 1: one draw per pixel
    assert_operator BenchSupport.now - started, :<, 1
    assert_operator sp.data.bytes.count { |v| v != 100 }, :>, 32
  end

  def test_parse_pgm_header_variants
    assert_equal [1, 2], Distort.parse_pgm("P5\n# made by hand\n2 1\n# max\n255\n\x01\x02".b).data.bytes
    assert_equal [0, 255, 136], Distort.parse_pgm("P5 3 1 15\n\x00\x0F\x08".b).data.bytes
    assert_raises(ArgumentError) { Distort.parse_pgm("P5\n2 1\n65535\n\x00\x00\x00\x00".b) }
    assert_raises(ArgumentError) { Distort.parse_pgm("P6\n1 1\n255\n\x00\x00\x00".b) }
    img = QrTestEncoder.build("pgm").to_image(module_size: 2)
    assert_equal img.data, Distort.parse_pgm(Distort.pgm_bytes(img)).data
  end

  # --- bench helpers -----------------------------------------------------------

  def test_reports_survive_invalid_utf8_texts
    bad = "\xFF\xFEabc".dup.force_encoding(Encoding::UTF_8)
    assert_equal "��abc", BenchSupport.utf8(bad)
    assert_equal "é", BenchSupport.utf8("é".encode("ISO-8859-1"))
    assert_equal "ok", BenchSupport.utf8("ok".encode("UTF-16LE"))
    assert_equal "�", BenchSupport.utf8("\xE9".b)
    outcome = CorpusBench::Outcome.new(pass: false, ms: 1.0, texts: [bad, "\xC0".b], error: "boom \xFF".b)
    kase = QrCorpus::Case.new(dir: "qrcode-1", name: "1.png", path: "/x/1.png", expected: "x")
    json = CorpusBench.to_json([kase], { "qrcode-1/1.png@0" => outcome }, [], 1.0, { rotations: [0] }, "test")
    assert JSON.generate(json).valid_encoding?
    sample = SyntheticBench::Sample.new(input: nil, expected: ["x"])
    synth = SyntheticBench.classify(sample, [bad], 2.0)
    case_list = [SyntheticBench::Case.new(id: "f/a", family: "f", quick: true, build: nil)]
    assert JSON.generate(SyntheticBench.to_json(case_list, { "f/a" => synth }, {}, "test")).valid_encoding?
  end

  def test_missing_component_detection
    missing_constant = begin
      QrReader.const_get(:NoSuchComponentForTest)
    rescue NameError => e
      e
    end
    missing_method = begin
      QrReader::Image.no_such_stage_for_test
    rescue NoMethodError => e
      e
    end
    bug = begin
      nil.upcase
    rescue NoMethodError => e
      e
    end
    assert BenchSupport.missing_component?(missing_constant)
    assert BenchSupport.missing_component?(missing_method)
    assert BenchSupport.missing_component?(NotImplementedError.new)
    refute BenchSupport.missing_component?(bug)
    refute BenchSupport.missing_component?(RuntimeError.new("x"))
  end

  # zxcpp.py composites alpha over white like QrReader (PIL's convert("L")
  # alone turns a transparent background black) and reports unreadable
  # files instead of aborting the batch.
  def test_reference_reader_handles_alpha_and_garbage
    skip "zxing-cpp reference venv not available" unless QrReference.available?

    matrix = QrTestEncoder.encode("ALPHA", version: 1, level: :M, mask: 2)
    gray_img = QrTestEncoder.render(matrix, module_size: 4)
    rgba = gray_img.data.bytes.flat_map { |v| v.zero? ? [0, 0, 0, 255] : [0, 0, 0, 0] }.pack("C*")
    Dir.mktmpdir do |dir|
      alpha = File.join(dir, "alpha.png")
      File.binwrite(alpha, rgba_png(gray_img.width, gray_img.height, rgba))
      garbage = File.join(dir, "garbage.png")
      File.binwrite(garbage, "not an image")
      results = QrReference.decode([alpha, garbage, alpha])
      assert_equal 3, results.size
      assert_equal ["ALPHA"], results[0]["results"].map { |r| r["text"] }
      assert_empty results[1]["results"]
      assert_match(/Error/, results[1]["error"])
      assert_equal ["ALPHA"], results[2]["results"].map { |r| r["text"] }
    end
  end

  def rgba_png(width, height, rgba)
    raw = String.new(encoding: Encoding::BINARY)
    height.times { |y| raw << "\0" << rgba.byteslice(y * width * 4, width * 4) }
    chunk = ->(type, body) { [body.bytesize].pack("N") + type + body + [Zlib.crc32(type + body)].pack("N") }
    "\x89PNG\r\n\x1a\n".b + chunk.("IHDR", [width, height, 8, 6, 0, 0, 0].pack("NNCCCCC")) +
      chunk.("IDAT", Zlib::Deflate.deflate(raw)) + chunk.("IEND", "".b)
  end
end
