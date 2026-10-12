# frozen_string_literal: true

module QrReader
  # Static properties of a QR Code Model 2 symbol version (1..40):
  # dimension, alignment pattern centres, error correction block layout and
  # the 18-bit version information word (versions 7+).
  class SymbolVersion
    # Error correction levels in the order of their 2-bit format code.
    # Format bits: L = 01, M = 00, Q = 11, H = 10.
    EC_LEVELS = %i[L M Q H].freeze
    EC_LEVEL_FOR_BITS = %i[M L H Q].freeze # index = 2-bit value from format info

    # Per version, per level (L, M, Q, H):
    #   [ec_codewords_per_block, count1, data_codewords1, count2, data_codewords2]
    # (count2 / data_codewords2 are 0 when there is a single block group).
    EC_TABLE = [
      nil,
      [[7, 1, 19, 0, 0], [10, 1, 16, 0, 0], [13, 1, 13, 0, 0], [17, 1, 9, 0, 0]],
      [[10, 1, 34, 0, 0], [16, 1, 28, 0, 0], [22, 1, 22, 0, 0], [28, 1, 16, 0, 0]],
      [[15, 1, 55, 0, 0], [26, 1, 44, 0, 0], [18, 2, 17, 0, 0], [22, 2, 13, 0, 0]],
      [[20, 1, 80, 0, 0], [18, 2, 32, 0, 0], [26, 2, 24, 0, 0], [16, 4, 9, 0, 0]],
      [[26, 1, 108, 0, 0], [24, 2, 43, 0, 0], [18, 2, 15, 2, 16], [22, 2, 11, 2, 12]],
      [[18, 2, 68, 0, 0], [16, 4, 27, 0, 0], [24, 4, 19, 0, 0], [28, 4, 15, 0, 0]],
      [[20, 2, 78, 0, 0], [18, 4, 31, 0, 0], [18, 2, 14, 4, 15], [26, 4, 13, 1, 14]],
      [[24, 2, 97, 0, 0], [22, 2, 38, 2, 39], [22, 4, 18, 2, 19], [26, 4, 14, 2, 15]],
      [[30, 2, 116, 0, 0], [22, 3, 36, 2, 37], [20, 4, 16, 4, 17], [24, 4, 12, 4, 13]],
      [[18, 2, 68, 2, 69], [26, 4, 43, 1, 44], [24, 6, 19, 2, 20], [28, 6, 15, 2, 16]],
      [[20, 4, 81, 0, 0], [30, 1, 50, 4, 51], [28, 4, 22, 4, 23], [24, 3, 12, 8, 13]],
      [[24, 2, 92, 2, 93], [22, 6, 36, 2, 37], [26, 4, 20, 6, 21], [28, 7, 14, 4, 15]],
      [[26, 4, 107, 0, 0], [22, 8, 37, 1, 38], [24, 8, 20, 4, 21], [22, 12, 11, 4, 12]],
      [[30, 3, 115, 1, 116], [24, 4, 40, 5, 41], [20, 11, 16, 5, 17], [24, 11, 12, 5, 13]],
      [[22, 5, 87, 1, 88], [24, 5, 41, 5, 42], [30, 5, 24, 7, 25], [24, 11, 12, 7, 13]],
      [[24, 5, 98, 1, 99], [28, 7, 45, 3, 46], [24, 15, 19, 2, 20], [30, 3, 15, 13, 16]],
      [[28, 1, 107, 5, 108], [28, 10, 46, 1, 47], [28, 1, 22, 15, 23], [28, 2, 14, 17, 15]],
      [[30, 5, 120, 1, 121], [26, 9, 43, 4, 44], [28, 17, 22, 1, 23], [28, 2, 14, 19, 15]],
      [[28, 3, 113, 4, 114], [26, 3, 44, 11, 45], [26, 17, 21, 4, 22], [26, 9, 13, 16, 14]],
      [[28, 3, 107, 5, 108], [26, 3, 41, 13, 42], [30, 15, 24, 5, 25], [28, 15, 15, 10, 16]],
      [[28, 4, 116, 4, 117], [26, 17, 42, 0, 0], [28, 17, 22, 6, 23], [30, 19, 16, 6, 17]],
      [[28, 2, 111, 7, 112], [28, 17, 46, 0, 0], [30, 7, 24, 16, 25], [24, 34, 13, 0, 0]],
      [[30, 4, 121, 5, 122], [28, 4, 47, 14, 48], [30, 11, 24, 14, 25], [30, 16, 15, 14, 16]],
      [[30, 6, 117, 4, 118], [28, 6, 45, 14, 46], [30, 11, 24, 16, 25], [30, 30, 16, 2, 17]],
      [[26, 8, 106, 4, 107], [28, 8, 47, 13, 48], [30, 7, 24, 22, 25], [30, 22, 15, 13, 16]],
      [[28, 10, 114, 2, 115], [28, 19, 46, 4, 47], [28, 28, 22, 6, 23], [30, 33, 16, 4, 17]],
      [[30, 8, 122, 4, 123], [28, 22, 45, 3, 46], [30, 8, 23, 26, 24], [30, 12, 15, 28, 16]],
      [[30, 3, 117, 10, 118], [28, 3, 45, 23, 46], [30, 4, 24, 31, 25], [30, 11, 15, 31, 16]],
      [[30, 7, 116, 7, 117], [28, 21, 45, 7, 46], [30, 1, 23, 37, 24], [30, 19, 15, 26, 16]],
      [[30, 5, 115, 10, 116], [28, 19, 47, 10, 48], [30, 15, 24, 25, 25], [30, 23, 15, 25, 16]],
      [[30, 13, 115, 3, 116], [28, 2, 46, 29, 47], [30, 42, 24, 1, 25], [30, 23, 15, 28, 16]],
      [[30, 17, 115, 0, 0], [28, 10, 46, 23, 47], [30, 10, 24, 35, 25], [30, 19, 15, 35, 16]],
      [[30, 17, 115, 1, 116], [28, 14, 46, 21, 47], [30, 29, 24, 19, 25], [30, 11, 15, 46, 16]],
      [[30, 13, 115, 6, 116], [28, 14, 46, 23, 47], [30, 44, 24, 7, 25], [30, 59, 16, 1, 17]],
      [[30, 12, 121, 7, 122], [28, 12, 47, 26, 48], [30, 39, 24, 14, 25], [30, 22, 15, 41, 16]],
      [[30, 6, 121, 14, 122], [28, 6, 47, 34, 48], [30, 46, 24, 10, 25], [30, 2, 15, 64, 16]],
      [[30, 17, 122, 4, 123], [28, 29, 46, 14, 47], [30, 49, 24, 10, 25], [30, 24, 15, 46, 16]],
      [[30, 4, 122, 18, 123], [28, 13, 46, 32, 47], [30, 48, 24, 14, 25], [30, 42, 15, 32, 16]],
      [[30, 20, 117, 4, 118], [28, 40, 47, 7, 48], [30, 43, 24, 22, 25], [30, 10, 15, 67, 16]],
      [[30, 19, 118, 6, 119], [28, 18, 47, 31, 48], [30, 34, 24, 34, 25], [30, 20, 15, 61, 16]]
    ].freeze

    VERSION_INFO_GENERATOR = 0x1F25

    # Error correction block layout for one level of one version.
    EcBlocks = Struct.new(:ec_codewords_per_block, :groups) do
      # Array of data codeword counts, one entry per block, in transmission order.
      def data_codewords_per_block
        groups.flat_map { |count, data| [data] * count }
      end

      def block_count
        groups.sum { |count, _| count }
      end

      def total_data_codewords
        groups.sum { |count, data| count * data }
      end
    end

    attr_reader :number, :dimension, :alignment_centers, :total_codewords, :version_info_bits

    def initialize(number)
      @number = number
      @dimension = 17 + 4 * number
      @alignment_centers = self.class.compute_alignment_centers(number).freeze
      @ec_blocks = EC_TABLE[number].map do |ec, c1, d1, c2, d2|
        groups = [[c1, d1]]
        groups << [c2, d2] if c2.positive?
        EcBlocks.new(ec, groups.freeze).freeze
      end.freeze
      @total_codewords = self.class.raw_data_modules(number) / 8
      @version_info_bits = number >= 7 ? self.class.encode_version_info(number) : nil
      freeze
    end

    # EcBlocks for the given level (:L, :M, :Q, :H).
    def ec_blocks(level)
      @ec_blocks[EC_LEVELS.index(level) || raise(ArgumentError, "unknown EC level #{level.inspect}")]
    end

    def data_codewords(level)
      ec_blocks(level).total_data_codewords
    end

    def inspect
      "#<QrReader::SymbolVersion #{@number} (#{@dimension}x#{@dimension})>"
    end
    alias to_s inspect

    class << self
      # Version for a number in 1..40, or nil.
      def [](number)
        ALL[number - 1] if number.is_a?(Integer) && number.between?(1, 40)
      end

      # Version for a symbol dimension (21, 25, ... 177), or nil when the
      # dimension is not 1 mod 4 or out of range.
      def for_dimension(dimension)
        return nil unless (dimension % 4) == 1

        self[(dimension - 17) / 4]
      end

      # Decodes an 18-bit version information word read from the symbol.
      # Returns the version whose code word is closest in Hamming distance,
      # provided the distance is at most 3, else nil.
      def decode_version_info(bits)
        best = nil
        best_distance = 4
        7.upto(40) do |v|
          code = ALL[v - 1].version_info_bits
          return ALL[v - 1] if code == bits

          distance = (code ^ bits).digits(2).sum
          if distance < best_distance
            best = ALL[v - 1]
            best_distance = distance
          end
        end
        best
      end

      # Alignment pattern centre coordinates (same for rows and columns).
      def compute_alignment_centers(version)
        return [] if version == 1

        count = version / 7 + 2
        last = 17 + 4 * version - 7
        step = version == 32 ? 26 : (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2
        result = [6]
        (count - 1).times { |i| result.insert(1, last - i * step) }
        result
      end

      # Number of modules available for data + EC codewords (incl. remainder bits).
      def raw_data_modules(version)
        result = (16 * version + 128) * version + 64
        if version >= 2
          align = version / 7 + 2
          result -= (25 * align - 10) * align - 55
          result -= 36 if version >= 7
        end
        result
      end

      def encode_version_info(version)
        rem = version
        12.times { rem = (rem << 1) ^ ((rem >> 11) * VERSION_INFO_GENERATOR) }
        (version << 12) | rem
      end
    end

    ALL = (1..40).map { |n| new(n) }.freeze
  end
end
