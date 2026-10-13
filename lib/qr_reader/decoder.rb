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
  # information, version information, then the RS blocks one at a time, and
  # only then the bit stream.
  module Decoder
    # Diagnostic statuses in pipeline order (later = got further).
    STATUSES = %i[dimension format_info version_info reed_solomon bitstream ok].freeze

    # Array#pack formats "C<count>" that append the first +count+ codewords
    # of an RS block (at most 123 data codewords per block).
    DATA_FORMATS = Array.new(124) { |count| "C#{count}".freeze }.freeze
    private_constant :DATA_FORMATS

    class << self
      # Decodes +bit_matrix+ (N x N, N = 21..177, 1 = dark, no quiet zone).
      # Returns a Result (with points: nil) or nil when the grid is not a
      # decodable symbol. If +try_mirrored+ is set and the normal reading
      # fails, the transposed grid is tried and the Result marked mirrored.
      #
      # The orientation whose format information reads better goes first.
      # A symbol read the wrong way round yields format words at distance 2
      # or more from every (masked) code word, so when the first reading had
      # exact format information and the other one is at least 2 away, the
      # other one is not tried. (Copies written without the 0x5412 mask can
      # read exactly both ways round; then both orientations are tried.)
      #
      # Never raises for any grid content; raises TypeError if +bit_matrix+
      # is not a QrReader::BitMatrix.
      def decode(bit_matrix, try_mirrored: true)
        bits = module_bits(bit_matrix)
        return nil unless bits

        n = bit_matrix.width
        normal_words = FormatReader.format_bits(bits, n, false)
        normal = FormatReader.decode_format(*normal_words)
        return attempt(bits, n, false, normal_words, normal, nil) unless try_mirrored

        mirrored_words = FormatReader.format_bits(bits, n, true)
        mirrored = FormatReader.decode_format(*mirrored_words)
        normal_distance = normal ? normal[1] : 4
        mirrored_distance = mirrored ? mirrored[1] : 4
        if mirrored_distance < normal_distance
          result = attempt(bits, n, true, mirrored_words, mirrored, nil)
          return result if result || (mirrored_distance.zero? && normal_distance >= 2)

          attempt(bits, n, false, normal_words, normal, nil)
        else
          result = attempt(bits, n, false, normal_words, normal, nil)
          return result if result || (normal_distance.zero? && mirrored_distance >= 2)

          attempt(bits, n, true, mirrored_words, mirrored, nil)
        end
      end

      # Runs the decoder with bookkeeping and returns a Hash describing how far
      # it got: :status (one of STATUSES), :mirrored, :dimension, :format_bits,
      # :ec_level, :mask, :format_distance, :version, :version_bits,
      # :version_info (decoded version numbers of both copies), :blocks,
      # :block_errors (corrected codewords per RS block, nil = uncorrectable),
      # :errors_corrected, :error (bit stream message) and :result. With
      # +try_mirrored+, the reading that got further wins.
      def diagnose(bit_matrix, try_mirrored: true)
        bits = module_bits(bit_matrix)
        return { status: :dimension, mirrored: false, dimension: [bit_matrix.width, bit_matrix.height] } unless bits

        n = bit_matrix.width
        normal = { mirrored: false }
        words = FormatReader.format_bits(bits, n, false)
        attempt(bits, n, false, words, FormatReader.decode_format(*words), normal)
        return normal if normal[:status] == :ok || !try_mirrored

        mirrored = { mirrored: true }
        words = FormatReader.format_bits(bits, n, true)
        attempt(bits, n, true, words, FormatReader.decode_format(*words), mirrored)
        STATUSES.index(mirrored[:status]) > STATUSES.index(normal[:status]) ? mirrored : normal
      end

      private

      # The module String with only 0/1 bytes, or nil if the matrix cannot be
      # a symbol (not square, wrong dimension, inconsistent storage).
      def module_bits(matrix)
        raise TypeError, "expected a QrReader::BitMatrix, got #{matrix.class}" unless matrix.is_a?(BitMatrix)

        n = matrix.width
        bits = matrix.bits
        return nil unless bits.is_a?(String) && matrix.height == n && SymbolVersion.for_dimension(n) &&
                          bits.bytesize == n * n

        # Byte-wise operations below need a binary String (the BitMatrix
        # constructor ensures one, but the String is mutable).
        bits = bits.b unless bits.encoding == Encoding::BINARY
        # Any byte other than 1 counts as light (like BitMatrix#dark?).
        bits.count("\x00\x01") == bits.bytesize ? bits : bits.tr("^\x01", "\x00")
      end

      # One decoding pass in one orientation, given the format information
      # words read for it and their decoding ([FormatInformation, distance]
      # or nil). Returns a Result or nil; fills +diag+ if given.
      def attempt(bits, n, mirrored, format_words, format, diag)
        version = SymbolVersion.for_dimension(n)
        diag&.merge!(dimension: n, version: version.number, format_bits: format_words)
        return failure(diag, :format_info) unless format

        info, distance = format
        level = info.ec_level
        mask = info.mask
        diag&.merge!(ec_level: level, mask: mask, format_distance: distance)
        return failure(diag, :version_info) unless version_info_consistent?(bits, n, version, mirrored, diag)

        data, corrected = correct_blocks(bits, version, level, mask, mirrored, diag)
        return failure(diag, :reed_solomon) unless data

        content = begin
          BitstreamParser.parse(data, version.number)
        rescue FormatError => e
          diag[:error] = e.message if diag
          return failure(diag, :bitstream)
        end

        result = Result.new(text: content.text, raw_bytes: content.bytes, version: version.number, ec_level: level.downcase,
                            mask: mask, mirrored: mirrored, errors_corrected: corrected, eci: content.eci,
                            fnc1: content.fnc1, structured_append: content.structured_append,
                            symbology_identifier: content.symbology_identifier, segments: content.segments)
        diag&.merge!(status: :ok, result: result)
        result
      end

      def failure(diag, status)
        diag[:status] = status if diag
        nil
      end

      # Versions 7+ carry their version number twice. Accept if either copy
      # names the version implied by the dimension, or if neither copy can be
      # read (fall back to the dimension); reject if a copy reads as a
      # different version - the grid was most likely sampled at the wrong size.
      def version_info_consistent?(bits, n, version, mirrored, diag)
        return true if version.number < 7

        copies = FormatReader.version_bits(bits, n, mirrored)
        expected = version.version_info_bits
        diag[:version_bits] = copies if diag
        return true if copies.include?(expected) && !diag

        decoded = copies.map { |word| FormatReader.decode_version(word) }
        diag[:version_info] = decoded if diag
        decoded.include?(version.number) || decoded.none?
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
        data = String.new(capacity: version.total_codewords, encoding: Encoding::BINARY)
        corrected = 0
        block_errors = diag ? [] : nil
        failed = false
        blocks.each do |data_count, indices|
          codewords = Codewords.read_block(bits, order, mask_codewords, indices)
          fixed = ReedSolomon.decode(codewords, ec_count)
          block_errors << fixed if diag
          unless fixed
            return nil unless diag

            failed = true
            next
          end
          corrected += fixed
          codewords.pack(DATA_FORMATS[data_count], buffer: data)
        end
        diag&.merge!(blocks: blocks.size, block_errors: block_errors, errors_corrected: failed ? nil : corrected)
        failed ? nil : [data, corrected]
      end
    end
  end
end
