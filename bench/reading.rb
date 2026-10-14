# frozen_string_literal: true

# How long does one reading take, and how much memory does it need?
#
# Usage:
#   bundle exec ruby bench/reading.rb [--runs N] [--only NAME,...] [--no-interpreter] [--json OUT]
#
# Generates realistic inputs once into bench/inputs/ (ImageMagick `magick` is
# needed for that step only), then measures every input in a fresh Ruby
# process, with YJIT and with the plain interpreter:
#
#   first   - latency of the first QrReader.read in the process (includes YJIT
#             compilation / warm-up; what a CLI call or a cold worker sees)
#   warm    - median latency of N further reads in the same process
#   peak    - peak resident memory added by the first read (VmHWM after the
#             read minus VmRSS before it; Linux only, peak counter reset via
#             /proc/self/clear_refs)
#   allocs  - Ruby objects allocated by one read
#
# The library's own footprint (RSS after `require "qr_reader"`) is printed
# first. Inputs whose format is not supported yet are skipped.

require "stringio"
require "json"
require "optparse"
require "open3"
require "rbconfig"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
INPUTS = File.join(ROOT, "bench", "inputs")

options = { runs: 5, only: nil, interpreter: true, json: nil }
CHILD = ARGV.first == "--child"
CHILD || OptionParser.new do |o|
  o.on("--runs N", Integer, "warm reads per input (default 5)") { |v| options[:runs] = v }
  o.on("--only NAMES", "comma-separated input names") { |v| options[:only] = v.split(",") }
  o.on("--no-interpreter", "only measure with YJIT") { options[:interpreter] = false }
  o.on("--json OUT", "write results as JSON") { |v| options[:json] = v }
end.parse!

# ---------------------------------------------------------------------------
# Input generation (dev-time only: rqrcode_core + ImageMagick)

module Inputs
  module_function

  SWISS_QR_BILL = [
    "SPC", "0200", "1", "CH4431999123000889012", "S", "Robert Schneider AG", "Rue du Lac", "1268",
    "2501", "Biel", "CH", "", "", "", "", "", "", "", "1949.75", "CHF", "S", "Pia-Maria Rutschmann-Schnyder",
    "Grosse Marktgasse", "28", "9400", "Rorschach", "CH", "QRR", "210000000003139471430009017",
    "Bestellung vom 15.10.2020", "EPD"
  ].join("\n")

  def magick(*args)
    out, status = Open3.capture2e("magick", *args.map(&:to_s))
    raise "magick #{args.join(' ')} failed:\n#{out}" unless status.success?
  end

  # QR code as a PNG with +px+ pixels per module and a 4-module quiet zone.
  def qr_png(path, text, px, level: :m)
    require_relative "../test/support/qr_test_helper"
    matrix = QrTestHelper.rqr_matrix(text, level: level)
    QrTestHelper.write_png(QrTestHelper.render(matrix, module_size: px, quiet: 4), path)
    matrix.width
  end

  # Lines of text-like clutter for a document page, as ImageMagick draw args.
  def text_lines(width, top, bottom, line_height, seed)
    rng = Random.new(seed)
    words = %w[Rechnung Datum Betrag Total MwSt Leistung Kunde Nummer Zahlbar innert Tagen netto Konto
               Position Menge Preis Lieferung Bemerkungen Referenz Invoice Amount Payment Account Thank you]
    args = []
    y = top
    while y < bottom
      line = Array.new(rng.rand(4..11)) { words.sample(random: rng) }.join(" ")
      args += ["-annotate", "+#{(width * 0.08).round}+#{y}", line]
      y += line_height
    end
    args
  end

  def generate(dir)
    FileUtils.mkdir_p(dir)
    tmp = File.join(dir, "tmp")
    FileUtils.mkdir_p(tmp)
    path = ->(name) { File.join(dir, name) }

    # A clean, generated code as typically produced by web QR generators.
    qr_png(path["generated-v10-330px.png"], "https://example.com/" + "x" * 150, 6) unless File.exist?(path["generated-v10-330px.png"])

    # Phone photos: perspective, lighting gradient, blur, sensor noise, JPEG.
    [["photo-640x480.jpg", 640, 480, 4], ["photo-4032x3024-12mp.jpg", 4032, 3024, 22]].each do |name, w, h, px|
      next if File.exist?(path[name])

      qr = File.join(tmp, "photo-qr.png")
      n = qr_png(qr, "https://example.com/menu?table=12&lang=de", px)
      side = (n + 8) * px
      x0 = w * 0.32
      y0 = h * 0.22
      dst = [[x0, y0], [x0 + side * 0.95, y0 + side * 0.08], [x0 + side * 1.02, y0 + side * 1.05], [x0 - side * 0.05, y0 + side * 0.97]]
      persp = [[0, 0], [side, 0], [side, side], [0, side]].zip(dst).map { |(sx, sy), (dx, dy)| "#{sx},#{sy} #{dx.round},#{dy.round}" }.join(" ")
      magick "-size", "#{w}x#{h}", "plasma:wheat-tan", "-blur", "0x#{w / 200}", "(", qr, "-alpha", "set",
             "-virtual-pixel", "transparent", "+distort", "Perspective", persp, ")", "-geometry", "+0+0",
             "-layers", "flatten", "(", "-size", "#{w}x#{h}", "gradient:white-gray55", ")", "-compose", "multiply",
             "-composite", "-blur", "0x#{(px / 8.0).round(1)}", "-attenuate", "0.4", "+noise", "Gaussian",
             "-quality", "90", path[name]
    end

    # A4 page scans with a Swiss QR-bill payment part (46 mm code).
    [[300, 2480, 3508], [600, 4960, 7016]].each do |dpi, w, h|
      base = path["scan-a4-#{dpi}dpi.png"]
      unless File.exist?(base)
        mm = dpi / 25.4
        qr = File.join(tmp, "bill-#{dpi}.png")
        n = qr_png(qr, SWISS_QR_BILL, 1)
        target = (46 * mm).round
        magick qr, "-filter", "point", "-resize", "#{target}x#{target}", "-gravity", "center",
               "-fill", "black", "-draw", "rectangle #{target / 2 - 3.5 * mm},#{target / 2 - 3.5 * mm} #{target / 2 + 3.5 * mm},#{target / 2 + 3.5 * mm}",
               "-fill", "white", "-draw", "rectangle #{target / 2 - 0.8 * mm},#{target / 2 - 2.3 * mm} #{target / 2 + 0.8 * mm},#{target / 2 + 2.3 * mm}",
               "-draw", "rectangle #{target / 2 - 2.3 * mm},#{target / 2 - 0.8 * mm} #{target / 2 + 2.3 * mm},#{target / 2 + 0.8 * mm}",
               qr
        warn "  (QR-bill symbol: #{n} modules, #{(target.to_f / (n + 8)).round(1)} px/module at #{dpi} dpi)"
        magick "-size", "#{w}x#{h}", "xc:white", "-font", "DejaVu-Sans", "-pointsize", (9 * dpi / 72.0).round,
               "-fill", "gray10", *text_lines(w, (25 * mm).round, (180 * mm).round, (5.5 * mm).round, dpi),
               "-stroke", "black", "-strokewidth", (dpi / 300.0).ceil, "-draw", "line 0,#{(192 * mm).round} #{w},#{(192 * mm).round}",
               "-stroke", "none", qr, "-geometry", "+#{(67 * mm).round}+#{(209 * mm).round}", "-composite",
               "-rotate", "0.7", "-gravity", "center", "-crop", "#{w}x#{h}+0+0", "+repage",
               "-blur", "0x#{(dpi / 300.0 * 0.7).round(2)}", "-attenuate", "0.25", "+noise", "Gaussian",
               "-colorspace", "Gray", "-depth", "8", base
      end
      jpg = path["scan-a4-#{dpi}dpi.jpg"]
      magick base, "-quality", "85", jpg unless File.exist?(jpg)
      tif = path["scan-a4-#{dpi}dpi-g4.tif"]
      magick base, "-threshold", "55%", "-type", "Bilevel", "-compress", "Group4", tif unless File.exist?(tif)
      pdf = path["scan-a4-#{dpi}dpi.pdf"]
      magick jpg, "-compress", "jpeg", "-quality", "85", "-units", "PixelsPerInch", "-density", dpi, pdf unless File.exist?(pdf)
    end

    # Worst case: nothing to find (every strategy runs to the end).
    nocode = path["nocode-a4-300dpi.jpg"]
    unless File.exist?(nocode)
      magick "-size", "2480x3508", "xc:white", "-font", "DejaVu-Sans", "-pointsize", 38, "-fill", "gray10",
             *text_lines(2480, 300, 3300, 65, 3), "-blur", "0x0.7", "-attenuate", "0.25", "+noise", "Gaussian",
             "-colorspace", "Gray", "-quality", "85", nocode
    end
    nophoto = path["nocode-photo-4032x3024.jpg"]
    magick "-size", "4032x3024", "plasma:wheat-tan", "-blur", "0x20", "-attenuate", "0.4", "+noise", "Gaussian", "-quality", "90", nophoto unless File.exist?(nophoto)

    FileUtils.rm_rf(tmp)
  end
end

CASES = [
  ["corpus-png", "test/corpus/zxing/qrcode-3/10.png", "ZXing corpus photo, small PNG"],
  ["generated-png", "bench/inputs/generated-v10-330px.png", "clean generated code (v10)"],
  ["photo-0.3mp-jpeg", "bench/inputs/photo-640x480.jpg", "phone photo 640x480"],
  ["photo-12mp-jpeg", "bench/inputs/photo-4032x3024-12mp.jpg", "phone photo 4032x3024"],
  ["scan300-png", "bench/inputs/scan-a4-300dpi.png", "A4 scan 300 dpi, gray PNG"],
  ["scan300-jpeg", "bench/inputs/scan-a4-300dpi.jpg", "A4 scan 300 dpi, JPEG"],
  ["scan300-tiff-g4", "bench/inputs/scan-a4-300dpi-g4.tif", "A4 scan 300 dpi, 1-bit TIFF G4"],
  ["scan300-pdf", "bench/inputs/scan-a4-300dpi.pdf", "A4 scan 300 dpi, PDF (JPEG)"],
  ["scan600-jpeg", "bench/inputs/scan-a4-600dpi.jpg", "A4 scan 600 dpi, JPEG"],
  ["scan600-tiff-g4", "bench/inputs/scan-a4-600dpi-g4.tif", "A4 scan 600 dpi, 1-bit TIFF G4"],
  ["nocode-scan300", "bench/inputs/nocode-a4-300dpi.jpg", "A4 page without code (worst case)"],
  ["nocode-photo-12mp", "bench/inputs/nocode-photo-4032x3024.jpg", "12 MP photo without code (worst case)"]
].freeze

# ---------------------------------------------------------------------------
# Measurement (runs in a child process: bench/reading.rb --child PATH RUNS)

def child(path, runs)
  $LOAD_PATH.unshift File.join(ROOT, "lib")
  status = ->(key) { File.read("/proc/self/status")[/^#{key}:\s+(\d+)/, 1].to_i * 1024 }
  rss_boot = status.call("VmRSS")
  require "qr_reader"
  rss_lib = status.call("VmRSS")
  bytes = File.binread(path)
  GC.start
  rss_before = status.call("VmRSS")
  File.write("/proc/self/clear_refs", "5") # reset the VmHWM peak counter
  allocs_before = GC.stat(:total_allocated_objects)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = QrReader.read(StringIO.new(bytes))
  first = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  allocs = GC.stat(:total_allocated_objects) - allocs_before
  peak = status.call("VmHWM") - rss_before
  warm = Array.new(runs) do
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    QrReader.read(StringIO.new(bytes))
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end.sort
  puts JSON.generate(found: !result.nil?, text: result&.text&.slice(0, 40), version: result&.version,
                     first: first, warm: warm.empty? ? nil : warm[warm.size / 2], peak: peak, allocs: allocs,
                     lib_rss: rss_lib - rss_boot, file_size: bytes.bytesize)
rescue QrReader::UnsupportedImageError, NotImplementedError, NameError => e
  puts JSON.generate(skipped: "#{e.class}: #{e.message[0, 80]}")
end

if ARGV[0] == "--child"
  child(ARGV[1], ARGV[2].to_i)
  exit
end

def human_bytes(n)
  return "-" unless n

  n >= 1 << 20 ? format("%.0f MB", n / 1048576.0) : format("%.0f KB", n / 1024.0)
end

def ms(s)
  return "-" unless s

  s >= 1 ? format("%.2f s", s) : format("%.0f ms", s * 1000)
end

unless system("magick", "-version", out: File::NULL)
  abort "ImageMagick (magick) is needed once to generate bench/inputs/" unless Dir.exist?(INPUTS)
end
puts "Generating inputs in bench/inputs/ (first run only)..." unless File.exist?(File.join(INPUTS, "nocode-photo-4032x3024.jpg"))
Inputs.generate(INPUTS)

modes = [["yjit", ["--yjit"]]]
modes << ["interpreter", []] if options[:interpreter]
cases = CASES.select { |name, _, _| options[:only].nil? || options[:only].include?(name) }
results = []
puts "qr_reader reading benchmark - #{RUBY_DESCRIPTION.split(' (').first}, #{File.read('/proc/cpuinfo')[/model name\s*:\s*(.+)/, 1]}"
modes.each do |mode, flags|
  puts
  puts "== #{mode} =="
  puts format("%-18s %-38s %9s %8s %9s %9s %9s %10s  %s", "input", "description", "file", "found", "first", "warm", "peak RAM", "allocs", "")
  cases.each do |name, rel, desc|
    path = File.join(ROOT, rel)
    unless File.exist?(path)
      puts format("%-18s %-38s missing (#{rel})", name, desc)
      next
    end
    out, err, st = Open3.capture3(RbConfig.ruby, *flags, __FILE__, "--child", path, options[:runs].to_s, chdir: ROOT)
    data = st.success? ? JSON.parse(out.lines.last || "{}") : { "skipped" => "crashed: #{err.lines.last}" }
    if data["skipped"]
      puts format("%-18s %-38s skipped: %s", name, desc, data["skipped"])
      next
    end
    results << data.merge("input" => name, "mode" => mode, "description" => desc)
    lib_rss = data["lib_rss"]
    puts format("%-18s %-38s %9s %8s %9s %9s %9s %10d  %s", name, desc, human_bytes(data["file_size"]),
                data["found"] ? "yes" : "NO", ms(data["first"]), ms(data["warm"]), human_bytes(data["peak"]),
                data["allocs"], data["found"] ? "v#{data['version']}" : "")
    $lib_rss = lib_rss
  end
end
puts
puts "library footprint after require: #{human_bytes($lib_rss)} RSS"
File.write(options[:json], JSON.pretty_generate(results)) if options[:json]
