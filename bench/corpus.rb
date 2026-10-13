# frozen_string_literal: true

# ZXing blackbox corpus benchmark: decodes test/corpus/zxing/qrcode-*/*.png
# at several rotations and counts a case as passed when any decoded result's
# text equals the expected .txt content exactly (like ZXing's own tests).
#
# Usage:
#   bundle exec ruby [--yjit] bench/corpus.rb [options]
#
# Options:
#   --rotations 0,90,180,270  rotations to test (clockwise, QrReader::Image#rotate); default all four
#   --only DIR[,DIR...]       restrict to directories ("qrcode-3" or "3") or images ("qrcode-3/12.png");
#                             may be repeated
#   --json OUT                write per-case results, summary and timings as JSON
#   --compare PREVIOUS.json   list cases that newly pass / newly fail relative to an earlier --json run
#   --baseline [FILE]         compare with the zxing-cpp baseline (default bench/baselines/zxcpp.json)
#   --verbose                 print every case with its time and result
#   --no-try-harder           pass try_harder: false to QrReader.read_all
#   --reference               run zxing-cpp (bench/reference/zxcpp.py, TextMode Plain) instead of
#                             qr_reader; regenerate the baseline with
#                             bundle exec ruby bench/corpus.rb --reference --json bench/baselines/zxcpp.json
#
# Images are loaded with QrReader::Formats.decode and rotated before timing;
# the reported decode time is QrReader.read_all on the in-memory image.

require_relative "support"
require "optparse"
require "time"
require "corpus"
require "reference"

module CorpusBench
  DEFAULT_BASELINE = File.expand_path("baselines/zxcpp.json", __dir__)
  ALL_ROTATIONS = [0, 90, 180, 270].freeze

  Outcome = Data.define(:pass, :ms, :texts, :error)

  module_function

  def parse_options(argv)
    options = { rotations: ALL_ROTATIONS, only: [], try_harder: true }
    OptionParser.new do |o|
      o.banner = "Usage: bundle exec ruby [--yjit] bench/corpus.rb [options]"
      o.on("--rotations LIST", "comma-separated, e.g. 0,90") do |v|
        options[:rotations] = v.split(",").map { |r| Integer(r.strip, 10) % 360 }.uniq
        abort "rotations must be multiples of 90" unless options[:rotations].all? { |r| (r % 90).zero? }
      rescue ArgumentError
        abort "invalid --rotations #{v.inspect}: expected e.g. 0,90,180,270"
      end
      o.on("--only LIST", "directories or images") { |v| options[:only] << v }
      o.on("--json OUT") { |v| options[:json] = v }
      o.on("--compare PREVIOUS") { |v| options[:compare] = v }
      o.on("--baseline [FILE]") { |v| options[:baseline] = v || DEFAULT_BASELINE }
      o.on("--verbose") { options[:verbose] = true }
      o.on("--no-try-harder") { options[:try_harder] = false }
      o.on("--reference") { options[:reference] = true }
    end.parse!(argv)
    options
  end

  def run(argv)
    options = parse_options(argv)
    abort "corpus missing: run `bundle exec rake corpus:fetch`" unless QrCorpus.available?

    cases = QrCorpus.cases(only: options[:only])
    abort "no corpus images match #{options[:only].join(',')}" if cases.empty?

    decoder = options[:reference] ? QrReference.version : "qr_reader #{QrReader::VERSION}"
    puts "ZXing QR corpus: #{cases.size} images x rotations #{options[:rotations].join('/')} -- " \
         "#{decoder}#{options[:reference] ? '' : ", #{BenchSupport.runtime}"}"
    started = BenchSupport.now
    outcomes, load_times = options[:reference] ? run_reference(cases, options) : run_qr_reader(cases, options)
    wall = BenchSupport.now - started

    report(cases, outcomes, load_times, wall, options)
    json = to_json(cases, outcomes, load_times, wall, options, decoder)
    BenchSupport.write_json(options[:json], json) if options[:json]
    BenchSupport.compare_reports(options[:compare], json, "vs #{options[:compare]}") if options[:compare]
    BenchSupport.compare_reports(options[:baseline], json, "vs zxing-cpp baseline", baseline: true) if options[:baseline]
  end

  def case_id(kase, rotation)
    "#{kase.id}@#{rotation}"
  end

  # Decodes every case with qr_reader. Returns [{id => Outcome}, [load ms]].
  def run_qr_reader(cases, options)
    outcomes = {}
    load_times = []
    decode_options = { try_harder: options[:try_harder] }
    cases.each do |kase|
      image, error = load_image(kase, load_times)
      options[:rotations].each do |rotation|
        id = case_id(kase, rotation)
        outcomes[id] = if image
                         decode_case(image, rotation, kase.expected, decode_options)
                       else
                         Outcome.new(pass: false, ms: nil, texts: [], error: error)
                       end
        log(id, outcomes[id]) if options[:verbose]
      end
    rescue Interrupt
      warn "\ninterrupted -- reporting the cases done so far"
      break
    end
    [outcomes, load_times]
  end

  def load_image(kase, load_times)
    bytes = File.binread(kase.path)
    image, elapsed = BenchSupport.measure { QrReader::Formats.decode(bytes) }
    load_times << elapsed
    [image, nil]
  rescue *BenchSupport::CASE_ERRORS => e
    [nil, "load: #{e.class}: #{e.message}"]
  end

  def decode_case(image, rotation, expected, decode_options)
    rotated = image.rotate(rotation)
    results, elapsed = BenchSupport.measure { QrReader.read_all(rotated, **decode_options) }
    texts = results.map(&:text)
    Outcome.new(pass: texts.include?(expected), ms: elapsed, texts: texts, error: nil)
  rescue *BenchSupport::CASE_ERRORS => e
    Outcome.new(pass: false, ms: nil, texts: [], error: "#{e.class}: #{e.message}")
  end

  # Decodes every case with zxing-cpp (one Python process per rotation).
  def run_reference(cases, options)
    abort "zxing-cpp venv not found (set QR_READER_PYTHON)" unless QrReference.available?

    outcomes = {}
    options[:rotations].each do |rotation|
      results = QrReference.decode(cases.map(&:path), rotate_cw: rotation, text_mode: "Plain")
      cases.zip(results).each do |kase, result|
        texts = result["results"].map { |r| r["text"] }
        id = case_id(kase, rotation)
        outcomes[id] = Outcome.new(pass: texts.include?(kase.expected), ms: result["ms"], texts: texts,
                                   error: result["error"] && "zxing-cpp: #{result['error']}")
        log(id, outcomes[id]) if options[:verbose]
      end
    end
    [outcomes, []]
  end

  def log(id, outcome)
    status = if outcome.error then "ERROR"
             elsif outcome.pass then "pass"
             else "FAIL"
             end
    detail = outcome.error || (outcome.pass ? "" : "got [#{BenchSupport.preview(outcome.texts)}]")
    puts format("%-24s %-5s %9s  %s", id, status, BenchSupport.ms(outcome.ms), detail)
  end

  def report(cases, outcomes, load_times, wall, options)
    rotations = options[:rotations]
    baseline = options[:baseline] && File.exist?(options[:baseline]) ? BenchSupport.load_json(options[:baseline])["cases"] : nil
    headers = ["dir", "images"] + rotations.map { |r| "#{r}°" } + ["total"]
    rows = []
    cases.group_by(&:dir).each do |dir, dir_cases|
      rows << summary_row(dir, dir_cases, rotations, outcomes)
      rows << summary_row("  zxing-cpp", dir_cases, rotations, baseline) if baseline
    end
    rows << summary_row("total", cases, rotations, outcomes)
    rows << summary_row("  zxing-cpp", cases, rotations, baseline) if baseline
    puts
    puts BenchSupport.table(headers, rows)
    puts

    times = outcomes.values.filter_map(&:ms)
    puts BenchSupport.time_line("decode:", times)
    puts BenchSupport.time_line("load:  ", load_times) unless load_times.empty?
    puts format("wall time %.2f s", wall)
    slowest = outcomes.select { |_, o| o.ms }.max_by(5) { |_, o| o.ms }
    puts "slowest: " + slowest.map { |id, o| "#{id} #{BenchSupport.ms(o.ms)}" }.join(", ") unless slowest.empty?

    errors = outcomes.select { |_, o| o.error }
    return if errors.empty?

    puts
    puts "#{errors.size} cases raised errors:"
    errors.group_by { |_, o| o.error }.first(5).each do |message, group|
      puts "  #{group.size} x #{message[0, 200]}"
    end
  end

  def summary_row(label, cases, rotations, outcomes)
    per_rotation = rotations.map do |r|
      ids = cases.map { |c| case_id(c, r) }
      passed = ids.count { |id| outcome_pass?(outcomes[id]) }
      [passed, ids.count { |id| outcomes.key?(id) }]
    end
    passed = per_rotation.sum(&:first)
    total = per_rotation.sum(&:last)
    [label, label.start_with?(" ") ? "" : cases.size] +
      per_rotation.map { |p, t| "#{p}/#{t}" } + ["#{passed}/#{total} #{percent(passed, total)}"]
  end

  def outcome_pass?(outcome)
    case outcome
    when Outcome then outcome.pass
    when Hash then outcome["pass"]
    else false
    end
  end

  def percent(part, whole)
    whole.zero? ? "" : format("(%.1f%%)", 100.0 * part / whole)
  end

  def to_json(cases, outcomes, load_times, wall, options, decoder)
    by_dir = cases.group_by(&:dir).transform_values do |dir_cases|
      options[:rotations].to_h do |r|
        ids = dir_cases.map { |c| case_id(c, r) }
        [r.to_s, [ids.count { |id| outcomes[id]&.pass }, ids.count { |id| outcomes.key?(id) }]]
      end
    end
    times = outcomes.values.filter_map(&:ms)
    {
      "meta" => {
        "decoder" => decoder, "runtime" => options[:reference] ? nil : BenchSupport.runtime,
        "rotations" => options[:rotations], "try_harder" => options[:reference] ? nil : options[:try_harder],
        "text_mode" => options[:reference] ? "Plain" : nil, "created" => Time.now.utc.iso8601
      }.compact,
      "summary" => {
        "passed" => outcomes.count { |_, o| o.pass }, "total" => outcomes.size, "by_dir" => by_dir,
        "decode_ms" => BenchSupport.stats(times).transform_keys(&:to_s).transform_values { |v| v.is_a?(Float) ? v.round(3) : v },
        "load_ms_total" => load_times.sum.round(3), "wall_s" => wall.round(3),
        "errors" => outcomes.count { |_, o| o.error }
      },
      "cases" => outcomes.to_h do |id, o|
        [id, { "pass" => o.pass, "ms" => o.ms&.round(3), "texts" => o.texts.map { |t| BenchSupport.utf8(t) },
               "error" => o.error && BenchSupport.utf8(o.error) }.compact]
      end
    }
  end
end

CorpusBench.run(ARGV) if $PROGRAM_NAME == __FILE__
