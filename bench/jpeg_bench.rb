# frozen_string_literal: true

# JPEG decoder benchmark.
#
#   ruby bench/jpeg_bench.rb            # interpreter
#   ruby --yjit bench/jpeg_bench.rb     # YJIT
#   ruby bench/jpeg_bench.rb -n 5 -f 1920   # 5 timed runs, only cases matching "1920"
#
# Test images are photos of a QR code (ZXing corpus qrcode-1/1.png) resized
# to typical camera sizes with sensor-like noise, encoded by ImageMagick
# (`magick`, development tool) and cached in $TMPDIR/qr_reader_jpeg_bench.
# "first" is the first decode in this process (includes YJIT compilation),
# "best"/"median" are over the timed runs that follow.

require "fileutils"
require "optparse"
require "tmpdir"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "qr_reader"
require "qr_reader/formats/jpeg"

options = { runs: 3, filter: nil }
OptionParser.new do |o|
  o.on("-n RUNS", Integer, "timed runs per case (default 3)") { |v| options[:runs] = v }
  o.on("-f FILTER", "only cases whose name includes FILTER") { |v| options[:filter] = v }
end.parse!

CACHE = File.join(Dir.tmpdir, "qr_reader_jpeg_bench")
SOURCE = File.expand_path("../test/corpus/zxing/qrcode-1/1.png", __dir__)
FileUtils.mkdir_p(CACHE)

# [name, size, ImageMagick encoding options, scales]
CASES = [
  ["640x480 baseline 4:2:0 q85", "640x480", %w[-sampling-factor 2x2], [1, 2]],
  ["640x480 progressive 4:2:0 q85", "640x480", %w[-sampling-factor 2x2 -interlace JPEG], [1]],
  ["1920x1080 baseline 4:2:0 q85", "1920x1080", %w[-sampling-factor 2x2], [1, 2, 4, 8]],
  ["1920x1080 baseline 4:4:4 q85", "1920x1080", %w[-sampling-factor 1x1], [1]],
  ["1920x1080 gray q85", "1920x1080", %w[-colorspace Gray], [1]],
  ["1920x1080 progressive 4:2:0 q85", "1920x1080", %w[-sampling-factor 2x2 -interlace JPEG], [1, 2, 4, 8]],
  ["4032x3024 baseline 4:2:0 q85", "4032x3024", %w[-sampling-factor 2x2], [1, 2, 4, 8]],
  ["4032x3024 progressive 4:2:0 q85", "4032x3024", %w[-sampling-factor 2x2 -interlace JPEG], [1, 2, 4, 8]]
].freeze

def image_file(name, size, opts)
  file = File.join(CACHE, "#{name.tr(' :', '__')}.jpg")
  return file if File.exist?(file)

  ok = system("magick", SOURCE, "-resize", "#{size}!", "-attenuate", "0.25", "+noise", "Gaussian",
              "-quality", "85", *opts, file)
  abort "could not create #{file} (is ImageMagick's `magick` installed?)" unless ok
  file
end

def ms
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
end

yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
puts "ruby #{RUBY_VERSION} #{yjit ? 'YJIT' : 'interpreter'}, #{options[:runs]} timed runs"
puts format("%-34s %5s %8s %9s %9s %9s", "case", "scale", "KiB", "first ms", "best ms", "median")
CASES.each do |name, size, opts, scales|
  next if options[:filter] && !name.include?(options[:filter])

  bytes = File.binread(image_file(name, size, opts))
  scales.each do |scale|
    first = ms { QrReader::Formats::JPEG.decode(bytes, scale: scale) }
    times = Array.new(options[:runs]) { ms { QrReader::Formats::JPEG.decode(bytes, scale: scale) } }.sort
    puts format("%-34s %5d %8d %9.1f %9.1f %9.1f", name, scale, bytes.bytesize / 1024, first, times.first,
                times[times.size / 2])
  end
end
