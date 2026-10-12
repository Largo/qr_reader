# frozen_string_literal: true

module QrReader
  # The 15-bit format information word: error correction level + mask pattern,
  # protected by a BCH(15,5) code and XOR-masked with 0x5412.
  class FormatInformation
    MASK = 0x5412
    GENERATOR = 0x537

    attr_reader :ec_level, :mask, :bits

    def initialize(data_bits)
      @ec_level = SymbolVersion::EC_LEVEL_FOR_BITS[(data_bits >> 3) & 0x03]
      @mask = data_bits & 0x07
      @bits = self.class.encode(data_bits)
      freeze
    end

    def ==(other)
      other.is_a?(FormatInformation) && other.bits == bits
    end
    alias eql? ==

    def hash
      bits.hash
    end

    def inspect
      "#<QrReader::FormatInformation ec=#{@ec_level} mask=#{@mask}>"
    end

    class << self
      # 15-bit masked code word for 5 data bits (2 EC level bits + 3 mask bits).
      def encode(data_bits)
        rem = data_bits
        10.times { rem = (rem << 1) ^ ((rem >> 9) * GENERATOR) }
        ((data_bits << 10) | rem) ^ MASK
      end

      # Decodes the two 15-bit copies read from a symbol (pass the same value
      # twice when only one copy is available). Returns the FormatInformation
      # closest in Hamming distance to either copy if that distance is <= 3,
      # else nil. Also accepts copies that lack the 0x5412 XOR mask, as
      # written by some broken encoders.
      def decode(bits1, bits2 = bits1)
        closest(bits1, bits2) || closest(bits1 ^ MASK, bits2 ^ MASK)
      end

      def closest(bits1, bits2)
        best = nil
        best_distance = 4
        ALL.each do |info|
          code = info.bits
          return info if code == bits1 || code == bits2

          distance = popcount(bits1 ^ code)
          d2 = popcount(bits2 ^ code)
          distance = d2 if d2 < distance
          if distance < best_distance
            best = info
            best_distance = distance
          end
        end
        best
      end

      def popcount(value)
        count = 0
        while value != 0
          value &= value - 1
          count += 1
        end
        count
      end
    end

    ALL = (0..31).map { |d| new(d) }.freeze
  end
end
