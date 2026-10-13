# frozen_string_literal: true

# Detector timing benchmark (development tool).
#
#   bundle exec ruby [--yjit] test/detector/tools/bench_detect.rb IMAGE... [--runs N]
#
# For every image: hybrid binarization, the pure fast path, then the
# detector in normal and try_harder mode. "detect" consumes every candidate
# the way a reader would before decoding: geometry, #bits and, for
# candidates that pass the timing plausibility check, #alternatives.
# Reports the median of N runs (default 3) after one warm-up run.

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "qr_reader"
require "optparse"

runs = 3
OptionParser.new { |o| o.on("--runs N", Integer) { |v| runs = v } }.parse!

def clock
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def measure
  t = clock
  result = yield
  [result, (clock - t) * 1000]
end

def consume(detector, try_harder)
  count = 0
  detector.each_candidate(try_harder: try_harder) do |candidate|
    count += 1
    candidate.bits
    candidate.alternatives.each { |_| nil } if candidate.plausible?
  end
  count
end

def run(image)
  bits, t_bin = measure { QrReader::Binarizer.hybrid(image) }
  _, t_pure = measure { QrReader::Detector.detect_pure(bits) }
  detector = QrReader::Detector.new(bits, image: image)
  fast, t_fast = measure { consume(detector, false) }
  hard, t_hard = measure { consume(detector, true) }
  { bin: t_bin, pure: t_pure, fast: t_fast, hard: t_hard, candidates: [fast, hard] }
end

puts format("%-28s %9s %7s %8s %8s %8s  %s", "image", "size", "bin", "pure", "detect", "harder", "candidates")
ARGV.each do |path|
  image = QrReader.load_image(path)
  run(image)
  samples = Array.new(runs) { run(image) }
  med = ->(key) { samples.map { |s| s[key] }.sort[runs / 2] }
  puts format("%-28s %9s %7.1f %8.1f %8.1f %8.1f  %s", File.basename(path), "#{image.width}x#{image.height}",
              med.call(:bin), med.call(:pure), med.call(:fast), med.call(:hard), samples.first[:candidates].inspect)
end
puts "(ms, median of #{runs}; ruby #{RUBY_VERSION}#{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? ' +YJIT' : ''})"
