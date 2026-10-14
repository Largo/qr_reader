# frozen_string_literal: true

# Per-stage timings on representative inputs: PNG decode, JPEG decode,
# binarization, detection, symbol decoding, end-to-end QrReader.decode, and
# scanned documents (an A4 page at 300 DPI as PNG, JPEG, Group 4 TIFF and
# PDF). Stages whose component is not implemented yet are reported as "n/a".
#
# Usage:
#   bundle exec ruby [--yjit] bench/speed.rb [options]
#
# Options:
#   --iterations N     timed runs per input after one warm-up run (default 5; inputs
#                      slower than 2 s per run are timed once)
#   --stage LIST       only these stages: png,jpeg,binarize,detect,decode,end_to_end,scan
#   --json OUT         write the timings as JSON
#   --compare PREV     show the change against an earlier --json run
#
# Compare interpreters with `ruby bench/speed.rb` vs `ruby --yjit bench/speed.rb`.

require_relative "support"
require "stringio"
require "optparse"
require "time"
require "qr_encoder"
require "distort"
require "corpus"
require "open3"

module SpeedBench
  STAGES = %w[png jpeg binarize detect decode end_to_end scan].freeze
  TIME_BUDGET_MS = 2000.0

  Measurement = Data.define(:stage, :input, :status, :mean, :min, :runs, :megapixels)

  module_function

  def parse_options(argv)
    options = { iterations: 5, stages: STAGES }
    parser = OptionParser.new do |o|
      o.banner = "Usage: bundle exec ruby [--yjit] bench/speed.rb [options]"
      o.on("--iterations N", Integer) { |v| options[:iterations] = [v, 1].max }
      o.on("--stage LIST") do |v|
        options[:stages] = v.split(",")
        unknown = options[:stages] - STAGES
        abort "unknown stage(s) #{unknown.join(', ')}; known: #{STAGES.join(', ')}" unless unknown.empty?
      end
      o.on("--json OUT") { |v| options[:json] = v }
      o.on("--compare PREV") { |v| options[:compare] = v }
    end
    BenchSupport.parse!(parser, argv)
    options
  end

  def run(argv)
    options = parse_options(argv)
    puts "qr_reader #{QrReader::VERSION} stage timings -- #{BenchSupport.runtime}"
    inputs = Inputs.new
    results = []
    options[:stages].each do |stage|
      puts
      puts "== #{stage}"
      send("bench_#{stage}", inputs) do |label, megapixels, callable|
        m = time(stage, label, megapixels, options[:iterations], callable)
        results << m
        puts line(m)
      end
    end
    BenchSupport.write_json(options[:json], to_json(results)) if options[:json]
    compare(results, options[:compare]) if options[:compare]
  end

  # Warm-up run (also detects unimplemented components), then timed runs.
  def time(stage, label, megapixels, iterations, callable)
    first, first_ms = BenchSupport.measure { callable.call }
    status = first.nil? || first == [] || first == false ? "nil result" : "ok"
    times = []
    budget = first_ms > TIME_BUDGET_MS ? 1 : iterations
    budget.times { times << BenchSupport.measure { callable.call }[1] }
    Measurement.new(stage: stage, input: label, status: status, mean: times.sum / times.size,
                    min: times.min, runs: times.size, megapixels: megapixels)
  rescue StandardError, ScriptError, SystemStackError => e
    # Only a missing component is "n/a"; e.g. a NoMethodError on nil inside
    # a component is a bug and reported as an error.
    kind = BenchSupport.missing_component?(e) ? "n/a" : "error"
    Measurement.new(stage: stage, input: label, status: "#{kind} (#{e.class}: #{e.message[0, 80]})",
                    mean: nil, min: nil, runs: 0, megapixels: megapixels)
  end

  def line(m)
    throughput = m.mean && m.megapixels ? format("%6.1f MP/s", m.megapixels / (m.mean / 1000.0)) : ""
    status = m.status == "ok" ? "" : m.status
    format("  %-44s %10s %10s %11s  %s", m.input, BenchSupport.ms(m.mean), m.min ? "min #{BenchSupport.ms(m.min)}" : "",
           throughput, status)
  end

  # --- stages ------------------------------------------------------------------

  def bench_png(inputs)
    inputs.corpus_samples.each do |path|
      bytes = File.binread(path)
      yield "corpus #{path.split('/').last(2).join('/')} (#{png_info(bytes)})", megapixels(bytes),
            -> { QrReader::Formats.decode(bytes) }
    end
    { "gray 1024x1024" => inputs.png_gray, "rgb 1600x1200" => inputs.png_rgb }.each do |label, bytes|
      yield "synthetic #{label}", megapixels(bytes), -> { QrReader::Formats.decode(bytes) }
    end
  end

  def bench_jpeg(inputs)
    return yield("jpeg (ImageMagick not available)", nil, -> { raise NotImplementedError, "no magick" }) unless Distort.jpeg_available?

    inputs.jpegs.each do |label, bytes|
      mp = inputs.photo.size / 1e6
      yield "#{label} 1600x1200", mp, -> { QrReader::Formats.decode(bytes) }
      yield "#{label} 1600x1200 scale: 2", mp, -> { QrReader::Formats.decode(bytes, scale: 2) }
    end
    inputs.fixture_jpegs.each do |path|
      bytes = File.binread(path)
      yield "fixture #{File.basename(path)}", nil, -> { QrReader::Formats.decode(bytes) }
    end
  end

  def bench_binarize(inputs)
    inputs.images.each do |label, image|
      mp = image.size / 1e6
      yield "hybrid #{label}", mp, -> { QrReader::Binarizer.hybrid(image) }
      yield "global_histogram #{label}", mp, -> { QrReader::Binarizer.global_histogram(image) }
    end
  end

  def bench_detect(inputs)
    inputs.images.each do |label, image|
      bits = begin
        QrReader::Binarizer.hybrid(image)
      rescue StandardError, ScriptError => e # reported (n/a or error) by #time
        next yield("first candidate #{label}", nil, -> { raise e })
      end
      yield "first candidate #{label}", image.size / 1e6,
            -> { QrReader::Detector.new(bits, image: image).each_candidate.first }
    end
    clean = inputs.clean_image
    yield "detect_pure clean v10 (#{clean.width}x#{clean.height})", clean.size / 1e6,
          -> { QrReader::Detector.detect_pure(inputs.clean_bits) }
  end

  def bench_decode(inputs)
    inputs.symbols.each do |label, matrix|
      yield "Decoder.decode #{label}", nil, -> { QrReader::Decoder.decode(matrix) }
    end
  end

  def bench_end_to_end(inputs)
    inputs.corpus_samples.first(2).each do |path|
      yield "decode(path) #{path.split('/').last(2).join('/')}", nil, -> { QrReader.decode(path) }
    end
    yield "decode(png bytes) clean v10", nil, -> { QrReader.decode(StringIO.new(inputs.clean_png)) }
    yield "decode(Image) photo 1600x1200", inputs.photo.size / 1e6, -> { QrReader.decode(inputs.photo) }
    page = inputs.scan_page
    yield "decode(Image) A4 scan #{page.width}x#{page.height}", page.size / 1e6, -> { QrReader.decode(page) }
    yield "read_all(Image) 4 codes", nil, -> { QrReader.read_all(inputs.multi) }
    return unless Distort.jpeg_available?

    yield "decode(jpeg bytes) photo 1600x1200", inputs.photo.size / 1e6, -> { QrReader.decode(StringIO.new(inputs.jpegs.first[1])) }
  end

  # Scanned documents: one A4 page at 300 DPI in the formats scanners write.
  def bench_scan(inputs)
    page = inputs.scan_page
    mp = page.size / 1e6
    label = "A4 300 DPI #{page.width}x#{page.height}"
    png = inputs.scan_png
    yield "png load #{label}", mp, -> { QrReader::Formats.decode(png) }
    yield "decode(png bytes) #{label}", mp, -> { QrReader.decode(StringIO.new(png)) }
    inputs.scan_documents.each do |name, bytes|
      # No ImageMagick: shown as n/a.
      next yield("#{name} #{label}", mp, -> { raise NotImplementedError, bytes.message }) if bytes.is_a?(Exception)

      yield "#{name} load #{label}", mp, -> { load_document(bytes) }
      yield "decode(#{name} bytes) #{label}", mp, -> { QrReader.decode(StringIO.new(bytes)) }
    end
  end

  # Image(s) of an encoded scan, through the format's own module (TIFF and
  # PDF are containers that QrReader::Formats.decode does not open).
  def load_document(bytes)
    if bytes.start_with?("%PDF")
      QrReader::Formats::PDF.images(bytes)
    elsif bytes.start_with?("II*\0".b, "MM\0*".b)
      QrReader::Formats::TIFF.decode(bytes)
    else
      QrReader::Formats.decode(bytes)
    end
  end

  def png_info(bytes)
    w, h = bytes.byteslice(16, 8).unpack("NN")
    "#{w}x#{h}"
  end

  def megapixels(png)
    w, h = png.byteslice(16, 8).unpack("NN")
    w * h / 1e6
  end

  # --- report --------------------------------------------------------------------

  def to_json(results)
    {
      "meta" => { "runtime" => BenchSupport.runtime, "created" => Time.now.utc.iso8601 },
      "timings" => results.to_h do |m|
        ["#{m.stage}: #{m.input}", { "mean_ms" => m.mean&.round(3), "min_ms" => m.min&.round(3), "runs" => m.runs, "status" => m.status }]
      end
    }
  end

  def compare(results, path)
    previous = BenchSupport.load_json(path)["timings"]
    abort "#{path} is not a bench/speed.rb report (no \"timings\")" unless previous.is_a?(Hash)

    puts
    puts "vs #{path}:"
    results.each do |m|
      before = previous.dig("#{m.stage}: #{m.input}", "mean_ms")
      next unless before && m.mean

      puts format("  %-56s %10s -> %10s  (%+.0f%%)", "#{m.stage}: #{m.input}", BenchSupport.ms(before), BenchSupport.ms(m.mean),
                  100.0 * (m.mean - before) / before)
    end
  end

  # Lazily built benchmark inputs (deterministic).
  class Inputs
    def corpus_samples
      @corpus_samples ||= begin
        cases = QrCorpus.cases
        by_size = cases.sort_by { |c| -File.size(c.path) }
        [cases.first, by_size.first, by_size[by_size.size / 2]].compact.uniq.map(&:path)
      end
    end

    # A v6 code (8 px/module) in a 1600x1200 "photo": gradient, blur, noise.
    def photo
      @photo ||= begin
        code = QrTestEncoder.build("https://qr.test/speed/photo", version: 6, level: :M).to_image(module_size: 8)
        canvas = Distort.compose(1600, 1200, [[Distort.rotate(code, 12), 610, 380]], background: 235)
        img = Distort.gradient(canvas, from: 1.0, to: 0.55, angle: 35)
        Distort.gaussian_noise(Distort.blur(img, 1.2), sigma: 6, seed: 1)
      end
    end

    def clean_image
      @clean_image ||= QrTestEncoder.build("https://qr.test/speed/clean", version: 10, level: :Q).to_image(module_size: 4)
    end

    def clean_bits
      @clean_bits ||= QrReader::Binarizer.global_histogram(clean_image)
    end

    def clean_png
      @clean_png ||= BenchSupport.png_bytes(clean_image)
    end

    def multi
      @multi ||= begin
        codes = Array.new(4) { |k| QrTestEncoder.build("code #{k}", version: 2 + k, level: :M).to_image(module_size: 5) }
        Distort.compose(500, 500, codes.each_with_index.map { |img, k| [img, 10 + (k % 2) * 250, 10 + (k / 2) * 250] })
      end
    end

    def png_gray
      @png_gray ||= BenchSupport.png_bytes(Distort.resize(photo, 1024, 1024))
    end

    def png_rgb
      @png_rgb ||= BenchSupport.png_bytes(photo, rgb: true)
    end

    def jpegs
      @jpegs ||= [
        ["jpeg gray q75", Distort.jpeg_bytes(photo, quality: 75)],
        ["jpeg color 4:2:0 q75", Distort.jpeg_bytes(photo, quality: 75, color: true)],
        ["jpeg progressive color q75", Distort.jpeg_bytes(photo, quality: 75, color: true, progressive: true)]
      ]
    end

    # The three largest JPEG fixtures that are meant to decode (the fixture
    # set also holds deliberately unsupported files, e.g. arithmetic coding).
    def fixture_jpegs
      @fixture_jpegs ||= Dir[File.expand_path("../test/fixtures/jpeg/**/*.{jpg,jpeg}", __dir__)]
                         .sort_by { |path| [-File.size(path), path] }
                         .reject { |path| unsupported?(File.binread(path)) }
                         .first(3)
    end

    # A4 page at 300 DPI: off-white paper with sensor noise, lines of "text"
    # and a 25 mm wide QR code skewed by 1.2 degrees near the bottom right.
    def scan_page
      @scan_page ||= begin
        rng = Random.new(4)
        code = QrTestEncoder.build("https://qr.test/speed/scan/invoice-2024-0042", version: 4, level: :M).to_image(module_size: 8, quiet: 2)
        text = Array.new(70) do |line|
          words = []
          x = 236
          # Lines beside the code end before it.
          right = line > 64 ? 1900 : 2100
          while x < right
            width = rng.rand(30..160)
            words << [QrReader::Image.new(width, 28, "\x28".b * (width * 28)), x, 300 + line * 42]
            x += width + rng.rand(14..24)
          end
          words
        end.flatten(1)
        page = Distort.compose(2480, 3508, text + [[Distort.rotate(code, 1.2, margin: 0), 1980, 3080]], background: 246)
        Distort.gaussian_noise(page, sigma: 4, seed: 5)
      end
    end

    def scan_png
      @scan_png ||= BenchSupport.png_bytes(scan_page)
    end

    # name => encoded bytes, or the Distort::Unavailable error when the input
    # could not be produced.
    def scan_documents
      @scan_documents ||= begin
        pgm = Distort.pgm_bytes(scan_page)
        {
          "jpeg q85" => magick(pgm, "-quality", "85", "jpg:-"),
          "tiff g4" => magick(pgm, "-threshold", "50%", "-type", "Bilevel", "-compress", "Group4", "tiff:-"),
          "pdf (jpeg)" => magick(pgm, "-quality", "85", "-compress", "JPEG", "-density", "300", "pdf:-"),
          "pdf (g4)" => magick(pgm, "-threshold", "50%", "-type", "Bilevel", "-compress", "Group4", "-density", "300", "pdf:-")
        }
      end
    end

    def images
      @images ||= begin
        list = {}
        path = corpus_samples.first
        begin
          image = QrReader::Formats.decode(File.binread(path))
          list["corpus #{path.split('/').last(2).join('/')} #{image.width}x#{image.height}"] = image
        rescue NotImplementedError, StandardError
          nil
        end
        list["photo 1600x1200"] = photo
        list["A4 scan 2480x3508"] = scan_page
        list
      end
    end

    def symbols
      @symbols ||= [1, 10, 25, 40].to_h do |v|
        rng = Random.new(v)
        length = (QrTestEncoder.capacity_bits(v, :M) - 20) / 8 * 4 / 5
        text = Array.new(length) { rng.rand(32..126).chr }.join
        ["clean v#{v}-M (#{length} bytes)", QrTestEncoder.encode(text, version: v, level: :M)]
      end.merge(
        "v10-H max errors" => QrTestEncoder.encode("errors " * 10, version: 10, level: :H, corrupt_per_block: :max, seed: 1),
        "v25-L max errors" => QrTestEncoder.encode("errors " * 80, version: 25, level: :L, corrupt_per_block: :max, seed: 2)
      )
    end

    private

    def unsupported?(bytes)
      QrReader::Formats.decode(bytes)
      false
    rescue QrReader::UnsupportedImageError
      true
    rescue StandardError, NotImplementedError
      false # reported by the benchmark itself
    end

    # Output of `magick pgm:- ARGS` for +input+, or a Distort::Unavailable.
    def magick(input, *args)
      return Distort::Unavailable.new("ImageMagick (magick) is not installed") unless Distort.jpeg_available?

      out, err, status = Open3.capture3("magick", "pgm:-", *args, stdin_data: input, binmode: true)
      status.success? ? out : Distort::Unavailable.new("magick failed: #{err[0, 80]}")
    end
  end
end

SpeedBench.run(ARGV) if $PROGRAM_NAME == __FILE__
