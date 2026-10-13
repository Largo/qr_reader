# frozen_string_literal: true

# Prints what the detector sees in an image (development tool).
#
#   bundle exec ruby test/detector/tools/inspect.rb IMAGE [--rotate DEG] [--global] [--invert] [--dump]
#
# Lists finder patterns, the candidates in order with their dimension
# estimates and Decoder.diagnose status for bits and each alternative.
# --dump prints the sampled grid of the first candidate.

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "qr_reader"
require "optparse"

opts = { rotate: 0, global: false, invert: false, dump: false, limit: 8 }
OptionParser.new do |o|
  o.on("--rotate DEG", Integer) { |v| opts[:rotate] = v }
  o.on("--global") { opts[:global] = true }
  o.on("--invert") { opts[:invert] = true }
  o.on("--dump") { opts[:dump] = true }
  o.on("--limit N", Integer) { |v| opts[:limit] = v }
end.parse!

path = ARGV.fetch(0) { abort "usage: inspect.rb IMAGE" }
# First page of TIFF / PDF files, any other image format directly.
bytes = File.binread(path)
image = case QrReader::Reader.container_format(bytes)
        when :tiff then QrReader::Formats::TIFF.decode(bytes)
        when :pdf then QrReader::Formats::PDF.images(bytes).first
        else QrReader.load_image(bytes)
        end
image = image.rotate(opts[:rotate])
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
bm = opts[:global] ? QrReader::Binarizer.global_histogram(image) : QrReader::Binarizer.hybrid(image)
bm = bm.invert if opts[:invert]
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts "#{image.width}x#{image.height} binarized in #{((t1 - t0) * 1000).round(1)} ms"

if (pure = QrReader::Detector.detect_pure(bm))
  puts "pure: dim=#{pure.dimension} #{QrReader::Decoder.diagnose(pure.bits)[:status]}"
end

detector = QrReader::Detector.new(bm, image: image)
%i[fast hard].each do |mode|
  fps = detector.finder_patterns(try_harder: mode == :hard)
  puts "#{mode}: #{fps.size} finder patterns"
  fps.each { |f| puts format("  (%.1f, %.1f) ms=%.2f hits=%d q=%.2f", f.x, f.y, f.module_size, f.count, f.quality) }
end

detector.each_candidate(try_harder: true).first(opts[:limit]).each_with_index do |c, i|
  puts c.inspect
  alignment = c.instance_variable_get(:@alignment)&.map { |v| v.round(1) }
  puts "  dims=#{c.dimensions.inspect} mode=#{c.mode} alignment=#{alignment.inspect} timing=#{c.timing_quality.round(2)}"
  puts "  points=#{c.points.map { |x, y| [x.round(1), y.round(1)] }.inspect}"
  puts "  bits: #{QrReader::Decoder.diagnose(c.bits).inspect[0, 200]}"
  c.alternatives.each_with_index do |alt, j|
    puts "  alt#{j} (#{alt.width}): #{QrReader::Decoder.diagnose(alt).inspect[0, 160]}"
  end
  puts c.bits.to_s(dark: "#", light: ".") if opts[:dump] && i.zero?
end
