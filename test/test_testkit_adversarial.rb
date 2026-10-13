# frozen_string_literal: true

require_relative "test_helper"
require "qr_encoder"
require "distort"
require "reference"
require "tmpdir"
require_relative "../bench/support"
require_relative "../bench/corpus"
require_relative "../bench/synthetic"
require_relative "../bench/speed"
require "digest"

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

  # --- second pass: structured append parity, GS%, rqrcode masks ------------

  # §8.3.12: the parity is the XOR of the original message bytes, so GS and
  # "%" count as themselves, not as the "%" / "%%" escapes that alphanumeric
  # segments use after FNC1.
  def test_structured_append_parity_ignores_fnc1_escapes
    message = "A\x1DB%%C"
    e = QrTestEncoder.build([[:alphanumeric, message]], fnc1: :first, structured_append: [0, 2, nil])
    assert_equal "A%B%%%%C", e.segments.last.data
    assert_equal message.bytes.reduce(:^), e.segments.first.data[2]
    text = "10ABC\x1D21XY%Z\x1D30%%7"
    series = QrTestEncoder.structured_append_series(text, 3, mode: :alphanumeric, fnc1: :first, level: :L)
    assert_equal [text.bytes.reduce(:^)], series.map { |s| s.segments.first.data[2] }.uniq
  end

  # "GS%" would be written as "%%%", which decoders (ZXing, zxing-cpp)
  # read as "%GS": the encoder refuses it in one alphanumeric segment and
  # automatic mode falls back to byte mode; a segment break is unambiguous.
  def test_gs_followed_by_percent_is_never_misencoded
    assert_raises(QrTestEncoder::Error) { QrTestEncoder.build([[:alphanumeric, "AB\x1D%C"]], fnc1: :first) }
    assert_raises(QrTestEncoder::Error) { QrTestEncoder.structured_append_series("A\x1D%BC", 2, mode: :alphanumeric, fnc1: :first) }
    # Split between the GS and the "%", the parts are unambiguous.
    assert_equal 2, QrTestEncoder.structured_append_series("A\x1D%B", 2, mode: :alphanumeric, fnc1: :first).size
    auto = QrTestEncoder.build("AB\x1D%C", fnc1: :first)
    assert_equal %i[fnc1_first byte], auto.segments.map(&:mode)
    assert_equal %i[fnc1_first alphanumeric], QrTestEncoder.build("AB%\x1DC", fnc1: :first).segments.map(&:mode)
    skip "zxing-cpp reference venv not available" unless QrReference.available?

    symbols = [auto, QrTestEncoder.build([[:alphanumeric, "AB\x1D"], [:alphanumeric, "%C"]], fnc1: :first),
               QrTestEncoder.build("AB%\x1DC", fnc1: :first)]
    Dir.mktmpdir do |dir|
      paths = symbols.each_with_index.map do |sym, i|
        File.join(dir, "gs#{i}.png").tap { |path| QrTestHelper.write_png(sym.to_image(module_size: 3), path) }
      end
      texts = QrReference.decode(paths, text_mode: "Plain").map { |r| r["results"].map { |x| x["text"] } }
      assert_equal [["AB\x1D%C"], ["AB\x1D%C"], ["AB%\x1DC"]], texts
    end
  end

  # The requirement's own check for the remaining versions: rqrcode_core
  # chooses the mask, we read it from its format bits and must produce the
  # same symbol (test_encoder covers 1-10, 14, 21, 27, 33 and 40 this way).
  # rqrcode's mask evaluation is slow: a third of them by default, all with
  # QR_ENCODER_FULL=1.
  def test_matches_rqrcode_mask_choice_for_every_version
    rng = Random.new(31)
    versions = (11..39).to_a - [14, 21, 27, 33]
    versions = versions.each_slice(3).map(&:first) unless ENV["QR_ENCODER_FULL"]
    versions.each do |version|
      level = LEVELS[version % 4]
      mode, ours = [[:number, :numeric], [:alphanumeric, :alphanumeric], [:byte_8bit, :byte]][version % 3]
      chars = { number: "0123456789", alphanumeric: QrTestEncoder::ALPHANUMERIC_CHARSET, byte_8bit: "abcdefghij.-/:" }[mode]
      text = Array.new(rng.rand(1..60)) { chars[rng.rand(chars.size)] }.join
      theirs = QrReader::BitMatrix.from_rows(RQRCodeCore::QRCode.new(text, level: level.downcase, size: version, mode: mode).modules)
      read_level, mask = QrTestEncoder.read_format(theirs)
      assert_equal level, read_level, "version #{version}"
      assert_equal theirs, QrTestEncoder.encode([[ours, text]], version: version, level: level, mask: mask),
                   "#{version}-#{level} mask #{mask} #{mode}"
    end
  end

  def test_render_and_penalty_validate_their_arguments
    matrix = QrTestEncoder.encode("x", version: 1)
    [{ module_size: 0 }, { module_size: 2.5 }, { quiet: -1 }, { quiet: 1.5 }, { dark: 256 }, { light: -1 }, { dark: "0" }].each do |options|
      assert_raises(QrTestEncoder::Error, options.inspect) { QrTestEncoder.render(matrix, **options) }
    end
    assert_equal [21, 21], QrTestEncoder.render(matrix, module_size: 1, quiet: 0).then { |img| [img.width, img.height] }
    assert_raises(QrTestEncoder::Error) { QrTestEncoder.penalty(QrReader::BitMatrix.new(21, 25)) }
  end

  def test_encoded_ec_level_is_lowercase_like_results
    assert_equal :q, QrTestEncoder.build("x", level: "q").ec_level
    assert_equal :Q, QrTestEncoder.build("x", level: :q).level
    assert_equal %i[l m q h], LEVELS.map { |level| QrTestEncoder.build("x", level: level).ec_level }
  end

  # --- second pass: Distort ---------------------------------------------------------

  # Output bytes recorded with the original whole-image loops before they
  # were split into per-row kernels; the synthetic baselines depend on them.
  # Float rounding of libm functions may differ on other platforms.
  PINNED = {
    "gradient" => "185x185:a5c47ec3408fda8eca810c82a33eb45d",
    "vignette" => "185x185:6bad1294159381be34f270d60832048d",
    "shadow" => "185x185:573df56178bbdbe1bdfe268c3690ef3d",
    "gaussian_noise" => "185x185:3efc538d2a6ee1f332fbeddb40b4464e",
    "salt_pepper" => "185x185:4a5a31b4ab18ad428e7d92d818e9b80c",
    "blur" => "185x185:b2fb9f0ffe9d98cfb691e38254ad5aae",
    "motion_blur" => "185x185:36b83b9aad4f8368087bfa3d5d047cc2",
    "scale_down" => "68x68:30999a9fd4ad924cc16f0903f3a425a0",
    "scale_up" => "296x296:2b053cc589fc100c56e8de2449d557a4",
    "perspective" => "210x220:9992584793dad8340e8065f6b2be0b28",
    "tilt" => "185x185:fe0b6d12da4191b1c5709896e5035c07",
    "rotate" => "277x277:cbe616a54667ca2b1a4d7059da7c880f",
    "cylinder" => "185x185:1ab212231cd3c62db9d0c7e294cb332a",
    "barrel" => "185x185:30e001145c6da87badd95b73a67ec0d9"
  }.freeze

  def test_outputs_match_pinned_digests
    skip "digests pinned on x86_64 Linux" unless RUBY_PLATFORM.start_with?("x86_64-linux")

    img = Distort.gaussian_noise(QrTestEncoder.build("PINNED OUTPUT", version: 3, level: :Q, mask: 4).to_image(module_size: 5),
                                 sigma: 6, seed: 11)
    outputs = {
      "gradient" => Distort.gradient(img, from: 1.1, to: 0.35, angle: 125),
      "vignette" => Distort.vignette(img, strength: 0.7),
      "shadow" => Distort.shadow(img, darkness: 0.6, softness: 0.1, seed: 7),
      "gaussian_noise" => Distort.gaussian_noise(img, sigma: 20, seed: 3),
      "salt_pepper" => Distort.salt_pepper(img, amount: 0.03, seed: 3),
      "blur" => Distort.blur(img, 1.7),
      "motion_blur" => Distort.motion_blur(img, length: 8, angle: 35),
      "scale_down" => Distort.scale(img, 0.37),
      "scale_up" => Distort.scale(img, 1.6),
      "perspective" => Distort.perspective(img, [[12.5, 30], [170, 5], [190, 200], [3, 160]], 210, 220,
                                           background: 200, supersample: 3),
      "tilt" => Distort.perspective_tilt(img, strength: 0.25, seed: 9),
      "rotate" => Distort.rotate(img, 33.3),
      "cylinder" => Distort.cylinder(img, arc: 140, bulge: 0.1),
      "barrel" => Distort.barrel(img, k: -0.2, background: 30)
    }
    outputs.each do |name, out|
      assert_equal PINNED.fetch(name), "#{out.width}x#{out.height}:#{Digest::MD5.hexdigest(out.data)}", name
    end
  end

  # The documented algorithm in one piece: a 65536-entry Box-Muller table,
  # then one little-endian 16-bit pick per pixel from a single rng.bytes
  # call. Row-wise drawing must give the same stream for any image shape.
  def test_gaussian_noise_matches_one_shot_reference
    rng = Random.new(2)
    [[1, 1], [1, 9], [9, 1], [3, 3], [7, 5], [8, 3], [31, 17]].each do |w, h|
      img = QrReader::Image.new(w, h, Array.new(w * h) { rng.rand(256) }.pack("C*"))
      noise = Random.new(77)
      table = Array.new(65_536) { (Math.sqrt(-2 * Math.log(1 - noise.rand)) * Math.cos(2 * Math::PI * noise.rand) * 30).round }
      picks = noise.bytes(2 * w * h).unpack("v*")
      expected = img.data.bytes.each_with_index.map { |v, i| (v + table[picks[i]]).clamp(0, 255) }.pack("C*")
      assert_equal expected, Distort.gaussian_noise(img, sigma: 30, seed: 77).data, "#{w}x#{h}"
    end
  end

  def test_invalid_parameters_raise_argument_error
    img = gray(12, 10, 128)
    nan = Float::NAN
    corners = [[0, 0], [12, 0], [12, 10], [0, 10]]
    [
      -> { Distort.perspective(img, corners, 12, 10, supersample: 0) },
      -> { Distort.perspective(img, corners, 12, 10, supersample: 1.5) },
      -> { Distort.perspective(img, corners, 12, 10, supersample: 17) },
      -> { Distort.perspective(img, corners, 12, 10, background: 256) },
      -> { Distort.perspective(img, corners.first(3), 12, 10) },
      -> { Distort.perspective(img, [[0, 0], [12, nan], [12, 10], [0, 10]], 12, 10) },
      -> { Distort.perspective(img, corners, 0, 10) },
      -> { Distort.pad(img, 2.5) }, -> { Distort.pad(img, -1) }, -> { Distort.pad(img, 2, value: 256) },
      -> { Distort.compose(20, 20, [[img, 1.5, 2]]) }, -> { Distort.compose(20, 20, [[img, 1, 2]], background: -1) },
      -> { Distort.box_blur(img, 1.5) }, -> { Distort.motion_blur(img, length: 3.5) },
      -> { Distort.motion_blur(img, angle: nan) }, -> { Distort.rotate(img, nan) }, -> { Distort.rotate(img, 5, margin: -1) },
      -> { Distort.gradient(img, angle: nan) }, -> { Distort.gradient(img, to: Float::INFINITY) },
      -> { Distort.vignette(img, strength: nan) }, -> { Distort.shadow(img, softness: nan) },
      -> { Distort.gaussian_noise(img, sigma: nan) }, -> { Distort.gaussian_noise(img, sigma: Float::INFINITY) },
      -> { Distort.salt_pepper(img, amount: nan) }, -> { Distort.perspective_tilt(img, strength: nan) },
      -> { Distort.cylinder(img, bulge: nan) }, -> { Distort.cylinder(img, arc: "90") }, -> { Distort.barrel(img, k: nan) },
      -> { Distort.barrel(img, background: 300) }, -> { Distort.contrast(img, low: "0") }, -> { Distort.brightness(img, nil) },
      -> { Distort.jpeg_bytes(img, quality: "abc") }, -> { Distort.jpeg_bytes(img, quality: 0) },
      -> { Distort.jpeg_bytes(img, quality: 101) }, -> { Distort.jpeg(img, quality: 50.5) }
    ].each_with_index { |call, i| assert_raises(ArgumentError, "call #{i}") { call.call } }
  end

  # Absurd sizes fail fast instead of allocating gigabytes or looping for minutes.
  def test_absurd_sizes_are_rejected_or_bounded
    img = QrReader::Image.new(30, 20, (0...600).map { |i| (i * 37) % 256 }.pack("C*"))
    [
      -> { Distort.scale(img, 1e5) }, -> { Distort.scale(img, 1e300) }, -> { Distort.resize(img, 100_000, 100_000) },
      -> { Distort.perspective(img, [[0, 0], [1, 0], [1, 1], [0, 1]], 1 << 20, 1 << 20) },
      -> { Distort.rotate(img, 10, margin: 1 << 20) }, -> { Distort.pad(img, 1 << 20) },
      -> { Distort.compose(1 << 20, 1 << 20, []) }
    ].each_with_index { |call, i| assert_raises(ArgumentError, "call #{i}") { call.call } }
    started = BenchSupport.now
    [[10**9, 33], [10**12, 90], [10**9 + 1, 89.99999], [10**10, 0.00001]].each do |length, angle|
      blurred = Distort.motion_blur(img, length: length, angle: angle)
      assert_equal [30, 20], [blurred.width, blurred.height]
    end
    assert_operator BenchSupport.now - started, :<, 2
    # The same weights as summing every step one by one.
    [[1, 0], [2, 45], [8, 35], [15, 135], [40, 89.5], [1001, 10], [4000, 271]].each do |length, angle|
      rad = angle * Math::PI / 180
      expected = Array.new(length) do |i|
        t = i - length / 2
        [(t * Math.cos(rad)).round.clamp(-30, 30), (t * Math.sin(rad)).round.clamp(-20, 20)]
      end.tally
      assert_equal expected.to_a, Distort.send(:motion_offsets, length, rad, 30, 20).to_a, "#{length} at #{angle}"
    end
  end

  # Coordinates exactly on the edges and NaN/Infinity from degenerate quads
  # sample the border pixels or the background, never raise.
  def test_degenerate_warps_give_background
    img = QrReader::Image.new(4, 3, (1..12).to_a.pack("C*"))
    point = Distort.perspective(img, [[5, 5]] * 4, 10, 10, background: 77)
    assert_equal [77], point.data.bytes.uniq
    line = Distort.perspective(img, [[0, 0], [10, 0], [10, 0], [0, 0]], 10, 10, background: 9, supersample: 2)
    assert_equal [10, 10], [line.width, line.height]
    # Infinite and NaN (0 * Infinity) coordinates.
    assert_equal [255], Distort.barrel(img, k: Float::MAX).data.bytes.uniq
  end

  # --- second pass: reference runner and bench scripts -------------------------------

  def test_reference_decode_accepts_paths_that_look_like_options
    skip "zxing-cpp reference venv not available" unless QrReference.available?

    Dir.mktmpdir do |dir|
      QrTestHelper.write_png(QrTestEncoder.build("DASH").to_image, File.join(dir, "--pure"))
      QrTestHelper.write_png(QrTestEncoder.build("MINUS").to_image, File.join(dir, "-x.png"))
      results = Dir.chdir(dir) { QrReference.decode(["--pure", "-x.png"]) }
      assert_equal [["DASH"], ["MINUS"]], results.map { |r| r["results"].map { |x| x["text"] } }
    end
  end

  def test_report_comparison_rejects_foreign_reports
    Dir.mktmpdir do |dir|
      speed_report = File.join(dir, "speed.json")
      File.write(speed_report, JSON.generate({ "meta" => {}, "timings" => {} }))
      current = { "cases" => { "a" => { "pass" => true } } }
      _, err = capture_io do
        assert_raises(SystemExit) { BenchSupport.compare_reports(speed_report, current, "vs speed") }
      end
      assert_match(/no "cases"/, err)
      corpus_report = File.join(dir, "corpus.json")
      File.write(corpus_report, JSON.generate(current))
      _, err = capture_io do
        assert_raises(SystemExit) { SpeedBench.compare([], corpus_report) }
      end
      assert_match(/no "timings"/, err)
    end
  end

  def test_bench_option_errors_and_ci_limits
    parser = OptionParser.new { |o| o.on("--n N", Integer) }
    _, err = capture_io do
      error = assert_raises(SystemExit) { BenchSupport.parse!(parser, ["--n", "x"]) }
      assert_equal 2, error.status
    end
    assert_match(/invalid argument/, err)
    assert_equal ["2.0x faster", "4.0x slower", "1.0x faster", "-"],
                 [[10.0, 5.0], [0.5, 2.0], [3.0, 3.0], [0.0, 1.0]].map { |b, a| BenchSupport.speed_change(b, a) }
    assert_nil BenchSupport.check_limits(10, min_pass: 10, wrong: 0, max_wrong: 0)
    assert_nil BenchSupport.check_limits(3)
    [[{ min_pass: 11 }, /at least 11/], [{ wrong: 1, max_wrong: 0 }, /1 misreads/]].each do |options, message|
      _, err = capture_io do
        error = assert_raises(SystemExit) { BenchSupport.check_limits(10, **options) }
        assert_equal 1, error.status
      end
      assert_match message, err
    end
  end

  # The RGB variant decodes (Pillow, independent of BenchSupport) to the
  # same luminance.
  def test_rgb_png_writer
    image = QrReader::Image.new(7, 3, (0...21).map { |i| i * 12 }.pack("C*"))
    png = BenchSupport.png_bytes(image, rgb: true)
    raw = Zlib::Inflate.inflate(png.byteslice(41, png.byteslice(33, 4).unpack1("N")))
    assert_equal (0...3).map { |y| "\0".b + image.row(y).bytes.flat_map { |v| [v] * 3 }.pack("C*") }.join, raw
    skip "zxing-cpp reference venv not available" unless QrReference.available?

    Dir.mktmpdir do |dir|
      path = File.join(dir, "rgb.png")
      File.binwrite(path, BenchSupport.png_bytes(QrTestEncoder.build("RGB PNG").to_image, rgb: true))
      assert_equal ["RGB PNG"], QrReference.decode([path])[0]["results"].map { |r| r["text"] }
    end
  end

  def test_speed_bench_fixtures_are_meant_to_decode
    fixtures = SpeedBench::Inputs.new.fixture_jpegs
    skip "no JPEG fixtures" if fixtures.empty?

    fixtures.each do |path|
      QrReader::Formats.decode(File.binread(path))
    rescue QrReader::UnsupportedImageError => e
      flunk "#{path}: #{e.message}"
    rescue StandardError
      nil # other failures are the JPEG decoder's own tests' business
    end
    assert_equal 3, fixtures.size
  end
end
