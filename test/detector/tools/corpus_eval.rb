# frozen_string_literal: true

# Detector accuracy on the ZXing QR corpus (development tool).
#
#   bundle exec ruby test/detector/tools/corpus_eval.rb [options]
#     --only qrcode-3[,qrcode-4/12]   restrict cases (see QrCorpus.cases)
#     --rotations 0,90,180,270        rotations to test (default 0)
#     --verbose                       list every miss with detector diagnostics
#     --yjit-warmup                   run everything twice, time the second run
#     --binarizers hybrid,global      binarizers tried in order (Binarizer method
#                                     names; "global" = global_histogram)
#
# Runs the same strategy a reader would: pure fast path, then the hybrid
# binarizer (fast, then try_harder), then the global histogram binarizer;
# decodes every candidate's bits and alternatives with QrReader::Decoder.

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../support", __dir__)
require "qr_reader"
require "corpus"
require "optparse"

options = { rotations: [0], only: nil, verbose: false, warmup: false, binarizers: %i[hybrid global_histogram] }
OptionParser.new do |o|
  o.on("--only LIST") { |v| options[:only] = v }
  o.on("--rotations LIST") { |v| options[:rotations] = v.split(",").map(&:to_i) }
  o.on("--verbose") { options[:verbose] = true }
  o.on("--yjit-warmup") { options[:warmup] = true }
  o.on("--binarizers LIST") do |v|
    options[:binarizers] = v.split(",").map { |b| b == "global" ? :global_histogram : b.to_sym }
  end
end.parse!

module CorpusEval
  module_function

  def load(path)
    QrReader::Formats.decode(File.binread(path))
  rescue NotImplementedError, NameError
    w, h = `magick identify -format "%w %h" #{path}`.split.map(&:to_i)
    QrReader::Image.new(w, h, `magick #{path} -colorspace gray -depth 8 gray:-`.b)
  end

  # Decodes candidate bits and alternatives; returns [texts, stage, tries].
  def try_candidates(enum, stats)
    texts = []
    enum.each do |candidate|
      stats[:candidates] += 1
      result = QrReader::Decoder.decode(candidate.bits)
      unless result
        candidate.alternatives.each do |bits|
          stats[:alternatives] += 1
          result = QrReader::Decoder.decode(bits)
          break if result
        end
      end
      if result
        texts << result.text
        return texts
      end
    end
    texts
  end

  def read(image, stats, binarizers)
    binarizers.each_with_index do |name, i|
      bm = QrReader::Binarizer.public_send(name, image)
      if i.zero? && (pure = QrReader::Detector.detect_pure(bm)) && (r = QrReader::Decoder.decode(pure.bits))
        return [[r.text], :pure]
      end

      detector = QrReader::Detector.new(bm, image: image)
      modes = i.zero? ? [false, true] : [true]
      modes.each do |hard|
        texts = try_candidates(detector.each_candidate(try_harder: hard), stats)
        return [texts, :"#{name}_#{hard ? 'hard' : 'fast'}"] unless texts.empty?
      end
    end
    [[], :none]
  end

  def diagnostics(image)
    bm = QrReader::Binarizer.hybrid(image)
    detector = QrReader::Detector.new(bm, image: image)
    fps = detector.finder_patterns(try_harder: true)
    cands = detector.each_candidate(try_harder: true).first(3)
    "fps=#{fps.size} #{fps.first(6).map { |f| format('(%.0f,%.0f %.1f)', f.x, f.y, f.module_size) }.join(' ')}\n" \
      "      #{cands.map { |c| "dim=#{c.dimension} #{QrReader::Decoder.diagnose(c.bits)[:status]}" }.join(' | ')}"
  rescue StandardError => e
    "diag error #{e.class}: #{e.message}"
  end

  def run(options)
    cases = QrCorpus.cases(only: options[:only])
    images = cases.to_h { |c| [c.id, load(c.path)] }
    passes = options[:warmup] ? 2 : 1
    summary = nil
    passes.times do |pass|
      summary = Hash.new { |h, k| h[k] = [0, 0] }
      stages = Hash.new(0)
      stats = Hash.new(0)
      misses = []
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      options[:rotations].each do |rot|
        cases.each do |c|
          image = images[c.id].rotate(rot)
          texts, stage = read(image, stats, options[:binarizers])
          ok = texts.include?(c.expected)
          stages[ok ? stage : :miss] += 1
          summary[[c.dir, rot]][1] += 1
          summary[[c.dir, rot]][0] += 1 if ok
          misses << [c, rot, texts, image] unless ok
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      next if pass < passes - 1

      summary.sort.each { |(dir, rot), (ok, n)| puts format("%-10s %3d°  %3d / %3d", dir, rot, ok, n) }
      total_ok = summary.values.sum(&:first)
      total = summary.values.sum(&:last)
      puts format("total %d / %d   %.1f s (%.0f ms/image)  stages=%p  stats=%p",
                  total_ok, total, elapsed, elapsed * 1000 / total, stages, stats)
      misses.each do |c, rot, texts, image|
        puts "MISS #{c.id} rot=#{rot} got=#{texts.map { |t| t[0, 30] }.inspect}"
        puts "      #{diagnostics(image)}" if options[:verbose]
      end
    end
  end
end

CorpusEval.run(options)
