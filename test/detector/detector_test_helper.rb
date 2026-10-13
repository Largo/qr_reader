# frozen_string_literal: true

require_relative "../test_helper"
require "distort"

# Helpers for the detector tests: synthetic symbols, running the detector
# and comparing sampled grids with the source matrix.
module DetectorTestHelper
  include QrTestHelper

  # Payload that fills a good part of the given version at level L.
  def payload(version, seed: version)
    rng = Random.new(seed)
    chars = [*"a".."z", *"0".."9"]
    capacity = QrReader::SymbolVersion[version].data_codewords(:L) - 3
    Array.new([capacity * 3 / 4, 1].max) { chars[rng.rand(chars.size)] }.join
  end

  def symbol(version, level: :L)
    rqr_matrix(payload(version), level: level.to_s.downcase.to_sym, size: version)
  end

  # Number of differing modules outside the finder patterns and their
  # separators, which carry no data (Infinity if the sizes differ).
  def module_errors(a, b)
    return Float::INFINITY unless a && b && a.width == b.width && a.height == b.height

    n = a.width
    a.bits.bytesize.times.count do |i|
      x = i % n
      y = i / n
      next false if (x < 8 || x >= n - 8) && y < 8 || (x < 8 && y >= n - 8)

      a.bits.getbyte(i) != b.bits.getbyte(i)
    end
  end

  # Fewest module errors of any grid a detector produces for +image+
  # (candidates' bits and alternatives; the transposed source is accepted
  # too, since mirrored symbols are sampled transposed).
  def best_errors(image, expected, binarizer: :hybrid, invert: false, try_harder: true, limit: 8)
    matrix = QrReader::Binarizer.public_send(binarizer, image)
    matrix = matrix.invert if invert
    detector = QrReader::Detector.new(matrix, image: invert ? image.invert : image)
    targets = [expected, expected.transpose]
    best = Float::INFINITY
    detector.each_candidate(try_harder: try_harder).first(limit).each do |candidate|
      [candidate.bits, *candidate.alternatives.first(8)].each do |grid|
        targets.each { |t| best = [best, module_errors(grid, t)].min }
        return 0 if best.zero?
      end
    end
    best
  end

  # Asserts that some sampled grid matches the source within +tolerance+
  # module errors.
  def assert_detects(image, expected, tolerance: 3, message: nil, **options)
    errors = best_errors(image, expected, **options)
    assert errors <= tolerance, "#{message || 'symbol'}: best grid has #{errors} module errors"
  end

  # The candidates' sampled grids, decoded (the decoder is another
  # component; used where texts are easier to compare than grids).
  def decoded_texts(image, multi: false)
    detector = QrReader::Detector.new(QrReader::Binarizer.hybrid(image), image: image)
    texts = []
    detector.each_candidate(try_harder: true, multi: multi) do |candidate|
      result = QrReader::Decoder.decode(candidate.bits) ||
               candidate.alternatives.lazy.filter_map { |bits| QrReader::Decoder.decode(bits) }.first
      next unless result

      detector.confirm(candidate)
      texts << result.text
      break unless multi
    end
    texts.uniq
  end
end
