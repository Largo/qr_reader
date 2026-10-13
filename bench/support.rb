# frozen_string_literal: true

# Shared helpers for the bench/ scripts: load paths, timing, statistics,
# result tables, JSON reports and run-to-run comparisons.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../test/support", __dir__)

require "json"
require "optparse"
require "zlib"
require "qr_reader"

$stdout.sync = true

module BenchSupport
  # Exceptions a component under construction may raise; recorded per case
  # instead of aborting the whole run.
  CASE_ERRORS = [StandardError, ScriptError, SystemStackError].freeze

  # Gray byte => the same value as an RGB triple (String#gsub with a Hash
  # expands a whole row at C speed).
  GRAY_TO_RGB = (0..255).to_h { |v| [v.chr.b, (v.chr * 3).b] }.freeze

  module_function

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Runs the block and returns [result, elapsed milliseconds].
  def measure
    start = now
    result = yield
    [result, (now - start) * 1000.0]
  end

  def yjit?
    defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? true : false
  end

  def runtime
    "ruby #{RUBY_VERSION}#{yjit? ? ' +YJIT' : ''}"
  end

  # Summary statistics of a list of millisecond timings.
  def stats(values)
    return { n: 0, total: 0.0, mean: 0.0, median: 0.0, p95: 0.0, max: 0.0 } if values.empty?

    sorted = values.sort
    {
      n: sorted.size, total: sorted.sum, mean: sorted.sum / sorted.size,
      median: percentile(sorted, 50), p95: percentile(sorted, 95), max: sorted.last
    }
  end

  # Nearest-rank percentile of a sorted Array.
  def percentile(sorted, pct)
    sorted[[(pct / 100.0 * sorted.size).ceil - 1, 0].max]
  end

  def ms(value)
    return "-" if value.nil?

    value >= 100 ? format("%.0f ms", value) : format("%.1f ms", value)
  end

  def time_line(label, values)
    s = stats(values)
    format("%s total %.2f s; per image mean %s, median %s, p95 %s, max %s",
           label, s[:total] / 1000.0, ms(s[:mean]), ms(s[:median]), ms(s[:p95]), ms(s[:max]))
  end

  # Left-aligned first column, right-aligned other columns.
  def table(headers, rows)
    all = [headers] + rows
    widths = headers.each_index.map { |i| all.map { |r| r[i].to_s.size }.max }
    all.map do |row|
      row.each_with_index.map { |cell, i| i.zero? ? cell.to_s.ljust(widths[i]) : cell.to_s.rjust(widths[i]) }.join("  ")
    end.join("\n")
  end

  def write_json(path, data)
    File.write(path, JSON.pretty_generate(data))
    warn "wrote #{path}"
  end

  def load_json(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT, JSON::ParserError => e
    abort "cannot read #{path}: #{e.message}"
  end

  # Parses +argv+ with +parser+; bad options print the usage and exit 2
  # instead of a stack trace.
  def parse!(parser, argv)
    parser.parse!(argv)
  rescue OptionParser::ParseError => e
    warn "#{e.message}\n\n#{parser.help}"
    exit 2
  end

  # Exit status 1 (for CI) when fewer than +min_pass+ cases passed or more
  # than +max_wrong+ results were misreads; nil limits are not checked.
  def check_limits(passed, min_pass: nil, wrong: 0, max_wrong: nil)
    failures = []
    failures << "#{passed} cases passed, expected at least #{min_pass}" if min_pass && passed < min_pass
    failures << "#{wrong} misreads, at most #{max_wrong} allowed" if max_wrong && wrong > max_wrong
    return if failures.empty?

    warn "FAILED: #{failures.join('; ')}"
    exit 1
  end

  # Compares two {id => {"pass" => bool, ...}} maps over their common ids.
  def compare(previous, current)
    common = previous.keys & current.keys
    {
      newly_passing: common.select { |id| current[id]["pass"] && !previous[id]["pass"] },
      newly_failing: common.select { |id| previous[id]["pass"] && !current[id]["pass"] },
      common: common.size,
      previous_passed: common.count { |id| previous[id]["pass"] },
      current_passed: common.count { |id| current[id]["pass"] }
    }
  end

  # Prints the pass/fail changes and the decode time change between an
  # earlier JSON report at +path+ and the +current+ report Hash.
  def compare_reports(path, current, title, baseline: false)
    return warn("#{path} not found") unless File.exist?(path)

    previous = load_json(path)
    abort "#{path} is not a corpus/synthetic report (no \"cases\")" unless previous["cases"].is_a?(Hash)

    diff = compare(previous["cases"], current["cases"])
    labels = baseline ? { current_label: "qr_reader", previous_label: "zxing-cpp" } : {}
    print_comparison(title, diff, **labels)
    # Mean decode time over the cases timed in both runs.
    timed = previous["cases"].keys.select { |id| previous["cases"][id]["ms"] && current["cases"].dig(id, "ms") }
    return if timed.empty?

    before = timed.sum { |id| previous["cases"][id]["ms"] } / timed.size
    after = timed.sum { |id| current["cases"][id]["ms"] } / timed.size
    puts format("  mean decode time over %d cases: %s -> %s (%s)%s", timed.size, ms(before), ms(after), speed_change(before, after),
                baseline ? " [#{previous.dig('meta', 'decoder')} -> #{current.dig('meta', 'decoder')}]" : "")
  end

  # "2.5x faster" / "3.0x slower" going from +before+ to +after+ ms.
  def speed_change(before, after)
    return "-" unless before.positive? && after.positive?

    after <= before ? format("%.1fx faster", before / after) : format("%.1fx slower", after / before)
  end

  def print_comparison(title, diff, current_label: "now", previous_label: "before", limit: 60)
    puts
    puts "#{title}: #{diff[:previous_passed]} -> #{diff[:current_passed]} of #{diff[:common]} common cases " \
         "(+#{diff[:newly_passing].size} / -#{diff[:newly_failing].size})"
    print_ids("  passing #{current_label}, failing #{previous_label}", diff[:newly_passing], limit)
    print_ids("  failing #{current_label}, passing #{previous_label}", diff[:newly_failing], limit)
  end

  def print_ids(label, ids, limit)
    return if ids.empty?

    puts "#{label} (#{ids.size}):"
    ids.first(limit).each_slice(4) { |slice| puts "    " + slice.map { |id| id.ljust(26) }.join }
    puts "    ... #{ids.size - limit} more" if ids.size > limit
  end

  # +text+ as valid UTF-8 for JSON reports: other encodings are transcoded,
  # invalid bytes replaced (JSON.generate raises on invalid UTF-8, which
  # would lose a whole run's report at the very end).
  def utf8(text)
    s = text.to_s
    if s.encoding != Encoding::UTF_8 && s.encoding != Encoding::BINARY && s.valid_encoding?
      begin
        return s.encode(Encoding::UTF_8)
      rescue EncodingError
        nil
      end
    end
    s.dup.force_encoding(Encoding::UTF_8).scrub
  end

  # True when +error+ only says that a component (or one of its methods) is
  # not there yet: NotImplementedError, or a NameError / NoMethodError on a
  # QrReader module. Any other NoMethodError (e.g. on nil) is a real bug.
  def missing_component?(error)
    return true if error.is_a?(NotImplementedError)
    return false unless error.is_a?(NameError)

    receiver = begin
      error.receiver
    rescue ArgumentError
      nil
    end
    receiver.is_a?(Module) && receiver.name.to_s.start_with?("QrReader")
  end

  # Short single-line rendering of decoded texts for logs.
  def preview(texts, width = 60)
    texts.map do |t|
      s = t.to_s.dup.force_encoding(Encoding::UTF_8).scrub.dump
      s.size > width ? "#{s[0, width - 3]}..." : s
    end.join(", ")
  end

  # Grayscale (or RGB with rgb: true) PNG bytes of a QrReader::Image, for
  # writing benchmark inputs and failures to disk.
  def png_bytes(image, rgb: false)
    raw = String.new(capacity: image.size * (rgb ? 3 : 1) + image.height, encoding: Encoding::BINARY)
    image.height.times do |y|
      row = image.row(y)
      raw << "\0" << (rgb ? row.gsub(/./mn, GRAY_TO_RGB) : row)
    end
    chunk = lambda do |type, body|
      [body.bytesize].pack("N") + type + body + [Zlib.crc32(type + body)].pack("N")
    end
    "\x89PNG\r\n\x1a\n".b +
      chunk.call("IHDR", [image.width, image.height, 8, rgb ? 2 : 0, 0, 0, 0].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(raw)) +
      chunk.call("IEND", "".b)
  end
end
