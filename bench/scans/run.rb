# frozen_string_literal: true

# Scanned-document benchmark: runs QrReader.read_all on every case of the
# scan corpus (test/corpus/scans, made by bench/scans/generate.rb) and
# reports success per difficulty tier and per tag, wrong texts, and timings.
#
# A case passes when every expected text was decoded (order does not
# matter); "partial" when only some were; a decoded text that is not
# expected is a wrong text - a critical error, listed separately.
#
# Usage:
#   bundle exec ruby --yjit bench/scans/run.rb [options]      (proposed: rake scans:run)
#
# Options:
#   --only PATTERN    cases whose id, tier, family or a tag matches the glob, e.g.
#                     "qrbill-*", "hard", "fmt:pdf-*", "deg:crease" (repeatable: any matches)
#   --json OUT        write per-case results, summary and timings as JSON
#   --compare PREV    newly passing/failing cases and timing vs. an earlier --json run
#   --baseline [FILE] zxing-cpp's results next to ours (default bench/scans/baseline_zxcpp.json)
#   --reference       run zxing-cpp (bench/scans/zxcpp.py) instead of qr_reader; regenerate the
#                     baseline with: bundle exec ruby bench/scans/run.rb --reference --json bench/scans/baseline_zxcpp.json
#   --timeout SEC     time limit per case (default 120)
#   --jobs N          decode in N forked worker processes (faster; timings get noisier)
#   --no-try-harder   pass try_harder: false
#   --verbose         one line per case
#   --dry-run         check the manifest and the files, and run the scoring and report with
#                     an oracle that "decodes" the expected texts (no decoding)
#   --corpus DIR      corpus directory (default test/corpus/scans)

require_relative "../support"
require "optparse"
require "time"
require "timeout"
require "open3"
require "reference"

module ScanBench
  CORPUS = File.expand_path("../../test/corpus/scans", __dir__)
  DEFAULT_BASELINE = File.expand_path("baseline_zxcpp.json", __dir__)
  ZXCPP = File.expand_path("zxcpp.py", __dir__)
  TIERS = %w[common hard extreme].freeze
  STATUSES = %w[pass partial fail error timeout].freeze
  SIZE_BUCKETS = [[2, "< 2 Mpx"], [5, "2-5 Mpx"], [10, "5-10 Mpx"], [20, "10-20 Mpx"], [Float::INFINITY, "> 20 Mpx"]].freeze

  # One case of the manifest.
  Case = Data.define(:id, :file, :path, :tier, :family, :tags, :expected, :codes, :pixels) do
    def self.from(entry, dir)
      sizes = entry.fetch("image_size")
      new(id: entry.fetch("id"), file: entry.fetch("file"), path: File.join(dir, entry.fetch("file")),
          tier: entry.fetch("tier"), family: entry.fetch("family"), tags: entry.fetch("tags"),
          expected: entry.fetch("expected"), codes: entry.fetch("codes"), pixels: sizes.map { |w, h| w * h }.max)
    end

    def size_bucket
      SIZE_BUCKETS.find { |limit, _| pixels / 1e6 < limit }[1]
    end
  end

  # Result of one case. +texts+/+pages+/+centers+: what the decoder returned.
  Outcome = Data.define(:status, :found, :missed, :wrong, :misplaced, :ms, :texts, :error) do
    def pass?
      status == "pass"
    end

    def to_h
      { "status" => status, "pass" => pass?, "found" => found, "missed" => missed, "wrong" => wrong,
        "misplaced" => misplaced, "ms" => ms&.round(3), "texts" => texts.map { |t| BenchSupport.utf8(t) },
        "error" => error && BenchSupport.utf8(error) }.compact
    end

    def self.from_h(hash)
      new(status: hash["status"] || (hash["pass"] ? "pass" : "fail"), found: hash["found"] || 0,
          missed: hash["missed"] || 0, wrong: hash["wrong"] || [], misplaced: hash["misplaced"] || 0,
          ms: hash["ms"], texts: hash["texts"] || [], error: hash["error"])
    end
  end

  module_function

  def parse_options(argv)
    options = { only: [], timeout: 120.0, jobs: 1, try_harder: true, corpus: CORPUS }
    OptionParser.new do |o|
      o.banner = "Usage: bundle exec ruby --yjit bench/scans/run.rb [options]"
      o.on("--only PATTERN") { |v| options[:only] << v }
      o.on("--json OUT") { |v| options[:json] = v }
      o.on("--compare PREVIOUS") { |v| options[:compare] = v }
      o.on("--baseline [FILE]") { |v| options[:baseline] = v || DEFAULT_BASELINE }
      o.on("--reference") { options[:reference] = true }
      o.on("--timeout SEC", Float) { |v| options[:timeout] = v }
      o.on("--jobs N", Integer) { |v| options[:jobs] = [v, 1].max }
      o.on("--no-try-harder") { options[:try_harder] = false }
      o.on("--verbose") { options[:verbose] = true }
      o.on("--dry-run") { options[:dry_run] = true }
      o.on("--corpus DIR") { |v| options[:corpus] = File.expand_path(v) }
    end.parse!(argv)
    options
  end

  def load_manifest(dir)
    path = File.join(dir, "manifest.json")
    abort "#{path} missing: generate the corpus with `bundle exec ruby bench/scans/generate.rb`" unless File.exist?(path)
    manifest = BenchSupport.load_json(path)
    [manifest, manifest.fetch("cases").map { |entry| Case.from(entry, dir) }]
  end

  def select(cases, patterns)
    return cases if patterns.empty?

    cases.select do |c|
      patterns.any? { |pat| [c.id, c.tier, c.family, *c.tags].any? { |v| File.fnmatch?(pat, v) } }
    end
  end

  def run(argv)
    options = parse_options(argv)
    manifest, all = load_manifest(options[:corpus])
    cases = select(all, options[:only])
    abort "no cases match #{options[:only].join(', ')}" if cases.empty?

    missing = cases.reject { |c| File.exist?(c.path) }
    unless missing.empty?
      hint = missing.size < cases.size ? " --missing" : ""
      warn "#{missing.size} files missing (e.g. #{missing.first.file}): run bench/scans/generate.rb#{hint}"
      cases -= missing
      abort "nothing to run" if cases.empty?
    end

    decoder = if options[:dry_run] then "oracle (dry run)"
              elsif options[:reference] then QrReference.version
              else "qr_reader #{QrReader::VERSION}"
              end
    runtime = options[:reference] || options[:dry_run] ? nil : BenchSupport.runtime
    puts "Scan corpus: #{cases.size} cases (generator v#{manifest.dig('generator', 'version')}, " \
         "ImageMagick #{manifest.dig('generator', 'imagemagick')}) -- #{decoder}#{runtime ? ", #{runtime}" : ''}"
    started = BenchSupport.now
    outcomes = if options[:dry_run] then run_oracle(cases)
               elsif options[:reference] then run_reference(cases, options)
               else run_reader(cases, options)
               end
    wall = BenchSupport.now - started

    baseline = load_baseline(options[:baseline], manifest) if options[:baseline]
    report(cases, outcomes, baseline, wall, reference: options[:reference])
    json = to_json(cases, outcomes, manifest, decoder, runtime, wall, options)
    BenchSupport.write_json(options[:json], json) if options[:json]
    BenchSupport.compare_reports(options[:compare], json, "vs #{options[:compare]}") if options[:compare]
    if baseline
      BenchSupport.compare_reports(options[:baseline], json, "vs zxing-cpp baseline", baseline: true)
    end
    outcomes
  end

  # --- decoding --------------------------------------------------------------

  def run_reader(cases, options)
    return run_parallel(cases, options) if options[:jobs] > 1

    outcomes = {}
    cases.each do |kase|
      outcomes[kase.id] = decode_case(kase, options)
      log(kase, outcomes[kase.id]) if options[:verbose]
    rescue Interrupt
      warn "\ninterrupted -- reporting the cases done so far"
      break
    end
    outcomes
  end

  # Decodes one case with a time limit. Never raises.
  def decode_case(kase, options)
    results, ms = BenchSupport.measure do
      Timeout.timeout(options[:timeout]) { QrReader.read_all(kase.path, try_harder: options[:try_harder]) }
    end
    score(kase, results.map { |r| [r.text, r.page, center(r.points)] }, ms)
  rescue Timeout::Error
    Outcome.new(status: "timeout", found: 0, missed: kase.expected.size, wrong: [], misplaced: 0,
                ms: options[:timeout] * 1000, texts: [], error: "timeout after #{options[:timeout]} s")
  rescue *BenchSupport::CASE_ERRORS => e
    error = BenchSupport.missing_component?(e) ? "missing component: #{e.message}" : "#{e.class}: #{e.message}"
    Outcome.new(status: "error", found: 0, missed: kase.expected.size, wrong: [], misplaced: 0, ms: nil, texts: [],
                error: error[0, 300])
  end

  def center(points)
    return nil unless points && points.size == 4

    [points.sum { |p| p[0] } / 4.0, points.sum { |p| p[1] } / 4.0]
  end

  # Scores decoded [text, page, center] triples against the expected codes.
  def score(kase, decoded, ms)
    texts = decoded.map(&:first)
    remaining = kase.expected.dup
    found = 0
    texts.each do |t|
      i = remaining.index(t)
      next unless i

      remaining.delete_at(i)
      found += 1
    end
    wrong = texts.reject { |t| kase.expected.include?(t) }.uniq
    status = if remaining.empty? then "pass"
             elsif found.positive? then "partial"
             else "fail"
             end
    Outcome.new(status: status, found: found, missed: remaining.size, wrong: wrong,
                misplaced: misplaced(kase, decoded), ms: ms, texts: texts, error: nil)
  end

  # Correct texts reported far from where the code is (or on another page).
  def misplaced(kase, decoded)
    decoded.count do |text, page, at|
      next false unless at

      code = kase.codes.find { |c| c["text"] == text }
      next false unless code

      size = code["modules"] * code["module_px"].max
      (page || 0) != code["page"] || Math.hypot(at[0] - code["center"][0], at[1] - code["center"][1]) > [size / 2.0, 20].max
    end
  end

  # Forked workers pull case indices from a pipe and send back JSON lines.
  def run_parallel(cases, options)
    workers = Array.new([options[:jobs], cases.size].min) do
      to_child_r, to_child_w = IO.pipe
      from_child_r, from_child_w = IO.pipe
      pid = fork do
        to_child_w.close
        from_child_r.close
        while (line = to_child_r.gets)
          kase = cases[line.to_i]
          from_child_w.puts(JSON.generate([kase.id, decode_case(kase, options).to_h]))
          from_child_w.flush
        end
        exit!(0)
      end
      to_child_r.close
      from_child_w.close
      { pid: pid, input: to_child_w, output: from_child_r, busy: false }
    end
    queue = (0...cases.size).to_a
    outcomes = {}
    by_id = cases.to_h { |c| [c.id, c] }
    begin
      loop do
        workers.each do |w|
          next if w[:busy] || queue.empty?

          w[:case] = queue.shift
          w[:input].puts(w[:case])
          w[:input].flush
          w[:busy] = true
        end
        break if workers.none? { |w| w[:busy] }

        ready, = IO.select(workers.select { |w| w[:busy] }.map { |w| w[:output] })
        ready.each do |io|
          w = workers.find { |x| x[:output] == io }
          line = io.gets
          w[:busy] = false
          unless line
            kase = cases[w[:case]]
            warn "worker #{w[:pid]} died on #{kase.id}"
            outcomes[kase.id] = Outcome.new(status: "error", found: 0, missed: kase.expected.size, wrong: [],
                                            misplaced: 0, ms: nil, texts: [], error: "decoder process died")
            w[:dead] = true
            next
          end
          id, hash = JSON.parse(line)
          outcomes[id] = Outcome.from_h(hash)
          log(by_id[id], outcomes[id]) if options[:verbose]
        end
        workers.reject! { |w| w[:dead] }
        break if workers.empty?
      end
    rescue Interrupt
      warn "\ninterrupted -- reporting the cases done so far"
    ensure
      workers.each do |w|
        w[:input].close unless w[:input].closed?
        Process.kill("TERM", w[:pid]) rescue nil # rubocop:disable Style/RescueModifier
        Process.wait(w[:pid]) rescue nil # rubocop:disable Style/RescueModifier
      end
    end
    cases.each_with_object({}) { |c, h| h[c.id] = outcomes[c.id] if outcomes[c.id] }
  end

  # The decoder that knows the answers: exercises scoring and reporting.
  def run_oracle(cases)
    cases.to_h do |kase|
      decoded = kase.codes.map { |c| [c["text"], c["page"], c["center"]] }
      [kase.id, score(kase, decoded, 0.0)]
    end
  end

  # zxing-cpp through bench/scans/zxcpp.py (PDF pages via pdfimages).
  def run_reference(cases, options)
    abort "zxing-cpp venv not found (set QR_READER_PYTHON)" unless QrReference.available?

    input = cases.map { |c| JSON.generate({ "id" => c.id, "path" => c.path }) }.join("\n")
    out, err, status = Open3.capture3(QrReference.python, "-I", ZXCPP, stdin_data: "#{input}\n")
    abort "zxcpp.py failed: #{err}" unless status.success?

    by_id = cases.to_h { |c| [c.id, c] }
    outcomes = {}
    out.each_line do |line|
      row = JSON.parse(line)
      kase = by_id[row["id"]]
      next unless kase

      outcomes[kase.id] = if row["error"]
                            Outcome.new(status: "error", found: 0, missed: kase.expected.size, wrong: [], misplaced: 0,
                                        ms: nil, texts: [], error: "zxing-cpp: #{row['error']}")
                          else
                            score(kase, row["results"].map { |r| [r["text"], r["page"], center(r["corners"])] }, row["ms"])
                          end
      log(kase, outcomes[kase.id]) if options[:verbose]
    end
    cases.each_with_object({}) { |c, h| h[c.id] = outcomes[c.id] if outcomes[c.id] }
  end

  def log(kase, outcome)
    detail = outcome.error || ""
    detail = "missed #{outcome.missed}/#{kase.expected.size}" if detail.empty? && outcome.missed.positive?
    detail += "  WRONG [#{BenchSupport.preview(outcome.wrong)}]" unless outcome.wrong.empty?
    puts format("%-24s %-7s %-8s %9s  %s", kase.id, kase.tier, outcome.status, BenchSupport.ms(outcome.ms), detail)
  end

  # --- reporting -------------------------------------------------------------

  def load_baseline(path, manifest)
    return warn("#{path} not found (create it with --reference --json #{path})") unless File.exist?(path)

    data = BenchSupport.load_json(path)
    corpus = data.dig("meta", "corpus") || {}
    gen = manifest["generator"] || {}
    if corpus["version"] != gen["version"] || corpus["imagemagick"] != gen["imagemagick"]
      warn "note: baseline was made on corpus v#{corpus['version']} / ImageMagick #{corpus['imagemagick']}, " \
           "this corpus is v#{gen['version']} / ImageMagick #{gen['imagemagick']}"
    end
    data["cases"].transform_values { |h| Outcome.from_h(h) }
  end

  def report(cases, outcomes, baseline, wall, reference: false)
    done = cases.select { |c| outcomes.key?(c.id) }
    puts
    puts "By tier:"
    rows = TIERS.flat_map do |tier|
      group = done.select { |c| c.tier == tier }
      next [] if group.empty?

      row = [summary_row(tier, group, outcomes)]
      row << summary_row("  zxing-cpp", group, baseline, label_only: true) if baseline
      row
    end
    rows << summary_row("all", done, outcomes)
    rows << summary_row("  zxing-cpp", done, baseline, label_only: true) if baseline
    puts BenchSupport.table(summary_headers, rows)

    tag_groups(done).each do |group, tags|
      puts
      puts "By #{group}:"
      headers = ["tag", "cases", "pass", "%", "partial", "fail", "err", "wrong"]
      headers << "zxing-cpp %" if baseline
      table = tags.map do |tag, group_cases|
        row = tag_row(tag.sub(/\A#{Regexp.escape(group)}:/, ""), group_cases, outcomes)
        row << percent(group_cases.count { |c| baseline[c.id]&.pass? }, group_cases.count { |c| baseline.key?(c.id) }) if baseline
        row
      end
      puts BenchSupport.table(headers, table)
    end

    timing_report(done, outcomes, wall, reference)
    wrong_report(done, outcomes)
    failure_report(done, outcomes)
  end

  def summary_headers
    ["tier", "cases", "pass", "partial", "fail", "error", "timeout", "pass %", "codes found", "wrong texts"]
  end

  def summary_row(label, group, outcomes, label_only: false)
    present = group.select { |c| outcomes.key?(c.id) }
    counts = STATUSES.to_h { |s| [s, present.count { |c| outcomes[c.id].status == s }] }
    found = present.sum { |c| outcomes[c.id].found }
    codes = present.sum { |c| c.expected.size }
    wrong = present.sum { |c| outcomes[c.id].wrong.size }
    [label, label_only ? "" : group.size, counts["pass"], counts["partial"], counts["fail"], counts["error"],
     counts["timeout"], percent(counts["pass"], present.size), "#{found}/#{codes}", wrong.zero? ? "0" : "#{wrong} !!"]
  end

  def tag_row(label, group, outcomes)
    present = group.select { |c| outcomes.key?(c.id) }
    count = ->(status) { present.count { |c| outcomes[c.id].status == status } }
    wrong = present.sum { |c| outcomes[c.id].wrong.size }
    [label, present.size, count.call("pass"), percent(count.call("pass"), present.size), count.call("partial"),
     count.call("fail"), count.call("error") + count.call("timeout"), wrong.zero? ? "" : "#{wrong} !!"]
  end

  # {"doc" => {"doc:qrbill" => [cases]}, ...} in a fixed group order.
  def tag_groups(cases)
    order = %w[doc fmt dpi mode ppm size version ec payload codes pages scanner layout pdf deg]
    groups = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
    cases.each do |c|
      c.tags.each { |t| groups[t.split(":", 2).first][t] << c if t.include?(":") }
    end
    groups.sort_by { |g, _| [order.index(g) || order.size, g] }.to_h do |g, tags|
      [g, tags.sort_by { |t, _| sort_key(t.split(":", 2).last) }]
    end
  end

  # Numeric buckets ("<2", "2-3", "6+", "15-25mm", ">40mm") in numeric
  # order, everything else alphabetically after them.
  def sort_key(value)
    m = value.match(/\A([<>]?)(\d+(?:\.\d+)?)/)
    return [1, 0, value] unless m

    [0, m[2].to_f + { "<" => -0.5, ">" => 0.5 }.fetch(m[1], 0), value]
  end

  def percent(part, whole)
    whole.zero? ? "-" : format("%.1f", 100.0 * part / whole)
  end

  def timing_report(cases, outcomes, wall, reference)
    puts
    puts(if reference
           "Time per case (ms; zxing-cpp decode time, image loading excluded):"
         else
           "Time per case (ms; QrReader.read_all on the file, loading included):"
         end)
    headers = %w[group cases mean median p95 max]
    rows = TIERS.map { |t| timing_row(t, cases.select { |c| c.tier == t }, outcomes) }
    rows << timing_row("all", cases, outcomes)
    SIZE_BUCKETS.each do |_, label|
      group = cases.select { |c| c.size_bucket == label }
      rows << timing_row(label, group, outcomes) unless group.empty?
    end
    puts BenchSupport.table(headers, rows)
    puts format("wall time %.1f s", wall)
    slowest = cases.select { |c| outcomes[c.id].ms }.max_by(5) { |c| outcomes[c.id].ms }
    puts "slowest: #{slowest.map { |c| "#{c.id} #{BenchSupport.ms(outcomes[c.id].ms)}" }.join(', ')}" unless slowest.empty?
  end

  def timing_row(label, group, outcomes)
    s = BenchSupport.stats(group.filter_map { |c| outcomes[c.id]&.ms })
    [label, s[:n], *%i[mean median p95 max].map { |k| s[:n].zero? ? "-" : format("%.0f", s[k]) }]
  end

  def wrong_report(cases, outcomes)
    bad = cases.reject { |c| outcomes[c.id].wrong.empty? }
    puts
    if bad.empty?
      puts "No wrong texts."
      return
    end

    puts "WRONG TEXTS (critical) in #{bad.size} cases:"
    bad.each do |c|
      puts "  #{c.id}: got [#{BenchSupport.preview(outcomes[c.id].wrong, 80)}]"
      puts "    expected [#{BenchSupport.preview(c.expected, 80)}]"
    end
  end

  def failure_report(cases, outcomes)
    failed = cases.reject { |c| outcomes[c.id].pass? }
    misplaced = cases.sum { |c| outcomes[c.id].misplaced }
    puts "#{misplaced} decoded codes reported far from their true position or on the wrong page" if misplaced.positive?
    return if failed.empty?

    puts
    puts "Not passing (#{failed.size}):"
    failed.group_by(&:tier).each do |tier, group|
      puts "  #{tier}: " + group.map { |c| "#{c.id}#{outcomes[c.id].status == 'partial' ? '(partial)' : ''}" }.join(" ")
    end
    errors = failed.select { |c| outcomes[c.id].error }
    return if errors.empty?

    puts "Errors:"
    errors.group_by { |c| outcomes[c.id].error[0, 120] }.first(8).each do |message, group|
      puts "  #{group.size} x #{message}"
    end
  end

  def to_json(cases, outcomes, manifest, decoder, runtime, wall, options)
    done = cases.select { |c| outcomes.key?(c.id) }
    times = done.filter_map { |c| outcomes[c.id].ms }
    stat = ->(values) { BenchSupport.stats(values).transform_keys(&:to_s).transform_values { |v| v.is_a?(Float) ? v.round(3) : v } }
    by = lambda do |groups|
      groups.transform_values do |group|
        { "cases" => group.size, "pass" => group.count { |c| outcomes[c.id].pass? },
          "partial" => group.count { |c| outcomes[c.id].status == "partial" },
          "wrong" => group.sum { |c| outcomes[c.id].wrong.size } }
      end
    end
    {
      "meta" => {
        "decoder" => decoder, "runtime" => runtime, "try_harder" => options[:reference] ? nil : options[:try_harder],
        "created" => Time.now.utc.iso8601, "only" => options[:only],
        "corpus" => (manifest["generator"] || {}).slice("version", "seed", "imagemagick")
      }.compact,
      "summary" => {
        "cases" => done.size, "pass" => done.count { |c| outcomes[c.id].pass? },
        "statuses" => STATUSES.to_h { |s| [s, done.count { |c| outcomes[c.id].status == s }] },
        "codes" => done.sum { |c| c.expected.size }, "found" => done.sum { |c| outcomes[c.id].found },
        "wrong" => done.sum { |c| outcomes[c.id].wrong.size },
        "by_tier" => by.call(done.group_by(&:tier)),
        "by_tag" => by.call(done.each_with_object(Hash.new { |h, k| h[k] = [] }) { |c, h| c.tags.each { |t| h[t] << c } }),
        "ms" => stat.call(times),
        "ms_by_tier" => done.group_by(&:tier).transform_values { |g| stat.call(g.filter_map { |c| outcomes[c.id].ms }) },
        "wall_s" => wall.round(3)
      },
      "cases" => done.to_h { |c| [c.id, outcomes[c.id].to_h.merge("tier" => c.tier)] }
    }
  end
end

ScanBench.run(ARGV) if $PROGRAM_NAME == __FILE__
