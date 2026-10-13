# frozen_string_literal: true

require "digest"
require "json"
require "zlib"

# Test support for the TIFF and CCITT decoders: access to the generated
# fixtures (see generate.rb) and deliberately simple, independent encoders
# for the variants a test needs: CCITT (T.4 / T.6), LZW (both bit orders),
# PackBits and a TIFF writer. Nothing here shares code with the decoders.
module TiffFixtures
  DIR = __dir__

  module_function

  def manifest
    @manifest ||= JSON.parse(File.read(File.join(DIR, "manifest.json")))
  end

  def read(name)
    File.binread(File.join(DIR, name))
  end

  # Expected luminance of page +page+ of a fixture (nil for digest-only
  # entries, see #expected_digest).
  def expected(name, page = 0)
    entry = manifest.fetch(name)["pages"][page]
    w = entry["width"]
    h = entry["height"]
    case entry["reference"]
    when "runs" then QrReader::Image.new(w, h, runs_image(w, h))
    when /\.rgba\.z\z/
      QrReader::Image.from_pixels(w, h, inflate(entry["reference"]), :rgba)
    when /\.cmyk\.z\z/
      QrReader::Image.new(w, h, cmyk_luma(inflate(entry["reference"])))
    end
  end

  def expected_digest(name, page = 0)
    manifest.fetch(name)["pages"][page]["sha256"]
  end

  # Tags of the first directory of a classic TIFF: tag => Array of Integers
  # (a String for UNDEFINED values such as JPEGTables).
  def first_directory(bytes)
    le = bytes.start_with?("II")
    u16 = ->(pos) { bytes.unpack1(le ? "v" : "n", offset: pos) }
    u32 = ->(pos) { bytes.unpack1(le ? "V" : "N", offset: pos) }
    ifd = u32.call(4)
    Array.new(u16.call(ifd)) do |i|
      entry = ifd + 2 + 12 * i
      type = u16.call(entry + 2)
      size = { 3 => 2, 4 => 4 }.fetch(type, 1) * u32.call(entry + 4)
      data = bytes.byteslice(size > 4 ? u32.call(entry + 8) : entry + 8, size)
      values = case type
               when 3 then data.unpack(le ? "v*" : "n*")
               when 4 then data.unpack(le ? "V*" : "N*")
               when 7 then data
               else data.unpack("C*")
               end
      [u16.call(entry), values]
    end.to_h
  end

  def inflate(file)
    Zlib::Inflate.inflate(File.binread(File.join(DIR, file)))
  end

  # CMYK ink amounts (0 = none) -> luminance: R = (255 - C) * (255 - K) / 255 ...
  def cmyk_luma(cmyk)
    cmyk.unpack("C*").each_slice(4).map do |c, m, y, k|
      r, g, b = [c, m, y].map { |v| ((255 - v) * (255 - k) + 127) / 255 }
      QrReader::Image.luma(r, g, b)
    end.pack("C*")
  end

  # The run-length coverage image (see generate.rb): row r < 256 has a white
  # run, a black run and white up to the end, together covering every
  # terminating, make-up and extended make-up code of both colours; the last
  # two rows are all white and all black.
  def runs_image(width, height)
    rows = Array.new(height) do |r|
      if r == height - 2 then "\xFF".b * width
      elsif r == height - 1 then "\0".b * width
      else
        white, black = runs_row(r)
        ("\xFF".b * white) + ("\0".b * black) + ("\xFF".b * (width - white - black))
      end
    end
    rows.join
  end

  def runs_row(r)
    [(r % 64) + 64 * ((r * 11) % 41), (63 - (r % 64)) + 64 * ((r * 7 + 3) % 41)]
  end

  # Bilevel rows (Arrays of 0 = white / 1 = black) -> luminance image.
  def bilevel_image(rows)
    QrReader::Image.new(rows[0].size, rows.size, rows.flatten.map { |b| b == 1 ? 0 : 255 }.pack("C*"))
  end

  # Deterministic random bilevel rows mixing several structures: noise,
  # long runs, vertical edges with small shifts (vertical modes), blank rows.
  def random_bilevel(width, height, seed:)
    rng = Random.new(seed)
    prev = Array.new(width, 0)
    Array.new(height) do
      row = case rng.rand(6)
            when 0 then Array.new(width) { rng.rand(2) }
            when 1 then Array.new(width, 0)
            when 2 # long runs
              out = []
              color = rng.rand(2)
              out.concat([color ^= 1] * (1 + rng.rand([width, 3000].min))) while out.size < width
              out.first(width)
            else # previous row with edges moved by up to +-4 and a few flips
              row = prev.dup
              (1 + rng.rand(4)).times do
                x = rng.rand(width)
                shift = rng.rand(-4..4)
                row[x] = prev[(x + shift).clamp(0, width - 1)]
              end
              row.each_index { |x| row[x] = prev[(x - 1).clamp(0, width - 1)] } if rng.rand(4).zero?
              row
            end
      prev = row
    end
  end

  # Independent CCITT encoder (ITU-T T.4 and T.6) producing bit strings.
  module CcittEncoder
    WHITE = {
      0 => "00110101", 1 => "000111", 2 => "0111", 3 => "1000", 4 => "1011", 5 => "1100", 6 => "1110",
      7 => "1111", 8 => "10011", 9 => "10100", 10 => "00111", 11 => "01000", 12 => "001000", 13 => "000011",
      14 => "110100", 15 => "110101", 16 => "101010", 17 => "101011", 18 => "0100111", 19 => "0001100",
      20 => "0001000", 21 => "0010111", 22 => "0000011", 23 => "0000100", 24 => "0101000", 25 => "0101011",
      26 => "0010011", 27 => "0100100", 28 => "0011000", 29 => "00000010", 30 => "00000011", 31 => "00011010",
      32 => "00011011", 33 => "00010010", 34 => "00010011", 35 => "00010100", 36 => "00010101",
      37 => "00010110", 38 => "00010111", 39 => "00101000", 40 => "00101001", 41 => "00101010",
      42 => "00101011", 43 => "00101100", 44 => "00101101", 45 => "00000100", 46 => "00000101",
      47 => "00001010", 48 => "00001011", 49 => "01010010", 50 => "01010011", 51 => "01010100",
      52 => "01010101", 53 => "00100100", 54 => "00100101", 55 => "01011000", 56 => "01011001",
      57 => "01011010", 58 => "01011011", 59 => "01001010", 60 => "01001011", 61 => "00110010",
      62 => "00110011", 63 => "00110100",
      64 => "11011", 128 => "10010", 192 => "010111", 256 => "0110111", 320 => "00110110", 384 => "00110111",
      448 => "01100100", 512 => "01100101", 576 => "01101000", 640 => "01100111", 704 => "011001100",
      768 => "011001101", 832 => "011010010", 896 => "011010011", 960 => "011010100", 1024 => "011010101",
      1088 => "011010110", 1152 => "011010111", 1216 => "011011000", 1280 => "011011001",
      1344 => "011011010", 1408 => "011011011", 1472 => "010011000", 1536 => "010011001",
      1600 => "010011010", 1664 => "011000", 1728 => "010011011"
    }.freeze
    BLACK = {
      0 => "0000110111", 1 => "010", 2 => "11", 3 => "10", 4 => "011", 5 => "0011", 6 => "0010", 7 => "00011",
      8 => "000101", 9 => "000100", 10 => "0000100", 11 => "0000101", 12 => "0000111", 13 => "00000100",
      14 => "00000111", 15 => "000011000", 16 => "0000010111", 17 => "0000011000", 18 => "0000001000",
      19 => "00001100111", 20 => "00001101000", 21 => "00001101100", 22 => "00000110111",
      23 => "00000101000", 24 => "00000010111", 25 => "00000011000", 26 => "000011001010",
      27 => "000011001011", 28 => "000011001100", 29 => "000011001101", 30 => "000001101000",
      31 => "000001101001", 32 => "000001101010", 33 => "000001101011", 34 => "000011010010",
      35 => "000011010011", 36 => "000011010100", 37 => "000011010101", 38 => "000011010110",
      39 => "000011010111", 40 => "000001101100", 41 => "000001101101", 42 => "000011011010",
      43 => "000011011011", 44 => "000001010100", 45 => "000001010101", 46 => "000001010110",
      47 => "000001010111", 48 => "000001100100", 49 => "000001100101", 50 => "000001010010",
      51 => "000001010011", 52 => "000000100100", 53 => "000000110111", 54 => "000000111000",
      55 => "000000100111", 56 => "000000101000", 57 => "000001011000", 58 => "000001011001",
      59 => "000000101011", 60 => "000000101100", 61 => "000001011010", 62 => "000001100110",
      63 => "000001100111",
      64 => "0000001111", 128 => "000011001000", 192 => "000011001001", 256 => "000001011011",
      320 => "000000110011", 384 => "000000110100", 448 => "000000110101", 512 => "0000001101100",
      576 => "0000001101101", 640 => "0000001001010", 704 => "0000001001011", 768 => "0000001001100",
      832 => "0000001001101", 896 => "0000001110010", 960 => "0000001110011", 1024 => "0000001110100",
      1088 => "0000001110101", 1152 => "0000001110110", 1216 => "0000001110111", 1280 => "0000001010010",
      1344 => "0000001010011", 1408 => "0000001010100", 1472 => "0000001010101", 1536 => "0000001011010",
      1600 => "0000001011011", 1664 => "0000001100100", 1728 => "0000001100101"
    }.freeze
    EXTENDED = {
      1792 => "00000001000", 1856 => "00000001100", 1920 => "00000001101", 1984 => "000000010010",
      2048 => "000000010011", 2112 => "000000010100", 2176 => "000000010101", 2240 => "000000010110",
      2304 => "000000010111", 2368 => "000000011100", 2432 => "000000011101", 2496 => "000000011110",
      2560 => "000000011111"
    }.freeze
    # Vertical mode codes by a1 - b1.
    VERTICAL = { -3 => "0000010", -2 => "000010", -1 => "010", 0 => "1", 1 => "011", 2 => "000011",
                 3 => "0000011" }.freeze
    PASS = "0001"
    HORIZONTAL = "001"
    EOL = "000000000001"

    module_function

    # Encodes bilevel +rows+ (Arrays of 0 = white / 1 = black).
    # k: < 0 Group 4, 0 Group 3 1-D, > 0 Group 3 2-D (a 1-D row every k rows).
    # eol: EOL before each row (Group 3); byte_align: :row pads each row to
    # a byte boundary (TIFF compression 2, PDF EncodedByteAlign without
    # EOLs), :eol pads before each EOL so that it ends on a byte boundary
    # (TIFF T4Options bit 2), :eol_start pads so that each EOL starts on one;
    # rtc: end with EOFB (Group 4) or RTC (Group 3); fill_order 2 reverses
    # the bits of every byte. Returns a binary String.
    def encode(rows, k: -1, eol: k >= 0, byte_align: nil, rtc: true, fill_order: 1)
      width = rows[0].size
      bits = +""
      ref = []
      rows.each_with_index do |row, y|
        cur = changes(row)
        if eol
          pad(bits, 8 - 12) if byte_align == :eol
          pad(bits, 0) if byte_align == :eol_start
          bits << EOL
          bits << ((y % k).zero? ? "1" : "0") if k.positive?
        elsif byte_align == :row
          pad(bits, 0)
        end
        if k.negative? || (k.positive? && !(y % k).zero?)
          encode_2d(bits, cur, ref, width)
        else
          encode_1d(bits, row)
        end
        ref = cur
      end
      if rtc
        if k.negative?
          bits << EOL << EOL
        else
          6.times { bits << EOL << (k.positive? ? "1" : "") }
        end
      end
      bits << "0" * (-bits.size % 8)
      data = [bits].pack("B*")
      data = data.unpack("b*").pack("B*") if fill_order == 2
      data
    end

    # Appends zero bits until bits.size % 8 == offset % 8.
    def pad(bits, offset)
      bits << "0" while (bits.size - offset) % 8 != 0
    end

    # Changing elements: positions where the colour differs from the pixel
    # before (the pixel before the first is white).
    def changes(row)
      out = []
      prev = 0
      row.each_with_index do |c, x|
        out << x if c != prev
        prev = c
      end
      out
    end

    def encode_1d(bits, row)
      x = 0
      color = 0
      width = row.size
      while x < width
        run = 0
        run += 1 while x + run < width && row[x + run] == color
        run_code(bits, run, color)
        x += run
        color ^= 1
      end
      # A row ending in black needs no trailing white run.
    end

    def run_code(bits, run, color)
      table = color.zero? ? WHITE : BLACK
      while run >= 2560
        bits << EXTENDED[2560]
        run -= 2560
      end
      if run >= 64
        makeup = run / 64 * 64
        bits << (makeup >= 1792 ? EXTENDED[makeup] : table[makeup])
        run -= makeup
      end
      bits << table[run]
    end

    # T.4 two-dimensional coding of one row against the reference row.
    def encode_2d(bits, cur, ref, width)
      a0 = -1
      color = 0
      loop do
        a1 = next_change(cur, a0, width)
        b1 = ref_b1(ref, a0, color, width)
        b2 = next_change(ref, b1, width)
        if b2 < a1
          bits << PASS
          a0 = b2
        elsif (a1 - b1).abs <= 3
          bits << VERTICAL.fetch(a1 - b1)
          a0 = a1
          color ^= 1
        else
          a2 = next_change(cur, a1, width)
          bits << HORIZONTAL
          run_code(bits, a1 - [a0, 0].max, color)
          run_code(bits, a2 - a1, color ^ 1)
          a0 = a2
        end
        break if a0 >= width
      end
    end

    # First changing element after +pos+ (width if none).
    def next_change(changes, pos, width)
      changes.find { |c| c > pos } || width
    end

    # b1: first changing element of the reference row after a0 whose
    # colour is the opposite of +color+ (even indices change to black).
    def ref_b1(ref, a0, color, width)
      ref.each_with_index { |c, i| return c if c > a0 && i.even? == color.zero? }
      width
    end
  end

  # LZW encoder for TIFF (MSB-first with early change) and the old
  # LSB-first variant; emits a Clear code when the table is full.
  module LzwEncoder
    module_function

    def encode(data, compat: false, clear_every: nil)
      codes = []
      widths = []
      table = {}
      reset = lambda do
        table.clear
        256.times { |i| table[i.chr.b] = i }
      end
      reset.call
      next_code = 258
      width = 9
      early = compat ? 0 : 1
      emit = lambda do |code|
        codes << code
        widths << width
      end
      emit.call(256)
      w = "".b
      emitted = 0
      fresh = true # the next code follows a Clear (the decoder adds no entry for it)
      data.each_byte do |byte|
        c = byte.chr.b
        wc = w + c
        if table.key?(wc)
          w = wc
          next
        end
        emit.call(table[w])
        emitted += 1
        fresh = false
        table[wc] = next_code
        next_code += 1
        width += 1 if next_code + early > (1 << width) && width < 12
        if next_code >= 4094 || (clear_every && (emitted % clear_every).zero?)
          emit.call(256)
          reset.call
          next_code = 258
          width = 9
          fresh = true
        end
        w = c
      end
      unless w.empty?
        emit.call(table[w])
        # Like libtiff: the decoder adds an entry for this code, which may
        # widen the codes before EOI.
        width += 1 if !fresh && next_code + 1 + early > (1 << width) && width < 12
      end
      emit.call(257)
      pack(codes, widths, compat)
    end

    def pack(codes, widths, compat)
      if compat
        acc = 0
        n = 0
        out = []
        codes.zip(widths).each do |code, width|
          acc |= code << n
          n += width
          while n >= 8
            out << (acc & 0xFF)
            acc >>= 8
            n -= 8
          end
        end
        out << acc if n.positive?
        out.pack("C*")
      else
        bits = codes.zip(widths).map { |code, width| code.to_s(2).rjust(width, "0") }.join
        [bits].pack("B*")
      end
    end
  end

  module PackBits
    module_function

    # Encodes with literal runs, repeat runs and the occasional -128 no-op.
    def encode(data)
      out = "".b
      bytes = data.bytes
      i = 0
      while i < bytes.size
        run = 1
        run += 1 while i + run < bytes.size && bytes[i + run] == bytes[i] && run < 128
        if run >= 3
          out << [257 - run, bytes[i]].pack("CC")
          i += run
        else
          lit = 1
          lit += 1 while i + lit < bytes.size && lit < 128 && !(bytes[i + lit] == bytes[i + lit + 1] &&
                                                              bytes[i + lit] == bytes[i + lit + 2])
          out << [lit - 1].pack("C") << bytes[i, lit].pack("C*")
          out << "\x80".b if (i / 7).odd?
          i += lit
        end
      end
      out
    end
  end

  # Minimal TIFF writer: pages of tags plus strip (or tile) data.
  module TiffWriter
    SHORT = 3
    LONG = 4
    LONG8 = 16
    UNDEFINED = 7
    OFFSET_TAGS = [273, 324, 513].freeze

    module_function

    # pages: [{ tags: { tag => Integer | [Integer] | [type, values] | String },
    #           chunks: [String], tiled: false, next: optional next-IFD override }]
    # Offsets (273/324) and byte counts (279/325) are filled in from +chunks+
    # unless given. Returns the file as a binary String.
    def build(pages, endian: :little, big: false)
      le = endian == :little
      out = (le ? "II".b : "MM".b)
      out << (big ? u(43, 2, le) + u(8, 2, le) + u(0, 2, le) + u(0, 8, le) : u(42, 2, le) + u(0, 4, le))
      first_pos = big ? 8 : 4
      prev_next = first_pos
      ifd_offsets = []
      pages.each do |page|
        tags = page[:tags].dup
        chunks = page[:chunks] || []
        offsets = chunks.map do |chunk|
          out << "\0".b if out.bytesize.odd?
          pos = out.bytesize
          out << chunk
          pos
        end
        off_tag, count_tag = page[:tiled] ? [324, 325] : [273, 279]
        tags[off_tag] = [big ? LONG8 : LONG, offsets] unless tags.key?(off_tag) || chunks.empty?
        tags[count_tag] = [big ? LONG8 : LONG, chunks.map(&:bytesize)] unless tags.key?(count_tag) || chunks.empty?
        tags.compact!
        out << "\0".b if out.bytesize.odd?
        ifd_pos = out.bytesize
        ifd_offsets << ifd_pos
        out[prev_next, big ? 8 : 4] = u(ifd_pos, big ? 8 : 4, le)
        prev_next = write_ifd(out, tags, le, big)
        out[prev_next, big ? 8 : 4] = u(page[:next], big ? 8 : 4, le) if page[:next]
      end
      out
    end

    def write_ifd(out, tags, le, big)
      entry_size = big ? 20 : 12
      value_size = big ? 8 : 4
      start = out.bytesize
      sorted = tags.sort_by(&:first)
      out << u(sorted.size, big ? 8 : 2, le)
      table_pos = out.bytesize
      out << "\0".b * (sorted.size * entry_size + value_size)
      sorted.each_with_index do |(tag, value), i|
        type, values = typed(tag, value, big)
        bytes = encode_values(type, values, le)
        count = type == UNDEFINED ? bytes.bytesize : values.size
        if bytes.bytesize <= value_size
          field = bytes + "\0".b * (value_size - bytes.bytesize)
        else
          out << "\0".b if out.bytesize.odd?
          field = u(out.bytesize, value_size, le)
          out << bytes
        end
        entry = u(tag, 2, le) + u(type, 2, le) + u(count, value_size, le) + field
        out[table_pos + i * entry_size, entry_size] = entry
      end
      start + (big ? 8 : 2) + sorted.size * entry_size
    end

    def typed(tag, value, big)
      return [UNDEFINED, value] if value.is_a?(String)
      return value if value.is_a?(Array) && value.size == 2 && value[1].is_a?(Array)

      values = Array(value)
      type = if OFFSET_TAGS.include?(tag) || values.any? { |v| v > 0xFFFF }
               big && values.any? { |v| v > 0xFFFFFFFF } ? LONG8 : LONG
             else
               SHORT
             end
      [type, values]
    end

    def encode_values(type, values, le)
      return values.b if type == UNDEFINED

      case type
      when 1, 7 then values.pack("C*")
      when 3 then values.pack(le ? "v*" : "n*")
      when 4 then values.pack(le ? "V*" : "N*")
      when 8 then values.pack(le ? "s<*" : "s>*")
      when 9 then values.pack(le ? "l<*" : "l>*")
      when 16 then values.pack(le ? "Q<*" : "Q>*")
      else raise ArgumentError, "type #{type}"
      end
    end

    def u(value, size, le)
      bytes = Array.new(size) { |i| (value >> (8 * i)) & 0xFF }
      (le ? bytes : bytes.reverse).pack("C*")
    end
  end
end
