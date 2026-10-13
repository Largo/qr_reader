# frozen_string_literal: true

module QrReader
  module Decoder
    # Arithmetic in GF(256) as used by QR codes: field polynomial
    # x^8 + x^4 + x^3 + x^2 + 1 (0x11D), primitive element alpha = 2.
    # Addition is XOR; multiplication goes through log/antilog tables.
    module GaloisField
      PRIMITIVE = 0x11D

      exp = Array.new(512, 0)
      log = Array.new(256, 0)
      x = 1
      255.times do |i|
        exp[i] = x
        log[x] = i
        x <<= 1
        x ^= PRIMITIVE if x > 255
      end
      255.upto(511) { |i| exp[i] = exp[i - 255] }

      # EXP[i] = alpha**i for 0 <= i < 512. Doubled in length so that
      # EXP[LOG[a] + LOG[b]] needs no modulo.
      EXP = exp.freeze
      # LOG[a] = discrete log of a (1..255). LOG[0] is undefined (stored as 0).
      LOG = log.freeze

      # MULTIPLY_BY_ALPHA_POWER[j][s] = s * alpha**j, for j < 31 (enough for the
      # largest QR block's 30 error correction codewords). Lets a syndrome
      # Horner step be one Array lookup: s = table[s] ^ codeword.
      MULTIPLY_BY_ALPHA_POWER = Array.new(31) do |j|
        Array.new(256) { |s| s.zero? ? 0 : exp[log[s] + j] }.freeze
      end.freeze

      @multiplication_table = nil

      # Full multiplication table: multiplication_table[a][b] = a * b. Built on
      # first use because only error correction needs it. Row a is EXP
      # shifted by LOG[a] and permuted by LOG, gathered at C speed.
      def self.multiplication_table
        @multiplication_table ||= begin
          logs = LOG[1, 255]
          zero = Array.new(256, 0).freeze
          Array.new(256) do |a|
            next zero if a.zero?

            EXP[LOG[a], 255].values_at(*logs).unshift(0).freeze
          end.freeze
        end
      end

      module_function

      def multiply(a, b)
        a.zero? || b.zero? ? 0 : EXP[LOG[a] + LOG[b]]
      end

      # a / b for b != 0.
      def divide(a, b)
        a.zero? ? 0 : EXP[LOG[a] + 255 - LOG[b]]
      end

      # alpha**power for any integer power (negative allowed).
      def power(power)
        EXP[power % 255]
      end
    end
  end
end
