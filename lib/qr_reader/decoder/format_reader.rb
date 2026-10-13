# frozen_string_literal: true

module QrReader
  module Decoder
    # Reads the format information (EC level + mask) and version information
    # words from a module grid. Bit order is exactly that of ISO/IEC 18004
    # §7.9/§7.10 as implemented by ZXing's BitMatrixParser: the first module
    # read becomes the most significant bit.
    #
    # +bits+ is the symbol's module String (0/1 bytes, row-major), +n+ its
    # dimension. With +mirrored+ the symbol is read transposed.
    module FormatReader
      # Copy 1 around the top-left finder, as [x, y].
      FORMAT_COPY1 = [[0, 8], [1, 8], [2, 8], [3, 8], [4, 8], [5, 8], [7, 8], [8, 8],
                      [8, 7], [8, 5], [8, 4], [8, 3], [8, 2], [8, 1], [8, 0]].freeze

      # Version information code words for versions 7..40.
      VERSION_CODES = (7..40).map { |v| SymbolVersion[v].version_info_bits }.freeze
      POPCOUNT9 = Array.new(512) { |i| i.to_s(2).count("1") }.freeze
      NO_CANDIDATES = [].freeze
      private_constant :POPCOUNT9, :NO_CANDIDATES

      @format_table = nil
      @positions = {}

      class << self
        # The two 15-bit format information words [copy1, copy2]. Copy 2 runs
        # up column 8 from the bottom-left corner (7 modules, above them is the
        # dark module), then along row 8 to the right edge (8 modules).
        def format_bits(bits, n, mirrored: false)
          copy1, copy2 = positions(n, mirrored)
          [read_word(bits, copy1), read_word(bits, copy2)]
        end

        # The two 18-bit version information words [top_right, bottom_left].
        def version_bits(bits, n, mirrored: false)
          top_right, bottom_left = positions(n, mirrored)[2]
          [read_word(bits, top_right), read_word(bits, bottom_left)]
        end

        # Decodes the two format words like FormatInformation.decode (nearest
        # code word within Hamming distance 3 of either copy, ties to the lower
        # code; then the same for copies lacking the 0x5412 mask), but with one
        # Array lookup per word. Returns [FormatInformation, distance] or nil.
        def decode_format(copy1, copy2)
          table = format_table
          mask = FormatInformation::MASK
          entry = closer(table[copy1 & 0x7FFF], table[copy2 & 0x7FFF]) ||
                  closer(table[(copy1 ^ mask) & 0x7FFF], table[(copy2 ^ mask) & 0x7FFF])
          entry && [FormatInformation::ALL[entry >> 2], entry & 3]
        end

        # Every format information worth trying for the two copies, most
        # likely first: Array of up to two [FormatInformation, distance].
        #
        # Each copy proposes the code word within Hamming distance 3 of it
        # (as in #decode_format, masked code words first, then copies lacking
        # the 0x5412 mask). When the copies propose different code words, the
        # one needing fewer bit errors in both copies together goes first
        # (ties: the smaller distance of a single copy, then the lower code):
        # ranking by one copy alone picks the wrong one when both copies are
        # damaged, and trying the runner-up rescues the symbol when it is.
        # +distance+ is the smaller distance of the two copies.
        def format_candidates(copy1, copy2)
          table = format_table
          copy1 &= 0x7FFF
          copy2 &= 0x7FFF
          a = table[copy1]
          b = table[copy2]
          unless a || b
            mask = FormatInformation::MASK
            copy1 ^= mask
            copy2 ^= mask
            a = table[copy1]
            b = table[copy2]
            return NO_CANDIDATES unless a || b
          end
          return [candidate(a, copy2)] unless b
          return [candidate(b, copy1)] if a.nil? || a >> 2 == b >> 2

          first = candidate(a, copy2)
          second = candidate(b, copy1)
          first_rank = [(a & 3) + popcount15(copy2 ^ first[0].bits), a & 3, a >> 2]
          second_rank = [(b & 3) + popcount15(copy1 ^ second[0].bits), b & 3, b >> 2]
          (second_rank <=> first_rank).negative? ? [second, first] : [first, second]
        end

        # Version number (7..40) whose code word is nearest to the 18-bit
        # +word+ within Hamming distance 3 (ties to the lower version), or nil.
        # Same result as SymbolVersion.decode_version_info, without allocation.
        def decode_version(word)
          best = nil
          best_distance = 4
          i = 0
          while i < 34
            x = VERSION_CODES[i] ^ word
            return i + 7 if x.zero?

            distance = POPCOUNT9[x & 511] + POPCOUNT9[(x >> 9) & 511]
            if distance < best_distance
              best = i + 7
              best_distance = distance
            end
            i += 1
          end
          best
        end

        private

        # Word made of the modules at +indices+, first index = most significant bit.
        def read_word(bits, indices)
          word = 0
          i = 0
          count = indices.size
          while i < count
            word = (word << 1) | bits.getbyte(indices[i])
            i += 1
          end
          word
        end

        # Module String indices, in reading order, of format copy 1, format
        # copy 2 and the two version information blocks for dimension +n+,
        # cached per dimension and orientation.
        def positions(n, mirrored)
          @positions[mirrored ? -n : n] ||= begin
            index = mirrored ? ->(x, y) { x * n + y } : ->(x, y) { y * n + x }
            copy2 = (n - 1).downto(n - 7).map { |y| [8, y] } + (n - 8).upto(n - 1).map { |x| [x, 8] }
            top_right = 5.downto(0).flat_map { |y| (n - 9).downto(n - 11).map { |x| [x, y] } }
            bottom_left = 5.downto(0).flat_map { |x| (n - 9).downto(n - 11).map { |y| [x, y] } }
            words = [FORMAT_COPY1, copy2, top_right, bottom_left].map do |coords|
              coords.map { |x, y| index.call(x, y) }.freeze
            end
            [words[0], words[1], words[2, 2].freeze].freeze
          end
        end

        # [FormatInformation, distance] for a format table +entry+ proposed by
        # one copy; +other+ is the other copy (it may be closer).
        def candidate(entry, other)
          info = FormatInformation::ALL[entry >> 2]
          distance = entry & 3
          other_distance = popcount15(other ^ info.bits)
          [info, other_distance < distance ? other_distance : distance]
        end

        def popcount15(word)
          POPCOUNT9[word & 511] + POPCOUNT9[word >> 9]
        end

        def closer(a, b)
          return b unless a
          return a unless b

          da = a & 3
          db = b & 3
          return a if da < db
          return b if db < da

          a < b ? a : b
        end

        def format_table
          @format_table ||= build_format_table
        end

        # 32768 entries: (format data bits << 2 | distance) for every 15-bit
        # word within distance 3 of a format code word, else nil. The code has
        # minimum distance 7, so these neighbourhoods never overlap. (Plain
        # loops in a method that runs once: YJIT would spend more time
        # compiling blocks here than running them.)
        def build_format_table
          table = Array.new(1 << 15)
          data = 0
          while data < 32
            code = FormatInformation::ALL[data].bits
            base = data << 2
            table[code] = base
            a = 0
            while a < 15
              one = code ^ (1 << a)
              table[one] = base | 1
              b = 0
              while b < a
                two = one ^ (1 << b)
                table[two] = base | 2
                c = 0
                while c < b
                  table[two ^ (1 << c)] = base | 3
                  c += 1
                end
                b += 1
              end
              a += 1
            end
            data += 1
          end
          table.freeze
        end
      end
    end
  end
end
