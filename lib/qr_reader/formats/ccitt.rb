# frozen_string_literal: true

module QrReader
  module Formats
    # CCITT fax decoder: Group 3 (ITU-T T.4: 1-D Modified Huffman and 2-D
    # Modified READ) and Group 4 (T.6, MMR), the bilevel codings that scanners
    # and fax machines write into TIFF files (compression 2, 3 and 4) and PDFs
    # embed as CCITTFaxDecode streams.
    #
    #   CCITT.decode(g4_data, columns: 2480, rows: 3508)     # => #<QrReader::Image 2480x3508>
    #   CCITT.decode(g3_data, columns: 1728, k: 0)           # rows until RTC / end of data
    #
    # Parameters follow PDF's CCITTFaxDecode filter:
    # * +k+ < 0: Group 4; 0: Group 3 1-D; > 0: Group 3 2-D (each row's tag
    #   bit selects 1-D or 2-D coding).
    # * +rows+ nil or 0: decode until EOFB / RTC or the end of the data.
    #   Missing rows (truncated data) are white.
    # * +black_is_1+ false: coded white is 255 and coded black 0 (what a PDF
    #   shows with the default Decode array); true inverts the image (also
    #   what TIFF's BlackIsZero photometric means for fax data).
    # * +encoded_byte_align+: every row starts on a byte boundary (TIFF
    #   compression 2 rows, PDF EncodedByteAlign).
    # * +fill_order+ 2: bits are stored least significant first (TIFF FillOrder).
    # * +end_of_line+: EOL codes precede the rows. EOLs, fill bits before
    #   them and EOFB/RTC are recognised either way, so the flag only
    #   decides whether an unaligned EOL may stand before a byte-aligned row.
    # * +end_of_block+ and +damaged_rows_before_error+ are accepted for PDF
    #   compatibility. Decoding is always lenient: rows stop at EOFB/RTC or
    #   after +rows+ rows, and damaged rows never raise.
    #
    # Damaged rows of EOL-delimited (Group 3) data are replaced by the row
    # above and decoding resumes at the next EOL. Group 4 cannot
    # resynchronise, so an error ends the image there (the rest stays
    # white). Only data in which not even the first row decodes raises
    # ImageError. Uncompressed-mode extensions count as damage.
    #
    # Speed: codes are looked up in tables indexed by the next 13 (runs) or
    # 7 (2-D modes) bits, read from two adjacent 16-bit words of the data
    # (unpacked once); changing elements live in Integer arrays and rows are
    # painted with String#bytesplice (C memcpy) runs; rows equal to the row
    # above are appended as a whole.
    module CCITT
      # Terminating codes for run lengths 0..63.
      WHITE_TERMINATING = %w[
        00110101 000111 0111 1000 1011 1100 1110 1111 10011 10100 00111 01000 001000 000011 110100 110101
        101010 101011 0100111 0001100 0001000 0010111 0000011 0000100 0101000 0101011 0010011 0100100
        0011000 00000010 00000011 00011010 00011011 00010010 00010011 00010100 00010101 00010110 00010111
        00101000 00101001 00101010 00101011 00101100 00101101 00000100 00000101 00001010 00001011 01010010
        01010011 01010100 01010101 00100100 00100101 01011000 01011001 01011010 01011011 01001010 01001011
        00110010 00110011 00110100
      ].freeze
      BLACK_TERMINATING = %w[
        0000110111 010 11 10 011 0011 0010 00011 000101 000100 0000100 0000101 0000111 00000100 00000111
        000011000 0000010111 0000011000 0000001000 00001100111 00001101000 00001101100 00000110111
        00000101000 00000010111 00000011000 000011001010 000011001011 000011001100 000011001101
        000001101000 000001101001 000001101010 000001101011 000011010010 000011010011 000011010100
        000011010101 000011010110 000011010111 000001101100 000001101101 000011011010 000011011011
        000001010100 000001010101 000001010110 000001010111 000001100100 000001100101 000001010010
        000001010011 000000100100 000000110111 000000111000 000000100111 000000101000 000001011000
        000001011001 000000101011 000000101100 000001011010 000001100110 000001100111
      ].freeze
      # Make-up codes for run lengths 64, 128, ..., 1728.
      WHITE_MAKEUP = %w[
        11011 10010 010111 0110111 00110110 00110111 01100100 01100101 01101000 01100111 011001100
        011001101 011010010 011010011 011010100 011010101 011010110 011010111 011011000 011011001
        011011010 011011011 010011000 010011001 010011010 011000 010011011
      ].freeze
      BLACK_MAKEUP = %w[
        0000001111 000011001000 000011001001 000001011011 000000110011 000000110100 000000110101
        0000001101100 0000001101101 0000001001010 0000001001011 0000001001100 0000001001101
        0000001110010 0000001110011 0000001110100 0000001110101 0000001110110 0000001110111
        0000001010010 0000001010011 0000001010100 0000001010101 0000001011010 0000001011011
        0000001100100 0000001100101
      ].freeze
      # Extended make-up codes shared by both colours: 1792, 1856, ..., 2560.
      EXTENDED_MAKEUP = %w[
        00000001000 00000001100 00000001101 000000010010 000000010011 000000010100 000000010101
        000000010110 000000010111 000000011100 000000011101 000000011110 000000011111
      ].freeze

      # Bits peeked for a run-length code (the longest code has 13 bits).
      RUN_BITS = 13
      # Bits peeked for a 2-D mode code.
      MODE_BITS = 7

      # 2-D modes. Vertical modes VL3..VR3 are 0..6 (offset a1 - b1 = mode - 3).
      PASS = 7
      HORIZONTAL = 8
      EXTENSION = 9
      ZEROS = 10 # seven zero bits: an EOL (premature here) or garbage

      MODE_CODES = {
        "0000010" => 0, "000010" => 1, "010" => 2, "1" => 3, "011" => 4, "000011" => 5, "0000011" => 6,
        "0001" => PASS, "001" => HORIZONTAL, "0000001" => EXTENSION
      }.freeze

      class << self
        # Decodes a CCITT stream to an Image (see the module documentation
        # for the parameters). end_of_block and damaged_rows_before_error
        # are accepted for PDF compatibility; decoding is always lenient.
        # rubocop:disable Lint/UnusedMethodArgument
        def decode(data, columns:, rows: nil, k: -1, black_is_1: false, encoded_byte_align: false, fill_order: 1,
                   end_of_line: false, end_of_block: true, damaged_rows_before_error: 0)
          raise ImageError, "CCITT data must be a String" unless data.is_a?(String)

          rows = nil if rows.is_a?(Integer) && rows.zero?
          check_size(columns, rows)
          decoder = Decoder.new(data, columns, k: k, byte_align: encoded_byte_align,
                                               end_of_line: end_of_line, fill_order: fill_order)
          out = String.new(capacity: columns * (rows || 64), encoding: Encoding::BINARY)
          count = decoder.decode_into(out, rows, inverted: black_is_1 ? true : false)
          raise ImageError, "corrupt CCITT data (first row undecodable)" if decoder.failed_at_start?
          raise ImageError, "CCITT data contains no rows" if count.zero?

          Image.new(columns, count, out)
        end
        # rubocop:enable Lint/UnusedMethodArgument

        private

        # Lookup table for the next RUN_BITS bits: (run << 4 | code length),
        # or -1 where no code matches (EOL, garbage).
        def run_table(terminating, makeup)
          table = Array.new(1 << RUN_BITS, -1)
          add = lambda do |code, run|
            len = code.size
            start = code.to_i(2) << (RUN_BITS - len)
            table.fill((run << 4) | len, start, 1 << (RUN_BITS - len))
          end
          terminating.each_with_index { |code, run| add.call(code, run) }
          makeup.each_with_index { |code, i| add.call(code, 64 * (i + 1)) }
          EXTENDED_MAKEUP.each_with_index { |code, i| add.call(code, 1792 + 64 * i) }
          table.freeze
        end

        # Lookup table for the next MODE_BITS bits: (mode << 4 | code length).
        def mode_table
          table = Array.new(1 << MODE_BITS, ZEROS << 4)
          MODE_CODES.each do |code, mode|
            len = code.size
            table.fill((mode << 4) | len, code.to_i(2) << (MODE_BITS - len), 1 << (MODE_BITS - len))
          end
          table.freeze
        end

        def check_size(columns, rows)
          unless columns.is_a?(Integer) && columns.positive? && (rows.nil? || (rows.is_a?(Integer) && rows.positive?))
            raise ImageError, "invalid CCITT dimensions #{columns.inspect}x#{rows.inspect}"
          end
          return if columns * (rows || 1) <= MAX_PIXELS

          raise UnsupportedImageError, "CCITT image too large (#{columns}x#{rows}, limit #{MAX_PIXELS} pixels)"
        end
      end

      WHITE_RUNS = run_table(WHITE_TERMINATING, WHITE_MAKEUP)
      BLACK_RUNS = run_table(BLACK_TERMINATING, BLACK_MAKEUP)
      MODES = mode_table

      # Byte -> byte with its bits reversed (FillOrder 2), as String#tr tables.
      REVERSE_FROM = Image::TR_ESCAPE.call((0..255).to_a)
      REVERSE_TO = Image::TR_ESCAPE.call((0..255).map { |b| format("%08b", b).reverse.to_i(2) })

      # EOFB (Group 4) / the start of RTC (Group 3): two EOL codes.
      TWO_EOLS = 0b000000000001_000000000001

      # Row-start results of Decoder#start_row.
      ONE_D = 0
      TWO_D = 1
      DONE = 2

      # String#bytesplice with a source range exists from Ruby 3.3 on.
      SPLICE_RANGE = RUBY_VERSION >= "3.3"

      # Decodes one CCITT stream.
      class Decoder
        NONZERO = /[^\0]/n
        private_constant :NONZERO

        # +data+ is the encoded stream, +columns+ the row width in pixels.
        def initialize(data, columns, k: -1, byte_align: false, end_of_line: false, fill_order: 1)
          data = data.b unless data.encoding == Encoding::BINARY
          data = data.tr(REVERSE_FROM, REVERSE_TO) if fill_order == 2
          @data = data
          @nbits = data.bytesize * 8
          @win = words(data)
          @columns = columns
          @k = k.is_a?(Integer) ? k : -1
          @byte_align = byte_align ? true : false
          @end_of_line = end_of_line ? true : false
          @pos = 0
          @eols = false
          @failed_at_start = false
        end

        # True when the very first row could not be decoded.
        def failed_at_start?
          @failed_at_start
        end

        # Appends decoded rows (+columns+ bytes each) to +out+: exactly
        # +rows+ rows when given (white after the end of the data), else all
        # rows up to the end of the data. Returns the number of rows appended.
        def decode_into(out, rows, inverted: false)
          cols = @columns
          bg = (inverted ? "\x00".b : "\xFF".b) * cols
          fg = (inverted ? "\xFF".b : "\x00".b) * cols
          row = bg.dup
          limit = rows || (MAX_PIXELS / cols)
          ref = Array.new(4, cols)
          cur = []
          count = 0
          while count < limit
            mode = start_row(count.zero?)
            break if mode == DONE

            ok = mode == TWO_D ? decode_2d_row(ref, cur) : decode_1d_row(cur)
            if ok
              cur.push(cols, cols, cols, cols)
            elsif @eols
              # Damaged row: repeat the row above, resume at the next EOL.
              cur.replace(ref)
              @pos = find_eol(@pos)
            else
              # No EOLs to resynchronise at: keep the row's start and stop.
              @failed_at_start = true if count.zero?
              cur.pop if cur.size.odd?
              cur.push(cols, cols, cols, cols)
              emit(cur, ref, row, out, bg, fg)
              count += 1
              break
            end
            emit(cur, ref, row, out, bg, fg)
            count += 1
            ref, cur = cur, ref
            cur.clear
          end
          if rows
            out << bg * (rows - count) if count < rows
            count = rows
          elsif count == limit && start_row(false) != DONE
            raise UnsupportedImageError, "CCITT image too large (more than #{limit} rows)"
          end
          count
        end

        private

        # The data as big-endian 16-bit words plus zero padding: any 13 bits
        # lie within two adjacent words, any 25 bits within three. (A table
        # of 32-bit windows at every byte offset would save a lookup per
        # code but takes far longer to build than a dense page to decode.)
        def words(data)
          (data + ("\0".b * (16 + (data.bytesize & 1)))).unpack("n*")
        end

        def peek(pos, bits)
          w = @win
          k = pos >> 4
          (((w[k] << 32) | (w[k + 1] << 16) | w[k + 2]) >> (48 - bits - (pos & 15))) & ((1 << bits) - 1)
        end

        # Handles byte alignment, fill bits, EOL codes, EOFB/RTC and the
        # 1-D/2-D tag bit in front of a row. Returns ONE_D, TWO_D or DONE.
        # Group 3 data may start with several EOLs.
        def start_row(first)
          pos = @pos
          return DONE if pos >= @nbits

          if @byte_align && !@end_of_line
            # EOFB/RTC may follow the last row unaligned; two EOLs in a row
            # cannot be mistaken for fill bits and a row.
            return DONE if peek(pos, 24) == TWO_EOLS

            pos = (pos + 7) & ~7
          end
          eol = false
          # 11 zero bits: an EOL (maybe after fill bits), EOFB/RTC or padding.
          while peek(pos, 12) <= 1
            pos = skip_eol(pos) or return DONE
            # A second EOL right away is EOFB (Group 4) or RTC (Group 3).
            return DONE if eol && !(first && @k >= 0)

            eol = @eols = true
            # In 2-D Group 3 data each EOL of an RTC carries a tag bit.
            pos += 1 if @k.positive? && peek(pos + 1, 12) <= 1
          end
          pos = (pos + 7) & ~7 if @byte_align && !eol
          two_d = @k.negative?
          if @k.positive?
            two_d = peek(pos, 1).zero?
            pos += 1
          end
          @pos = pos
          two_d ? TWO_D : ONE_D
        end

        # Skips zero bits and the 1 bit that ends an EOL. Returns the
        # position after it, or nil when only zeros remain.
        def skip_eol(pos)
          while pos < @nbits
            bits = peek(pos, 25)
            return pos + 26 - bits.bit_length unless bits.zero?

            pos = (@data.index(NONZERO, (pos >> 3) + 1) or return nil) * 8
          end
          nil
        end

        # Bit position of the next EOL code (or of the fill bits before it)
        # at or after +pos+; the end of the data when there is none.
        def find_eol(pos)
          nbits = @nbits
          while pos < nbits
            bits = peek(pos, 12)
            return pos if bits <= 1

            # No EOL can start before the first 1 bit of this window.
            pos += 13 - bits.bit_length
          end
          nbits
        end

        # Decodes a Modified Huffman (1-D) row into changing elements.
        # Returns false on a coding error.
        def decode_1d_row(cur)
          pos = @pos
          win = @win
          cols = @columns
          white = WHITE_RUNS
          black = BLACK_RUNS
          a = 0
          while true
            run = 0
            while true
              e = white[(((win[k = pos >> 4] << 16) | win[k + 1]) >> (19 - (pos & 15))) & 0x1FFF]
              if e.negative?
                @pos = pos
                return false
              end
              pos += e & 15
              e >>= 4
              run += e
              break if e < 64
            end
            a += run
            a = cols if a > cols
            cur << a
            break if a >= cols

            run = 0
            while true
              e = black[(((win[k = pos >> 4] << 16) | win[k + 1]) >> (19 - (pos & 15))) & 0x1FFF]
              if e.negative?
                @pos = pos
                return false
              end
              pos += e & 15
              e >>= 4
              run += e
              break if e < 64
            end
            a += run
            a = cols if a > cols
            cur << a
            break if a >= cols
          end
          @pos = pos
          true
        end

        # Decodes a 2-D (READ) row against the reference row's changing
        # elements +ref+ (terminated by sentinels equal to the width).
        # Returns false on a coding error.
        def decode_2d_row(ref, cur)
          pos = @pos
          win = @win
          cols = @columns
          modes = MODES
          a0 = -1
          color = 0 # of the run starting at a0; changing element parity
          bi = 0    # index of b1 in ref
          while a0 < cols
            m = modes[(((win[k = pos >> 4] << 16) | win[k + 1]) >> (25 - (pos & 15))) & 0x7F]
            pos += m & 15
            m >>= 4
            if m < PASS # vertical: a1 = b1 + (m - 3)
              a1 = ref[bi] + m - 3
              if a1 < a0 || a1.negative?
                @pos = pos
                return false
              end
              a1 = cols if a1 > cols
              cur << a1
              a0 = a1
              color ^= 1
              # b1 for the other colour: next element on the right, or (after
              # VL) possibly the previous one.
              bi += m >= 3 || bi.zero? ? 1 : -1
              bi += 2 while (b = ref[bi]) <= a0 && b < cols
            elsif m == PASS
              a0 = ref[bi + 1]
              bi += 2
              bi += 2 while (b = ref[bi]) <= a0 && b < cols
            elsif m == HORIZONTAL
              first = color.zero? ? WHITE_RUNS : BLACK_RUNS
              run1 = 0
              while true
                e = first[(((win[k = pos >> 4] << 16) | win[k + 1]) >> (19 - (pos & 15))) & 0x1FFF]
                if e.negative?
                  @pos = pos
                  return false
                end
                pos += e & 15
                e >>= 4
                run1 += e
                break if e < 64
              end
              second = color.zero? ? BLACK_RUNS : WHITE_RUNS
              run2 = 0
              while true
                e = second[(((win[k = pos >> 4] << 16) | win[k + 1]) >> (19 - (pos & 15))) & 0x1FFF]
                if e.negative?
                  @pos = pos
                  return false
                end
                pos += e & 15
                e >>= 4
                run2 += e
                break if e < 64
              end
              a1 = (a0.negative? ? 0 : a0) + run1
              a1 = cols if a1 > cols
              a0 = a1 + run2
              a0 = cols if a0 > cols
              cur << a1 << a0
              bi += 2 while (b = ref[bi]) <= a0 && b < cols
            else # extension (uncompressed mode) or an EOL inside the row
              @pos = pos
              return false
            end
          end
          @pos = pos
          true
        end

        # Appends the row described by the changing elements +cur+ to +out+.
        # +row+ keeps the last painted non-blank row for reuse.
        def emit(cur, ref, row, out, bg, fg)
          cols = @columns
          if cur[0] >= cols
            out << bg
          elsif cur == ref
            out << row
          else
            row.bytesplice(0, cols, bg)
            i = 0
            while (a = cur[i]) < cols
              len = cur[i + 1] - a
              if SPLICE_RANGE
                row.bytesplice(a, len, fg, 0, len)
              else
                row.bytesplice(a, len, fg.byteslice(0, len))
              end
              i += 2
            end
            out << row
          end
        end
      end

      private_constant(*constants)
    end
  end
end
