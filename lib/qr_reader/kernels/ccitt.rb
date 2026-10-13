# frozen_string_literal: true

require_relative "../errors"

# CCITT fax kernel: Group 3 (ITU-T T.4, 1-D Modified Huffman and 2-D
# Modified READ) and Group 4 (T.6, MMR) decoding for TIFF, PDF and JBIG2's
# MMR regions. Kernel files are plain Ruby in the subset that Spinel
# compiles (see DESIGN.md, "Kernels").
#
# Codes are looked up in tables indexed by the next 13 (runs) or 7 (2-D
# modes) bits, read from adjacent 16-bit words of the data; changing
# elements live in Integer arrays; rows are built from cached runs and
# rows equal to the row above are appended as they are.
module QrReaderKernels
  # Terminating codes for run lengths 0..63.
  CCITT_WHITE_TERMINATING = %w[
    00110101 000111 0111 1000 1011 1100 1110 1111 10011 10100 00111 01000 001000 000011 110100 110101
    101010 101011 0100111 0001100 0001000 0010111 0000011 0000100 0101000 0101011 0010011 0100100
    0011000 00000010 00000011 00011010 00011011 00010010 00010011 00010100 00010101 00010110 00010111
    00101000 00101001 00101010 00101011 00101100 00101101 00000100 00000101 00001010 00001011 01010010
    01010011 01010100 01010101 00100100 00100101 01011000 01011001 01011010 01011011 01001010 01001011
    00110010 00110011 00110100
  ].freeze
  CCITT_BLACK_TERMINATING = %w[
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
  CCITT_WHITE_MAKEUP = %w[
    11011 10010 010111 0110111 00110110 00110111 01100100 01100101 01101000 01100111 011001100
    011001101 011010010 011010011 011010100 011010101 011010110 011010111 011011000 011011001
    011011010 011011011 010011000 010011001 010011010 011000 010011011
  ].freeze
  CCITT_BLACK_MAKEUP = %w[
    0000001111 000011001000 000011001001 000001011011 000000110011 000000110100 000000110101
    0000001101100 0000001101101 0000001001010 0000001001011 0000001001100 0000001001101
    0000001110010 0000001110011 0000001110100 0000001110101 0000001110110 0000001110111
    0000001010010 0000001010011 0000001010100 0000001010101 0000001011010 0000001011011
    0000001100100 0000001100101
  ].freeze
  # Extended make-up codes shared by both colours: 1792, 1856, ..., 2560.
  CCITT_EXTENDED_MAKEUP = %w[
    00000001000 00000001100 00000001101 000000010010 000000010011 000000010100 000000010101
    000000010110 000000010111 000000011100 000000011101 000000011110 000000011111
  ].freeze
  # 2-D mode codes: vertical VL3..VR3 (0..6; a1 = b1 + mode - 3), pass (7),
  # horizontal (8), extension (9).
  CCITT_MODE_CODES = %w[0000010 000010 010 1 011 000011 0000011 0001 001 0000001].freeze

  CCITT_PASS = 7
  CCITT_HORIZONTAL = 8
  # Seven zero bits (an EOL inside a row, or garbage).
  CCITT_ZEROS = 10

  # Row starts (CcittDecoder#start_row).
  CCITT_ONE_D = 0
  CCITT_TWO_D = 1
  CCITT_DONE = 2

  # Runs shorter than this come from cached Strings.
  CCITT_CACHED_RUNS = 64

  # Value of a binary digit String ("0110" -> 6).
  def self.ccitt_code_value(code)
    v = 0
    i = 0
    n = code.bytesize
    while i < n
      v = (v << 1) | (code.getbyte(i) - 48)
      i += 1
    end
    v
  end

  # Writes (value << 4 | code length) into +table+ (indexed by +bits+ bits)
  # at every index that starts with +code+.
  def self.ccitt_add_code(table, bits, code, value)
    len = code.bytesize
    i = ccitt_code_value(code) << (bits - len)
    stop = i + (1 << (bits - len))
    while i < stop
      table[i] = (value << 4) | len
      i += 1
    end
  end

  # Lookup table for the next 13 bits: (run << 4 | code length), or -1
  # where no code matches (EOL, garbage).
  def self.ccitt_run_table(terminating, makeup)
    table = Array.new(8192, -1)
    i = 0
    while i < terminating.size
      ccitt_add_code(table, 13, terminating[i], i)
      i += 1
    end
    i = 0
    while i < makeup.size
      ccitt_add_code(table, 13, makeup[i], 64 * (i + 1))
      i += 1
    end
    i = 0
    while i < CCITT_EXTENDED_MAKEUP.size
      ccitt_add_code(table, 13, CCITT_EXTENDED_MAKEUP[i], 1792 + 64 * i)
      i += 1
    end
    table
  end

  # Lookup table for the next 7 bits: (mode << 4 | code length).
  def self.ccitt_mode_table
    table = Array.new(128, CCITT_ZEROS << 4)
    i = 0
    while i < CCITT_MODE_CODES.size
      ccitt_add_code(table, 7, CCITT_MODE_CODES[i], i)
      i += 1
    end
    table
  end

  # Strings of 0..CCITT_CACHED_RUNS-1 copies of +byte+.
  def self.ccitt_runs(byte)
    runs = []
    run = String.new(capacity: CCITT_CACHED_RUNS, encoding: Encoding::BINARY)
    i = 0
    while i < CCITT_CACHED_RUNS
      runs << run.dup
      run << byte
      i += 1
    end
    runs
  end

  CCITT_WHITE_RUNS = ccitt_run_table(CCITT_WHITE_TERMINATING, CCITT_WHITE_MAKEUP)
  CCITT_BLACK_RUNS = ccitt_run_table(CCITT_BLACK_TERMINATING, CCITT_BLACK_MAKEUP)
  CCITT_MODES = ccitt_mode_table
  CCITT_RUNS_FF = ccitt_runs(255)
  CCITT_RUNS_00 = ccitt_runs(0)

  # Decodes a CCITT stream to +columns+-byte rows (coded white 255, black
  # 0; swapped when +black_is_1+). +k+ < 0: Group 4; 0: Group 3 1-D; > 0:
  # Group 3 2-D. +rows+ > 0: exactly that many rows (white after the end
  # of the data); 0: all rows up to EOFB/RTC or the end of the data, at
  # most +max_rows+ (more raise UnsupportedImageError). +byte_align+: rows
  # start on byte boundaries; +end_of_line+: EOLs precede the rows (only
  # decides whether an unaligned EOL may stand before a byte-aligned row).
  #
  # Damaged rows of EOL-delimited (Group 3) data are replaced by the row
  # above and decoding resumes at the next EOL. Without EOLs an error ends
  # the image there. Raises ImageError when not even the first row decodes.
  # spinel-sample: QrReaderKernels.ccitt_decode("\x26\xA0\x00\x10\x01".b, 8, 0, -1, false, false, false, 100)
  def self.ccitt_decode(data, columns, rows, k, byte_align, end_of_line, black_is_1, max_rows)
    decoder = CcittDecoder.new(data, columns, k, byte_align, end_of_line)
    out = decoder.decode(rows, max_rows, black_is_1)
    raise QrReader::ImageError, "corrupt CCITT data (first row undecodable)" if decoder.failed_at_start
    raise QrReader::ImageError, "CCITT data contains no rows" if out.bytesize == 0

    out
  end

  # Decodes one CCITT stream.
  class CcittDecoder
    attr_reader :failed_at_start

    def initialize(data, columns, k, byte_align, end_of_line)
      @data = data
      @nbits = data.bytesize * 8
      @win = words(data)
      @columns = columns
      @k = k
      @byte_align = byte_align
      @end_of_line = end_of_line
      @pos = 0
      @eols = false
      @failed_at_start = false
      @last = ""
    end

    # The rows (see QrReaderKernels.ccitt_decode).
    def decode(rows, max_rows, inverted)
      cols = @columns
      bg = filled(inverted ? 0 : 255, cols)
      fg = filled(inverted ? 255 : 0, cols)
      bg_runs = inverted ? CCITT_RUNS_00 : CCITT_RUNS_FF
      fg_runs = inverted ? CCITT_RUNS_FF : CCITT_RUNS_00
      out = String.new(capacity: cols * (rows > 0 ? rows : 64), encoding: Encoding::BINARY)
      limit = rows > 0 ? rows : max_rows
      ref = [cols, cols, cols, cols]
      cur = []
      count = 0
      while count < limit
        mode = start_row(count == 0)
        break if mode == CCITT_DONE

        ok = mode == CCITT_TWO_D ? decode_2d_row(ref, cur) : decode_1d_row(cur)
        stop = false
        if ok
          push_sentinels(cur, cols)
        elsif @eols
          # Damaged row: repeat the row above, resume at the next EOL.
          copy(ref, cur)
          @pos = find_eol(@pos)
        else
          # No EOLs to resynchronise at: keep the row's start and stop.
          @failed_at_start = true if count == 0
          cur.pop if cur.size.odd?
          push_sentinels(cur, cols)
          stop = true
        end
        out << row_for(cur, ref, bg, fg, bg_runs, fg_runs)
        count += 1
        break if stop

        swap = ref
        ref = cur
        cur = swap
        cur.clear
      end
      if rows > 0
        while count < rows
          out << bg
          count += 1
        end
      elsif count == limit && start_row(false) != CCITT_DONE
        raise QrReader::UnsupportedImageError, "CCITT image too large (more than #{limit} rows)"
      end
      out
    end

    private

    # The data as big-endian 16-bit words plus zero padding: any 13 bits
    # lie within two adjacent words, any 25 bits within three.
    def words(data)
      n = data.bytesize
      count = (n + 1) / 2 + 8
      win = Array.new(count, 0)
      i = 0
      while i < n
        i = words_part(data, win, i, n)
      end
      win
    end

    # Fills words from byte +i+ on (a part, so that YJIT compiles the loop).
    def words_part(data, win, i, n)
      stop = i + 8192
      stop = n - 1 if stop > n - 1
      while i < stop
        win[i >> 1] = (data.getbyte(i) << 8) | data.getbyte(i + 1)
        i += 2
      end
      if i == n - 1
        win[i >> 1] = data.getbyte(i) << 8
        i += 1
      end
      i
    end

    def filled(byte, count)
      s = String.new(capacity: count, encoding: Encoding::BINARY)
      i = 0
      while i < count
        s << byte
        i += 1
      end
      s
    end

    def push_sentinels(cur, cols)
      cur << cols
      cur << cols
      cur << cols
      cur << cols
    end

    def copy(from, to)
      to.clear
      i = 0
      n = from.size
      while i < n
        to << from[i]
        i += 1
      end
    end

    def peek(pos, bits)
      w = @win
      k = pos >> 4
      (((w[k] << 32) | (w[k + 1] << 16) | w[k + 2]) >> (48 - bits - (pos & 15))) & ((1 << bits) - 1)
    end

    # Handles byte alignment, fill bits, EOL codes, EOFB/RTC and the
    # 1-D/2-D tag bit in front of a row. Returns CCITT_ONE_D, CCITT_TWO_D
    # or CCITT_DONE. Group 3 data may start with several EOLs.
    def start_row(first)
      pos = @pos
      return CCITT_DONE if pos >= @nbits

      if @byte_align && !@end_of_line
        # EOFB/RTC may follow the last row unaligned; two EOLs in a row
        # cannot be mistaken for fill bits and a row.
        return CCITT_DONE if peek(pos, 24) == 0b000000000001_000000000001

        pos = (pos + 7) & ~7
      end
      eol = false
      # 11 zero bits: an EOL (maybe after fill bits), EOFB/RTC or padding.
      while peek(pos, 12) <= 1
        pos = skip_eol(pos)
        return CCITT_DONE if pos < 0
        # A second EOL right away is EOFB (Group 4) or RTC (Group 3).
        return CCITT_DONE if eol && !(first && @k >= 0)

        eol = true
        @eols = true
        # In 2-D Group 3 data each EOL of an RTC carries a tag bit.
        pos += 1 if @k > 0 && peek(pos + 1, 12) <= 1
      end
      pos = (pos + 7) & ~7 if @byte_align && !eol
      two_d = @k < 0
      if @k > 0
        two_d = peek(pos, 1) == 0
        pos += 1
      end
      @pos = pos
      two_d ? CCITT_TWO_D : CCITT_ONE_D
    end

    # Skips zero bits and the 1 bit that ends an EOL. Returns the position
    # after it, or -1 when only zeros remain.
    def skip_eol(pos)
      while pos < @nbits
        bits = peek(pos, 25)
        return pos + 26 - bit_length(bits) if bits != 0

        # 25 zero bits: continue at the next nonzero byte.
        i = (pos >> 3) + 1
        n = @data.bytesize
        i += 1 while i < n && @data.getbyte(i) == 0
        return -1 if i >= n

        pos = i * 8
      end
      -1
    end

    # Bit position of the next EOL code (or of the fill bits before it)
    # at or after +pos+; the end of the data when there is none.
    def find_eol(pos)
      nbits = @nbits
      while pos < nbits
        bits = peek(pos, 12)
        return pos if bits <= 1

        # No EOL can start before the first 1 bit of this window.
        pos += 13 - bit_length(bits)
      end
      nbits
    end

    def bit_length(v)
      n = 0
      while v > 0
        v >>= 1
        n += 1
      end
      n
    end

    # Decodes a Modified Huffman (1-D) row into changing elements. Returns
    # false on a coding error.
    def decode_1d_row(cur)
      pos = @pos
      win = @win
      cols = @columns
      white = CCITT_WHITE_RUNS
      black = CCITT_BLACK_RUNS
      a = 0
      while true
        run = 0
        while true
          k = pos >> 4
          e = white[(((win[k] << 16) | win[k + 1]) >> (19 - (pos & 15))) & 0x1FFF]
          if e < 0
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
          k = pos >> 4
          e = black[(((win[k] << 16) | win[k + 1]) >> (19 - (pos & 15))) & 0x1FFF]
          if e < 0
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
    # elements +ref+ (terminated by sentinels equal to the width). Returns
    # false on a coding error.
    def decode_2d_row(ref, cur)
      pos = @pos
      win = @win
      cols = @columns
      modes = CCITT_MODES
      a0 = -1
      color = 0 # of the run starting at a0; changing element parity
      bi = 0    # index of b1 in ref
      while a0 < cols
        k = pos >> 4
        m = modes[(((win[k] << 16) | win[k + 1]) >> (25 - (pos & 15))) & 0x7F]
        pos += m & 15
        m >>= 4
        if m < CCITT_PASS # vertical: a1 = b1 + (m - 3)
          a1 = ref[bi] + m - 3
          if a1 < a0 || a1 < 0
            @pos = pos
            return false
          end
          a1 = cols if a1 > cols
          cur << a1
          a0 = a1
          color ^= 1
          # b1 for the other colour: next element on the right, or (after
          # VL) possibly the previous one.
          bi += m >= 3 || bi == 0 ? 1 : -1
          bi += 2 while (b = ref[bi]) <= a0 && b < cols
        elsif m == CCITT_PASS
          a0 = ref[bi + 1]
          bi += 2
          bi += 2 while (b = ref[bi]) <= a0 && b < cols
        elsif m == CCITT_HORIZONTAL
          first = color == 0 ? CCITT_WHITE_RUNS : CCITT_BLACK_RUNS
          run1 = 0
          while true
            k = pos >> 4
            e = first[(((win[k] << 16) | win[k + 1]) >> (19 - (pos & 15))) & 0x1FFF]
            if e < 0
              @pos = pos
              return false
            end
            pos += e & 15
            e >>= 4
            run1 += e
            break if e < 64
          end
          second = color == 0 ? CCITT_BLACK_RUNS : CCITT_WHITE_RUNS
          run2 = 0
          while true
            k = pos >> 4
            e = second[(((win[k] << 16) | win[k + 1]) >> (19 - (pos & 15))) & 0x1FFF]
            if e < 0
              @pos = pos
              return false
            end
            pos += e & 15
            e >>= 4
            run2 += e
            break if e < 64
          end
          a1 = (a0 < 0 ? 0 : a0) + run1
          a1 = cols if a1 > cols
          a0 = a1 + run2
          a0 = cols if a0 > cols
          cur << a1
          cur << a0
          bi += 2 while (b = ref[bi]) <= a0 && b < cols
        else # extension (uncompressed mode) or an EOL inside the row
          @pos = pos
          return false
        end
      end
      @pos = pos
      true
    end

    # The row described by the changing elements +cur+ (+ref+: those of
    # the row above, last painted as @last).
    def row_for(cur, ref, bg, fg, bg_runs, fg_runs)
      cols = @columns
      return bg if cur[0] >= cols
      return @last if same(cur, ref)

      row = String.new(capacity: cols, encoding: Encoding::BINARY)
      a = 0 # start of the next background run
      i = 0
      while (b = cur[i]) < cols
        n = b - a
        if n < CCITT_CACHED_RUNS
          row << bg_runs[n]
        else
          row << bg.byteslice(0, n)
        end
        a = cur[i + 1]
        n = a - b
        if n < CCITT_CACHED_RUNS
          row << fg_runs[n]
        else
          row << fg.byteslice(0, n)
        end
        i += 2
      end
      n = cols - a
      if n < CCITT_CACHED_RUNS
        row << bg_runs[n]
      elsif n > 0
        row << bg.byteslice(0, n)
      end
      @last = row
      row
    end

    def same(cur, ref)
      n = cur.size
      return false unless n == ref.size

      i = 0
      while i < n
        return false unless cur[i] == ref[i]

        i += 1
      end
      true
    end
  end
end
