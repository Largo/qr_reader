# frozen_string_literal: true

module QrReader
  module Decoder
    # Reed-Solomon error correction for QR code blocks over GF(256) (0x11D).
    #
    # The generator polynomial of an EC block with +ec+ codewords has the roots
    # alpha**0 .. alpha**(ec-1). Decoding computes the syndromes, finds the
    # error locator with Berlekamp-Massey, its roots with a Chien search and the
    # error values with Forney's formula, then re-checks the syndromes of the
    # corrected block. At most floor(ec/2) errors are corrected; anything that
    # does not lead to a verified codeword is rejected.
    #
    # Polynomials are Arrays of coefficients; a block's codewords[0] is the
    # coefficient of x**(n-1), so codeword i sits at "degree position" n-1-i.
    module ReedSolomon
      EXP = GaloisField::EXP
      LOG = GaloisField::LOG
      MULTIPLY_BY_ALPHA_POWER = GaloisField::MULTIPLY_BY_ALPHA_POWER

      module_function

      # Corrects +codewords+ (Array of Integers 0..255, data followed by EC
      # codewords, first element = highest-degree coefficient) in place.
      # Returns the number of corrected codewords, or nil when the block is
      # uncorrectable (the Array is then left unchanged).
      def decode(codewords, ec_count)
        n = codewords.size
        return nil if ec_count < 1 || ec_count >= n || n > 255 || ec_count >= MULTIPLY_BY_ALPHA_POWER.size

        syndromes = syndromes(codewords, ec_count)
        return 0 unless syndromes

        locator = berlekamp_massey(syndromes)
        errors = locator.size - 1
        return nil if errors.zero? || 2 * errors > ec_count

        positions = chien_search(locator, n)
        return nil unless positions

        magnitudes = forney(syndromes, locator, positions)
        return nil unless magnitudes && corrects_syndromes?(syndromes, positions, magnitudes)

        positions.each_with_index { |e, k| codewords[n - 1 - e] ^= magnitudes[k] }
        errors
      end

      # Syndromes S_j = r(alpha**j) for j = 0...ec_count, or nil when all are
      # zero (the block is a valid codeword). This is the hot path for clean
      # symbols, so the cheaper of two equivalent methods is used: with a JIT,
      # Horner's rule over all codewords (allocation-free table lookups);
      # in the plain interpreter, the remainder r(x) mod g(x) computed with
      # one Bignum step per codeword, whose syndromes are those of r(x)
      # because g(alpha**j) = 0 (about 3x faster there).
      def syndromes(codewords, ec_count)
        jit? ? horner_syndromes(codewords, ec_count) : remainder_syndromes(codewords, ec_count)
      end

      # Syndromes by Horner's rule: one lookup and one XOR per codeword and
      # syndrome. Four syndromes share each pass over the codewords, which
      # roughly halves the loop overhead.
      def horner_syndromes(codewords, ec_count)
        n = codewords.size
        result = nil
        j = 0
        while j + 4 <= ec_count
          t0 = MULTIPLY_BY_ALPHA_POWER[j]
          t1 = MULTIPLY_BY_ALPHA_POWER[j + 1]
          t2 = MULTIPLY_BY_ALPHA_POWER[j + 2]
          t3 = MULTIPLY_BY_ALPHA_POWER[j + 3]
          s0 = s1 = s2 = s3 = 0
          i = 0
          while i < n
            c = codewords[i]
            s0 = t0[s0] ^ c
            s1 = t1[s1] ^ c
            s2 = t2[s2] ^ c
            s3 = t3[s3] ^ c
            i += 1
          end
          if (s0 | s1 | s2 | s3) != 0
            result ||= Array.new(ec_count, 0)
            result[j] = s0
            result[j + 1] = s1
            result[j + 2] = s2
            result[j + 3] = s3
          end
          j += 4
        end
        while j < ec_count
          table = MULTIPLY_BY_ALPHA_POWER[j]
          s = 0
          i = 0
          while i < n
            s = table[s] ^ codewords[i]
            i += 1
          end
          if s != 0
            result ||= Array.new(ec_count, 0)
            result[j] = s
          end
          j += 1
        end
        result
      end

      # Syndromes via the remainder r(x) mod g(x), kept as an Integer of
      # ec_count bytes (coefficient of x**(ec-1) in the top byte).
      def remainder_syndromes(codewords, ec_count)
        table = remainder_table(ec_count)
        shift = 8 * (ec_count - 1)
        r = 0
        i = 0
        n = codewords.size
        while i < n
          r = ((r << 8) | codewords[i]) ^ table[r >> shift]
          i += 1
        end
        return nil if r.zero?

        horner_syndromes([r.to_s(16).rjust(2 * ec_count, "0")].pack("H*").bytes, ec_count)
      end

      # True when running under a JIT compiler (or a non-CRuby VM).
      def jit?
        return true unless RUBY_ENGINE == "ruby"

        yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
        zjit = defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?
        yjit || zjit ? true : false
      end

      @remainder_tables = []

      # remainder_table(ec)[b] = b * g(x) as an Integer of ec + 1 bytes, where
      # g(x) = (x - alpha**0) ... (x - alpha**(ec-1)) is the monic generator.
      # The map b -> b * g(x) is GF(2)-linear, so only the eight single-bit
      # rows need field multiplications; the others are XORs of those.
      def remainder_table(ec_count)
        @remainder_tables[ec_count] ||= begin
          generator = [1]
          ec_count.times do |i|
            next_generator = generator + [0]
            generator.each_with_index { |c, k| next_generator[k + 1] ^= GaloisField.multiply(c, EXP[i]) }
            generator = next_generator
          end
          table = Array.new(256, 0)
          8.times do |bit|
            b = 1 << bit
            table[b] = generator.inject(0) { |acc, c| (acc << 8) | GaloisField.multiply(b, c) }
          end
          b = 1
          while b < 256
            low = b & -b # lowest set bit; table[b ^ low] is already filled
            table[b] = table[low] ^ table[b ^ low] unless b == low
            b += 1
          end
          table.freeze
        end
      end

      # Error locator polynomial Lambda (coefficients, Lambda[0] = 1) of the
      # shortest LFSR generating the syndrome sequence. Its length - 1 is the
      # number of errors assumed (its degree).
      def berlekamp_massey(syndromes)
        mul = GaloisField.multiplication_table
        current = [1]
        previous = [1]
        length = 0
        shift = 1
        previous_discrepancy = 1
        count = syndromes.size
        n = 0
        while n < count
          d = syndromes[n]
          i = 1
          while i <= length
            d ^= mul[current[i]][syndromes[n - i]]
            i += 1
          end
          if d.zero?
            shift += 1
          else
            row = mul[EXP[LOG[d] + 255 - LOG[previous_discrepancy]]] # d / previous_discrepancy
            replaced = 2 * length <= n ? current.dup : nil
            size = previous.size
            current << 0 while current.size < size + shift
            k = 0
            while k < size
              current[k + shift] ^= row[previous[k]]
              k += 1
            end
            if replaced
              length = n + 1 - length
              previous = replaced
              previous_discrepancy = d
              shift = 1
            else
              shift += 1
            end
          end
          n += 1
        end
        current.pop while current.size > length + 1
        current << 0 while current.size < length + 1 # degree below length: no valid locator
        current
      end

      # Degree positions e (0...n) of the errors: the e with
      # Lambda(alpha**-e) == 0, by Horner evaluation. Returns nil unless
      # exactly deg(Lambda) roots lie inside the block.
      def chien_search(locator, n)
        mul = GaloisField.multiplication_table
        errors = locator.size - 1
        return nil if locator[errors].zero?

        roots = []
        e = 0
        while e < n
          row = mul[EXP[255 - e]] # x = alpha**-e
          s = locator[errors]
          k = errors - 1
          while k >= 0
            s = row[s] ^ locator[k]
            k -= 1
          end
          if s.zero?
            roots << e
            return roots if roots.size == errors
          end
          e += 1
        end
        nil
      end

      # Error values by Forney's formula (first consecutive root alpha**0):
      # e_k = X_k * Omega(X_k^-1) / Lambda'(X_k^-1), Omega = S * Lambda mod x^v.
      # Returns nil if a value comes out as zero (no valid correction).
      def forney(syndromes, locator, positions)
        mul = GaloisField.multiplication_table
        errors = locator.size - 1
        omega = Array.new(errors, 0)
        i = 0
        while i < errors
          v = 0
          k = 0
          while k <= i
            v ^= mul[locator[k]][syndromes[i - k]]
            k += 1
          end
          omega[i] = v
          i += 1
        end

        count = positions.size
        magnitudes = Array.new(count)
        p = 0
        while p < count
          e = positions[p]
          x_inverse = EXP[255 - e]
          row = mul[x_inverse]
          numerator = omega[errors - 1]
          i = errors - 2
          while i >= 0
            numerator = row[numerator] ^ omega[i]
            i -= 1
          end
          # Lambda'(x) has only the odd-degree terms (characteristic 2).
          x_squared = row[x_inverse]
          denominator = 0
          power = 1
          k = 1
          while k <= errors
            denominator ^= mul[locator[k]][power]
            power = mul[power][x_squared]
            k += 2
          end
          return nil if numerator.zero? || denominator.zero?

          magnitudes[p] = EXP[(e + LOG[numerator] + 255 - LOG[denominator]) % 255]
          p += 1
        end
        magnitudes
      end

      # True if subtracting the error values at the positions zeroes every
      # syndrome, i.e. the corrected block is a codeword.
      def corrects_syndromes?(syndromes, positions, magnitudes)
        mul = GaloisField.multiplication_table
        count = positions.size
        locators = Array.new(count) { |k| EXP[positions[k]] }
        terms = magnitudes.dup # magnitude_k * X_k**j, starting at j = 0
        j = 0
        ec_count = syndromes.size
        while j < ec_count
          s = syndromes[j]
          k = 0
          while k < count
            term = terms[k]
            s ^= term
            terms[k] = mul[term][locators[k]]
            k += 1
          end
          return false unless s.zero?

          j += 1
        end
        true
      end
    end
  end
end
