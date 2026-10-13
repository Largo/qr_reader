# frozen_string_literal: true

require_relative "decoder/galois_field"
require_relative "decoder/reed_solomon"
require_relative "decoder/function_patterns"
require_relative "decoder/data_mask"
require_relative "decoder/codewords"
require_relative "decoder/format_reader"
require_relative "decoder/character_set"
require_relative "decoder/bitstream_parser"

module QrReader
  # Decodes a sampled QR code module grid (ISO/IEC 18004:2015, Model 2).
  #
  #   result = QrReader::Decoder.decode(bit_matrix)   # => Result or nil
  #   QrReader::Decoder.diagnose(bit_matrix)          # => { status: :reed_solomon, ... }
  #
  # The pipeline is ordered so that garbage fails as early and cheaply as
  # possible (the detector may try many candidate grids): dimension, format
  # information (at most two candidates per orientation when the copies
  # disagree), version information, then the RS blocks one at a time, and
  # only then the bit stream.
  module Decoder
    # Diagnostic statuses in pipeline order (later = got further).
    STATUSES = %i[dimension format_info version_info reed_solomon bitstream ok].freeze

    # Array#pack formats "C<count>" that take the first +count+ codewords of
    # an RS block (at most 123 data codewords per block).
    DATA_FORMATS = Array.new(124) { |count| "C#{count}".freeze }.freeze
    # Strength order of the EC levels.
    EC_STRENGTH = { L: 0, M: 1, Q: 2, H: 3 }.freeze
    private_constant :DATA_FORMATS, :EC_STRENGTH

    class << self
      # Decodes +bit_matrix+ (N x N, N = 21..177, 1 = dark, no quiet zone).
      # Returns a Result (with points: nil) or nil when the grid is not a
      # decodable symbol. With +try_mirrored+, the grid is also read
      # transposed (first, if its format information reads better that way);
      # a Result read so is marked mirrored.
      #
      # Never raises for any grid content; raises TypeError if +bit_matrix+
      # is not a QrReader::BitMatrix.
      def decode(bit_matrix, try_mirrored: true)
        bits = module_bits(bit_matrix)
        bits && run(bits, bit_matrix.width, try_mirrored, nil)
      end

      # Runs the decoder with bookkeeping and returns a Hash describing how far
      # it got: :status (one of STATUSES), :mirrored, :dimension, :format_bits,
      # :ec_level (:l, :m, :q, :h), :mask, :format_distance, :version, :version_bits,
      # :version_info (decoded version numbers of both copies), :blocks,
      # :block_errors (corrected codewords per RS block, nil = uncorrectable),
      # :errors_corrected, :error (bit stream message) and :result.
      #
      # Makes exactly the attempts #decode makes, so :status is :ok exactly
      # when #decode returns a Result (then :result is that Result);
      # otherwise the attempt that got furthest is reported.
      def diagnose(bit_matrix, try_mirrored: true)
        bits = module_bits(bit_matrix)
        return { status: :dimension, mirrored: false, dimension: [bit_matrix.width, bit_matrix.height] } unless bits

        diags = []
        result = run(bits, bit_matrix.width, try_mirrored, diags)
        return diags.find { |diag| diag[:result].equal?(result) } if result

        diags.max_by.with_index { |diag, i| [STATUSES.index(diag[:status]), -i] }
      end

      private

      # Tries the format information candidates of the readings in turn and
      # returns the first Result, or nil. With +diags+ (an Array), a Hash per
      # attempt is appended (an attempt without format information too).
      #
      # A code word of a stronger EC level is also one of a weaker level with
      # the same block layout (its generator has the weaker one's roots and
      # more), so when damaged format information names both levels with the
      # same mask, the weaker reading would succeed - with the wrong level and,
      # for a symbol filled to capacity, parity bytes parsed as data. The
      # same-mask runner-up is therefore tried as well and the stronger
      # successful reading wins.
      def run(bits, n, try_mirrored, diags)
        readings(bits, n, try_mirrored).each do |mirrored, words, candidates|
          candidates = [nil] if candidates.empty? && diags
          candidates.each_with_index do |format, k|
            result = attempt(bits, n, mirrored, words, format, diags && (diags << { mirrored: mirrored }).last)
            next unless result

            sibling = candidates[k + 1]
            if sibling && stronger_reading?(sibling[0], format[0])
              stronger = attempt(bits, n, mirrored, words, sibling, diags && (diags << { mirrored: mirrored }).last)
              return stronger if stronger
            end
            return result
          end
        end
        nil
      end

      # True if +other+ (FormatInformation) has the mask of +info+ and a
      # stronger EC level.
      def stronger_reading?(other, info)
        other.mask == info.mask && EC_STRENGTH[other.ec_level] > EC_STRENGTH[info.ec_level]
      end

      # The module String with only 0/1 bytes, or nil if the matrix cannot be
      # a symbol (not square, wrong dimension, inconsistent storage).
      def module_bits(matrix)
        raise TypeError, "expected a QrReader::BitMatrix, got #{matrix.class}" unless matrix.is_a?(BitMatrix)

        n = matrix.width
        bits = matrix.bits
        return nil unless n.is_a?(Integer) && bits.is_a?(String) && matrix.height == n &&
                          SymbolVersion.for_dimension(n) && bits.bytesize == n * n

        # Byte-wise operations below need a binary String (the BitMatrix
        # constructor ensures one, but the String is mutable).
        bits = bits.b unless bits.encoding == Encoding::BINARY
        # Any byte other than 1 counts as light (like BitMatrix#dark?).
        bits.count("\x00\x01") == bits.bytesize ? bits : bits.tr("^\x01", "\x00")
      end

      # The orientations worth trying, the one whose format information reads
      # better first: Array of [mirrored, format_words, format_candidates].
      #
      # A symbol read the wrong way round yields format words at distance 2
      # or more from every (masked) code word, so when both copies of one
      # orientation read the same exact code word and the other orientation
      # is at least 2 away, only the first is tried. (Copies written without
      # the 0x5412 mask can read exactly both ways round; then both
      # orientations are tried.)
      def readings(bits, n, try_mirrored)
        normal = reading(bits, n, false)
        return [normal] unless try_mirrored

        mirrored = reading(bits, n, true)
        first, second = best_distance(mirrored) < best_distance(normal) ? [mirrored, normal] : [normal, mirrored]
        words = first[1]
        exact = words[0] == words[1] && best_distance(first).zero?
        exact && best_distance(second) >= 2 ? [first] : [first, second]
      end

      def reading(bits, n, mirrored)
        words = FormatReader.format_bits(bits, n, mirrored: mirrored)
        [mirrored, words, FormatReader.format_candidates(*words)]
      end

      # Smallest format distance of a reading (4 when nothing is within 3).
      def best_distance(reading)
        best = 4
        reading[2].each { |_, distance| best = distance if distance < best }
        best
      end

      # One decoding pass in one orientation, given the format information
      # words read for it and the format information to assume
      # ([FormatInformation, distance] or nil). Returns a Result or nil;
      # fills +diag+ if given.
      def attempt(bits, n, mirrored, format_words, format, diag)
        version = SymbolVersion.for_dimension(n)
        diag&.merge!(dimension: n, version: version.number, format_bits: format_words)
        return failure(diag, :format_info) unless format

        info, distance = format
        level = info.ec_level
        mask = info.mask
        diag&.merge!(ec_level: level.downcase, mask: mask, format_distance: distance)
        return failure(diag, :version_info) unless version_info_consistent?(bits, n, version, mirrored, diag)

        data, corrected = correct_blocks(bits, version, level, mask, mirrored, diag)
        return failure(diag, :reed_solomon) unless data

        content = begin
          BitstreamParser.parse(data, version.number)
        rescue FormatError => e
          diag[:error] = e.message if diag
          return failure(diag, :bitstream)
        end

        result = Result.new(text: content.text, raw_bytes: content.raw_bytes, version: version.number,
                            ec_level: level.downcase, mask: mask, mirrored: mirrored, errors_corrected: corrected,
                            eci: content.eci, fnc1: content.fnc1, structured_append: content.structured_append,
                            symbology_identifier: content.symbology_identifier, segments: content.segments)
        diag&.merge!(status: :ok, result: result)
        result
      end

      def failure(diag, status)
        diag[:status] = status if diag
        nil
      end

      # Versions 7+ carry their version number twice. The dimension decides:
      # the grid is rejected only when both copies name the same other
      # version (it was most likely sampled at the wrong size - a hint for
      # the detector). Unreadable copies, or a single copy damaged into
      # another version's code word, fall back to the dimension; Reed-Solomon
      # has the final word.
      def version_info_consistent?(bits, n, version, mirrored, diag)
        return true if version.number < 7

        copies = FormatReader.version_bits(bits, n, mirrored: mirrored)
        diag[:version_bits] = copies if diag
        return true if copies.include?(version.version_info_bits) && !diag

        first = FormatReader.decode_version(copies[0])
        second = FormatReader.decode_version(copies[1])
        diag[:version_info] = [first, second] if diag
        first.nil? || first != second || first == version.number
      end

      # Reads, error-corrects and concatenates the data codewords of all RS
      # blocks. Returns [data String, corrected count] or nil at the first
      # uncorrectable block (with +diag+, all blocks are checked).
      def correct_blocks(bits, version, level, mask, mirrored, diag)
        layout = Codewords.layout(version.number)
        order = mirrored ? layout.mirrored_order : layout.order
        mask_codewords = layout.mask_codewords(mask)
        ec_count = version.ec_blocks(level).ec_codewords_per_block
        blocks = layout.blocks(level)
        data = "".b
        corrected = 0
        block_errors = diag ? [] : nil
        blocks.each do |data_count, indices|
          codewords = Codewords.read_block(bits, order, mask_codewords, indices)
          fixed = ReedSolomon.decode(codewords, ec_count)
          block_errors << fixed if diag
          if fixed
            corrected += fixed
            data << codewords.pack(DATA_FORMATS[data_count])
          elsif !diag
            return nil
          end
        end
        failed = diag && block_errors.include?(nil)
        diag&.merge!(blocks: blocks.size, block_errors: block_errors, errors_corrected: failed ? nil : corrected)
        failed ? nil : [data, corrected]
      end
    end
  end
end
