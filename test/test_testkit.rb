# frozen_string_literal: true

require_relative "test_helper"
require "corpus"
require_relative "../bench/support"
require_relative "../bench/synthetic"

# Self-tests for the corpus helper and the benchmark infrastructure.
class TestTestkit < Minitest::Test
  BASELINES = File.expand_path("../bench/baselines", __dir__)

  def test_corpus_cases
    skip "corpus not fetched" unless QrCorpus.available?

    cases = QrCorpus.cases
    assert_equal 179, cases.size
    assert_equal %w[qrcode-1 qrcode-2 qrcode-3 qrcode-4 qrcode-5 qrcode-6], QrCorpus.directories
    assert_equal %w[1.png 2.png 3.png], cases.first(3).map(&:name)
    first = cases.first
    assert_equal "qrcode-1/1.png", first.id
    assert_equal Encoding::UTF_8, first.expected.encoding
    assert first.expected.valid_encoding?
    assert_equal "]Q1", first.metadata["SYMBOLOGY_IDENTIFIER"]
    assert_equal({}, cases[1].metadata)
  end

  def test_corpus_filters
    skip "corpus not fetched" unless QrCorpus.available?

    assert_equal 20, QrCorpus.cases(only: "qrcode-1").size
    assert_equal 20, QrCorpus.cases(only: "1").size
    assert_equal 39, QrCorpus.cases(only: ["1", "qrcode-5"]).size
    assert_equal 39, QrCorpus.cases(only: "1,5").size
    assert_equal ["qrcode-2/4.png"], QrCorpus.cases(only: "qrcode-2/4.png").map(&:id)
    assert_equal ["qrcode-2/4.png"], QrCorpus.cases(only: "qrcode-2/4").map(&:id)
    assert_equal 48, QrCorpus.cases(only: "qrcode-4/*").size
    assert_empty QrCorpus.cases(only: "nothing")
    assert_empty QrCorpus.cases(root: "/nonexistent")
  end

  def test_stats_and_compare
    s = BenchSupport.stats([5.0, 1.0, 3.0, 2.0, 4.0])
    assert_equal({ n: 5, total: 15.0, mean: 3.0, median: 3.0, p95: 5.0, max: 5.0 }, s)
    assert_equal 0, BenchSupport.stats([])[:n]
    previous = { "a" => { "pass" => true }, "b" => { "pass" => false }, "c" => { "pass" => true } }
    current = { "a" => { "pass" => false }, "b" => { "pass" => true }, "d" => { "pass" => true } }
    diff = BenchSupport.compare(previous, current)
    assert_equal ["b"], diff[:newly_passing]
    assert_equal ["a"], diff[:newly_failing]
    assert_equal 2, diff[:common]
  end

  def test_png_writer_matches_qr_test_helper
    image = QrTestEncoder.build("png", version: 1).to_image(module_size: 2)
    assert_equal QrTestHelper.png_bytes(image), BenchSupport.png_bytes(image)
    rgb = BenchSupport.png_bytes(image, rgb: true)
    assert_equal 2, rgb.getbyte(25) # colour type
  end

  def test_synthetic_grid_is_deterministic
    ids = SyntheticBench.all_cases.map(&:id)
    assert_equal ids.uniq, ids
    picks = SyntheticBench.all_cases.select { |c| %w[clean modes noise ec_overload multi].include?(c.family) && c.quick }
    first, = SyntheticBench.generate(picks)
    second, = SyntheticBench.generate(picks)
    picks.each do |c|
      a = first[c.id]
      b = second[c.id]
      assert_equal a.expected, b.expected, c.id
      assert_equal (a.input.is_a?(QrReader::Image) ? a.input.data : a.input), (b.input.is_a?(QrReader::Image) ? b.input.data : b.input), c.id
      refute_empty a.expected, c.id
    end
  end

  def test_synthetic_classification
    sample = SyntheticBench::Sample.new(input: nil, expected: ["a", %w[b b2]])
    assert_equal :pass, SyntheticBench.classify(sample, %w[a b2], 1.0).status
    assert_equal :partial, SyntheticBench.classify(sample, ["a"], 1.0).status
    assert_equal :fail, SyntheticBench.classify(sample, [], 1.0).status
    assert_equal :wrong, SyntheticBench.classify(sample, %w[a b x], 1.0).status
    overload = SyntheticBench::Sample.new(input: nil, expected: ["a"], overload: true)
    assert_equal :pass, SyntheticBench.classify(overload, [], 1.0).status
    assert_equal :wrong, SyntheticBench.classify(overload, ["garbage"], 1.0).status
  end

  # The committed zxing-cpp baselines must cover the current case sets;
  # regenerate them (see the script headers) after changing the grid.
  def test_baselines_cover_all_cases
    corpus = JSON.parse(File.read(File.join(BASELINES, "zxcpp.json")))["cases"]
    if QrCorpus.available?
      expected = QrCorpus.cases.flat_map { |c| [0, 90, 180, 270].map { |r| "#{c.id}@#{r}" } }
      assert_equal expected.sort, corpus.keys.sort
    end
    synthetic = JSON.parse(File.read(File.join(BASELINES, "synthetic_zxcpp.json")))["cases"]
    # The baseline always lists the JPEG cases; without ImageMagick they are
    # not generated, so compare the remaining ones.
    ids = SyntheticBench.all_cases.map(&:id)
    jpeg_ids = Distort.jpeg_available? ? [] : SyntheticBench.all_cases.select { |c| c.family == "jpeg" }.map(&:id)
    assert_equal (ids - jpeg_ids).sort, (synthetic.keys - jpeg_ids).sort
  end
end
