# frozen_string_literal: true

# Tests for the scan corpus tooling: the simulation library
# (test/support/scan_sim.rb), payloads, the generator's case matrix and the
# runner's scoring. Rendering tests need ImageMagick and are skipped without it.
#
#   bundle exec ruby -Itest bench/scans/test_scans.rb

require "test_helper"
require "tmpdir"
require "stringio"
require_relative "generate"
require_relative "run"

class TestScanSim < Minitest::Test
  include ScanSim

  def code(text = "https://example.com/scan", level: :m)
    Code.encode(text, level: level)
  end

  # Rasterises the "rectangle x0,y0 x1,y1" lines (inclusive pixel corners)
  # of an MVG string into a set of dark pixels.
  def dark_pixels(mvg)
    pixels = {}
    mvg.scan(/^rectangle (-?\d+),(-?\d+) (-?\d+),(-?\d+)$/) do |x0, y0, x1, y1|
      (y0.to_i..y1.to_i).each { |y| (x0.to_i..x1.to_i).each { |x| pixels[[x, y]] = true } }
    end
    pixels
  end

  def test_affine_composition_and_inverse
    t = Affine.translate(10, 5) * Affine.rotate(30) * Affine.scale(2, 3)
    x, y = t.apply(1.5, -2.0)
    back = t.inverse.apply(x, y)
    assert_in_delta 1.5, back[0], 1e-9
    assert_in_delta(-2.0, back[1], 1e-9)
    # Clockwise on screen: +x turns towards +y.
    rx, ry = Affine.rotate(90).apply(1, 0)
    assert_in_delta 0, rx, 1e-12
    assert_in_delta 1, ry, 1e-12
    # ImageMagick AffineProjection order: sx, rx, ry, sy, tx, ty.
    assert_equal "1.00000000,4.00000000,2.00000000,5.00000000,3.00000000,6.00000000",
                 Affine.new(a: 1.0, b: 2.0, c: 3.0, d: 4.0, e: 5.0, f: 6.0).to_magick
  end

  def test_qr_modules_are_exact_pixel_rectangles
    c = code
    n = c.modules
    doc = Document.new(60, 60)
    doc.ink.qr(c, 10, 10, n.to_f) # 1 mm modules
    pixels = dark_pixels(doc.ink.to_mvg(10.0, 600, 600)) # 10 px modules from (100, 100)
    n.times do |my|
      n.times do |mx|
        assert_equal c.matrix.dark?(mx, my), pixels.key?([100 + mx * 10 + 5, 100 + my * 10 + 5]), "module #{mx},#{my}"
      end
    end
    assert_equal c.matrix.bits.count("\x01") * 100, pixels.size
    refute pixels.key?([99, 100])
  end

  def test_gain_grows_and_shrinks_dark_modules
    c = code
    counts = [-0.2, 0.0, 0.2].map do |gain|
      doc = Document.new(60, 60)
      doc.ink.qr(c, 10, 10, c.modules.to_f, gain: gain) # 1 mm modules
      dark_pixels(doc.ink.to_mvg(10.0, 600, 600)).size # 10 px modules
    end
    assert_operator counts[0], :<, counts[1]
    assert_operator counts[1], :<, counts[2]
    # 20% gain = 1 px on each side of a 10 px module.
    lone = c.matrix.bits.count("\x01")
    assert_operator counts[2], :>, counts[1] + lone
  end

  def test_swiss_cross_is_drawn_in_the_centre
    c = Code.encode(ScanPayloads.qr_bill(Random.new(1)), level: :m)
    doc = Document.new(60, 60)
    doc.ink.qr(c, 7, 7, 46, cross: true)
    mvg = doc.ink.to_mvg(10.0, 600, 600)
    assert_includes mvg, "fill 'white' rectangle 265,265 334,334" # 7 mm white square around (300, 300)
    assert_includes mvg, "fill 'black' rectangle"
  end

  def test_page_geometry_follows_rotation_and_fax_resolution
    doc = Document.new(100, 50)
    doc.ink.qr(code, 10, 20, 20)
    { 0 => [[20, 30], [1181, 591]], 90 => [[20, 20], [591, 1181]], 180 => [[80, 20], [1181, 591]],
      270 => [[30, 80], [591, 1181]] }.each do |rotation, (centre_mm, size)|
      page = Page.new(doc, scan: Scan.new(dpi: 300, rotation: rotation))
      assert_equal size, page.size, "rotation #{rotation}"
      cx, cy = page.truth.first[:center]
      assert_in_delta centre_mm[0] * 300 / 25.4, cx, 0.2, "rotation #{rotation}"
      assert_in_delta centre_mm[1] * 300 / 25.4, cy, 0.2, "rotation #{rotation}"
    end
    fax = Page.new(doc, scan: Scan.new(dpi: [204, 98], mode: :threshold))
    assert_equal [803, 193], fax.size
    module_mm = 20.0 / fax.truth.first[:modules]
    assert_equal [module_mm * 204 / 25.4, module_mm * 98 / 25.4].map { |v| v.round(2) }, fax.truth.first[:module_px]
  end

  def test_skew_rotates_about_the_document_centre_and_glass_offsets
    doc = Document.new(100, 100)
    doc.ink.qr(code, 45, 45, 10) # centred symbol
    page = Page.new(doc, scan: Scan.new(dpi: 254, skew: 2.5))
    cx, cy = page.truth.first[:center]
    assert_in_delta 500, cx, 1e-6
    assert_in_delta 500, cy, 1e-6
    placed = Page.new(doc, scan: Scan.new(dpi: 254, area: [216, 297], position: [10, 20]))
    assert_equal [2160, 2970], placed.size
    assert_equal [600.0, 700.0], placed.truth.first[:center]
  end

  def test_clip_line_to_document
    square = [[0, 0], [10, 0], [10, 10], [0, 10]]
    t0, t1 = ScanSim.clip_line(-5, 5, 1, 0, square)
    assert_in_delta 5, t0, 1e-9
    assert_in_delta 15, t1, 1e-9
    assert_nil ScanSim.clip_line(-5, 20, 1, 0, square)
  end

  def test_scan_rejects_bad_settings
    assert_raises(ArgumentError) { Scan.new(mode: :sepia) }
    assert_raises(ArgumentError) { Scan.new(rotation: 45) }
    doc = Document.new(20, 20)
    assert_raises(ArgumentError) { ScanSim.render([Page.new(doc)], "x.tif", format: "tiff-g4") }
  end

  def test_render_formats_and_ground_truth
    skip "ImageMagick not available" unless ScanSim.available?

    c = code("https://example.com/scan-sim-test")
    doc = Document.new(60, 50, paper: "#f6f1e4", texture: 0.8)
    doc.ink.text(5, 8, "Grüße aus dem Test", size: 9)
    doc.ink.qr(c, 30, 15, 22)
    sticker = code("ANGLED STICKER")
    doc.ink.qr(sticker, 6, 22, 12, angle: 15, background: "white") # rendered as a rotated patch
    doc.marks.polyline([[5, 40], [25, 44]], color: "#1b2f9e", width: 0.4, smooth: true)
    Dir.mktmpdir do |dir|
      {
        "png-gray" => [Scan.new(dpi: 300, blur: 0.5, noise: 2, skew: 1.0), "\x89PNG".b],
        "jpeg-color" => [Scan.new(dpi: 200, mode: :color, rotation: 90), "\xFF\xD8".b],
        "tiff-g4" => [Scan.new(dpi: 300, mode: :threshold, rotation: 180), "II*\0".b],
        "pdf-g4" => [Scan.new(dpi: 300, mode: :adaptive), "%PDF".b]
      }.each do |format, (scan, magic)|
        page = Page.new(doc, scan: scan)
        path = File.join(dir, "case.#{ScanSim.extension(format)}")
        ScanSim.render([page], path, format: format, quality: 85, seed: 7)
        bytes = File.binread(path)
        assert bytes.start_with?(magic), format
        next unless format == "png-gray"

        image = QrReader::Formats.decode(bytes)
        assert_equal page.size, [image.width, image.height]
        # The reader is someone else's component: check positions of what it decodes.
        QrReader.read_all(path).each do |result|
          truth = page.truth.find { |t| t[:text] == result.text }
          refute_nil truth, "unexpected text #{result.text.inspect}"
          cx = result.points.sum { |p| p[0] } / 4.0
          cy = result.points.sum { |p| p[1] } / 4.0
          assert_in_delta truth[:center][0], cx, 3
          assert_in_delta truth[:center][1], cy, 3
        end
      end
    end
  end
end

class TestScanPayloads < Minitest::Test
  def test_check_digits
    assert_equal "CH4431999123000889012", ScanPayloads.iban(nil, "CH", "31999123000889012")
    assert_equal "210000000003139471430009017", ScanPayloads.qrr_reference("21000000000313947143000901")
    assert_equal "RF18539007547034", ScanPayloads.scor_reference("539007547034")
  end

  def test_qr_bill_structure
    rng = Random.new(3)
    20.times do
      text = ScanPayloads.qr_bill(rng)
      lines = text.split(/\r?\n/, -1)
      assert_equal %w[SPC 0200 1], lines[0, 3]
      assert_match(/\ACH\d{19}\z/, lines[3])
      assert_equal "S", lines[4]
      assert_equal "CHF", lines[19]
      assert_includes %w[QRR SCOR NON], lines[27]
      assert_equal "EPD", lines[30]
      assert_operator ScanSim::Code.encode(text, level: :m).version, :<=, 25
    end
  end

  def test_payloads_are_deterministic_utf8
    a = %i[url vcard epc utf8_text rksv ticket parcel].map { |m| ScanPayloads.public_send(m, Random.new(9)) }
    b = %i[url vcard epc utf8_text rksv ticket parcel].map { |m| ScanPayloads.public_send(m, Random.new(9)) }
    assert_equal a, b
    a.each { |t| assert t.valid_encoding? }
    assert_match(/[äöüéèçß]/, ScanPayloads.utf8_text(Random.new(1)) + ScanPayloads.vcard(Random.new(1)))
  end
end

class TestScanCorpusPlan < Minitest::Test
  def self.specs
    @specs ||= ScanCorpus.specs
  end

  def specs
    self.class.specs
  end

  def test_plan_size_and_determinism
    assert_equal ScanCorpus::PLAN.values.flatten.sum, specs.size
    assert_operator specs.size, :>=, 200
    assert_equal specs.map(&:id).uniq.size, specs.size
    letters = specs.select { |s| s.family == "letter" }
    again = ScanCorpus.specs(families: [:letter])
    assert_equal letters.map(&:id), again.map(&:id)
    assert_equal letters.map { |s| s.codes.map { |c| [c[:text], c[:center]] } },
                 again.map { |s| s.codes.map { |c| [c[:text], c[:center]] } }
  end

  def test_every_case_is_consistent
    specs.each do |s|
      scan = s.pages.first.scan
      bilevel = ScanSim::BILEVEL_MODES.include?(scan.mode)
      assert_equal bilevel, ScanSim::FORMATS.fetch(s.format)[2], "#{s.id}: #{s.format} with #{scan.mode}"
      assert s.pages.all? { |p| p.scan.dpi == scan.dpi && p.scan.mode == scan.mode }, s.id
      codes = s.codes
      refute_empty codes, s.id
      assert_equal codes.size, codes.map { |c| c[:text] }.uniq.size, "#{s.id}: duplicate payloads"
      codes.each do |c|
        w, h = s.pages[c[:page]].size
        half = c[:modules] * c[:module_px].max / 2.0
        assert_operator c[:center][0], :>, half * 0.5, "#{s.id}: code outside the image"
        assert_operator c[:center][1], :>, half * 0.5, "#{s.id}: code outside the image"
        assert_operator c[:center][0], :<, w - half * 0.5, "#{s.id}: code outside the image"
        assert_operator c[:center][1], :<, h - half * 0.5, "#{s.id}: code outside the image"
        assert_operator c[:version], :<=, 25, s.id if c[:kind] == "qrbill"
      end
      assert s.tags.any? { |t| t.start_with?("fmt:") } && s.tags.any? { |t| t.start_with?("ppm:") }, s.id
    end
  end

  def test_coverage_of_the_requirements
    tags = specs.flat_map(&:tags).tally
    %w[fmt:png-gray fmt:png-1bit fmt:jpeg-color fmt:jpeg-gray fmt:tiff-g4 fmt:tiff-g3 fmt:tiff-lzw
       fmt:pdf-dct fmt:pdf-g4 fmt:pdf-flate pages:multi dpi:150 dpi:200 dpi:300 dpi:600 dpi:fax-standard dpi:fax-fine
       mode:threshold mode:adaptive mode:ordered mode:diffusion mode:color mode:gray
       payload:url payload:vcard payload:qrbill payload:utf8 payload:numeric
       ec:l ec:m ec:q ec:h version:26-40 codes:3+
       deg:skew deg:rot90 deg:rot180 deg:rot270 deg:tint deg:shadow deg:blur deg:noise deg:jpeg deg:dotgain deg:thin
       deg:faded deg:speckles deg:photocopy deg:halftone deg:color-qr deg:color-bg deg:moire deg:curl deg:wave
       deg:crease deg:pen deg:stamp deg:edge deg:on-glass deg:dead-lines deg:inverted].each do |tag|
      assert tags.key?(tag), "no case tagged #{tag}"
    end
    tiers = specs.map(&:tier).tally
    assert_operator tiers["common"], :>, tiers["extreme"]
  end

  def test_common_cases_are_reasonable
    specs.select { |s| s.tier == "common" }.each do |s|
      ppm = s.codes.map { |c| c[:module_px].min }.min
      assert_operator ppm, :>=, 2.9, s.id
      assert_operator s.quality, :>=, 70, s.id if %w[jpeg-color jpeg-gray pdf-dct tiff-jpeg].include?(s.format)
    end
  end
end

class TestScanBench < Minitest::Test
  def kase(expected, codes: nil)
    codes ||= expected.each_with_index.map do |t, i|
      { "text" => t, "page" => 0, "center" => [100.0 + 200 * i, 100.0], "modules" => 25, "module_px" => [4.0, 4.0] }
    end
    ScanBench::Case.new(id: "x-common-01", file: "x.png", path: "x.png", tier: "common", family: "x",
                        tags: ["doc:x", "fmt:png-gray"], expected: expected, codes: codes, pixels: 4_000_000)
  end

  def test_scoring
    k = kase(%w[A B])
    assert_equal "pass", ScanBench.score(k, [["B", nil, nil], ["A", nil, nil]], 1.0).status
    partial = ScanBench.score(k, [["A", nil, nil]], 1.0)
    assert_equal ["partial", 1, 1], [partial.status, partial.found, partial.missed]
    assert_equal "fail", ScanBench.score(k, [], 1.0).status
    wrong = ScanBench.score(k, [["A", nil, nil], ["B", nil, nil], ["C", nil, nil]], 1.0)
    assert_equal ["pass", ["C"]], [wrong.status, wrong.wrong]
    # Duplicates of one text do not count for another expected copy.
    assert_equal "partial", ScanBench.score(kase(%w[A A]), [["A", nil, nil]], 1.0).status
  end

  def test_misplaced_results
    k = kase(%w[A B])
    good = ScanBench.score(k, [["A", nil, [102.0, 98.0]], ["B", 0, [300.0, 100.0]]], 1.0)
    assert_equal 0, good.misplaced
    bad = ScanBench.score(k, [["A", 1, [102.0, 98.0]], ["B", nil, [900.0, 100.0]]], 1.0)
    assert_equal 2, bad.misplaced
  end

  def test_outcome_round_trip_and_selection
    outcome = ScanBench.score(kase(%w[A]), [["A", nil, nil], ["Z", nil, nil]], 12.5)
    back = ScanBench::Outcome.from_h(JSON.parse(JSON.generate(outcome.to_h)))
    assert_equal [outcome.status, outcome.wrong, outcome.ms], [back.status, back.wrong, back.ms]
    cases = [kase(%w[A])]
    assert_equal 1, ScanBench.select(cases, ["fmt:png-*"]).size
    assert_equal 1, ScanBench.select(cases, ["common"]).size
    assert_empty ScanBench.select(cases, ["deg:crease"])
    assert_equal({ "doc" => [["doc:x", cases]], "fmt" => [["fmt:png-gray", cases]] }, ScanBench.tag_groups(cases))
  end

  def test_dry_run_on_a_tiny_corpus
    skip "ImageMagick not available" unless ScanSim.available?

    Dir.mktmpdir do |dir|
      spec = ScanCorpus.specs.find { |s| s.id == "receipt-common-03" } || ScanCorpus.specs.first
      ScanCorpus.render(spec, dir)
      File.write(File.join(dir, "manifest.json"), JSON.generate(ScanCorpus.manifest([spec], dir)))
      out = capture_io { ScanBench.run(["--dry-run", "--corpus", dir, "--json", File.join(dir, "r.json")]) }.first
      assert_match(/all\s+1\s+1\s+0\s+0\s+0\s+0\s+100\.0/, out)
      report = JSON.parse(File.read(File.join(dir, "r.json")))
      assert_equal 1, report.dig("summary", "pass")
      assert report.dig("cases", spec.id, "pass")
    end
  end
end
