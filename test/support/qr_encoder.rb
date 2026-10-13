# frozen_string_literal: true

require "qr_reader/image"
require "qr_reader/bit_matrix"
require "qr_reader/result"

# An independent QR Code Model 2 encoder (ISO/IEC 18004:2015), used only to
# generate test symbols that general-purpose encoders cannot produce: mixed
# segments incl. Kanji and Hanzi (GB2312), ECI designators of 1-3 bytes,
# FNC1 in first/second position, Structured Append headers, explicit masks
# and deliberately corrupted codewords or modules.
#
# Independent on purpose: it shares no code or tables with lib/ (its own EC
# block tables in the per-level "ECC per block / number of blocks" form,
# alignment positions from Annex E, codeword capacity counted from the drawn
# function patterns, its own GF(256), BCH and placement code).
#
#   QrTestEncoder.encode("HELLO", level: :Q)                   # => QrReader::BitMatrix
#   QrTestEncoder.build([[:eci, 26], [:byte, "Grüße"]], mask: 3) # => QrTestEncoder::Encoded
#   QrTestEncoder.build("01234567", version: 1, level: :M, corrupt_per_block: :max)
class QrTestEncoder
  # Raised when the content cannot be encoded (invalid characters for a
  # mode, too long for the requested version, bad options).
  class Error < ArgumentError; end

  # A segment has more characters than its character count indicator can
  # express in the chosen version range.
  class CountOverflow < Error; end

  # An encoded symbol.
  #
  # matrix          - QrReader::BitMatrix (no quiet zone), corruption applied
  # version, level, mask (level as in ISO/IEC 18004: :L, :M, :Q, :H; #ec_level
  #                   gives the lowercase form used by QrReader::Result)
  # segments        - Array of Segment actually encoded
  # bit_length      - number of payload bits before terminator/padding
  # data_codewords  - Array<Integer>, payload + padding, before error correction
  # blocks          - Array of [data Array<Integer>, ecc Array<Integer>] per RS block
  # codewords       - Array<Integer>, interleaved final sequence (uncorrupted)
  # corrupted       - Hash with :codewords (indices into +codewords+) and
  #                   :modules ([x, y] pairs) that were damaged
  Encoded = Data.define(:matrix, :version, :level, :mask, :segments, :bit_length,
                        :data_codewords, :blocks, :codewords, :corrupted) do
    def dimension
      matrix.width
    end

    # +level+ in the lowercase form of QrReader::Result#ec_level (:l, :m, :q, :h).
    def ec_level
      level.downcase
    end

    # Axis-aligned grayscale rendering with a light quiet zone.
    def to_image(module_size: 4, quiet: 4, dark: 0, light: 255)
      QrTestEncoder.render(matrix, module_size: module_size, quiet: quiet, dark: dark, light: light)
    end
  end

  # One bit stream segment. +data+ depends on +mode+: String (numeric,
  # alphanumeric, byte), Array of 13-bit values (kanji, hanzi), Integer
  # (eci, fnc1_second application indicator), [index, count, parity]
  # (structured_append) or nil (fnc1_first).
  Segment = Data.define(:mode, :data)

  LEVELS = %i[L M Q H].freeze

  # Error correction codewords per block, indexed by version (Table 9).
  ECC_PER_BLOCK = {
    L: [nil, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
        28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    M: [nil, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
        26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    Q: [nil, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30,
        28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    H: [nil, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28,
        30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
  }.freeze

  # Number of error correction blocks, indexed by version (Table 9).
  NUM_BLOCKS = {
    L: [nil, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8,
        8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    M: [nil, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
        17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    Q: [nil, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20,
        23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    H: [nil, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25,
        25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81]
  }.freeze

  # Row/column coordinates of alignment pattern centres (Annex E, Table E.1).
  ALIGNMENT_POSITIONS = [
    nil, [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
    [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50], [6, 30, 54], [6, 32, 58], [6, 34, 62],
    [6, 26, 46, 66], [6, 26, 48, 70], [6, 26, 50, 74], [6, 30, 54, 78], [6, 30, 56, 82],
    [6, 30, 58, 86], [6, 34, 62, 90],
    [6, 28, 50, 72, 94], [6, 26, 50, 74, 98], [6, 30, 54, 78, 102], [6, 28, 54, 80, 106],
    [6, 32, 58, 84, 110], [6, 30, 58, 86, 114], [6, 34, 62, 90, 118],
    [6, 26, 50, 74, 98, 122], [6, 30, 54, 78, 102, 126], [6, 26, 52, 78, 104, 130],
    [6, 30, 56, 82, 108, 134], [6, 34, 60, 86, 112, 138], [6, 30, 58, 86, 114, 142],
    [6, 34, 62, 90, 118, 146],
    [6, 30, 54, 78, 102, 126, 150], [6, 24, 50, 76, 102, 128, 154], [6, 28, 54, 80, 106, 132, 158],
    [6, 32, 58, 84, 110, 136, 162], [6, 26, 54, 82, 110, 138, 166], [6, 30, 58, 86, 114, 142, 170]
  ].freeze

  # 2-bit error correction level indicator in the format information (Table 12).
  LEVEL_BITS = { L: 0b01, M: 0b00, Q: 0b11, H: 0b10 }.freeze

  MODE_INDICATORS = {
    numeric: 0b0001, alphanumeric: 0b0010, byte: 0b0100, kanji: 0b1000, hanzi: 0b1101,
    eci: 0b0111, fnc1_first: 0b0101, fnc1_second: 0b1001, structured_append: 0b0011
  }.freeze

  # Character count indicator lengths for versions 1-9, 10-26 and 27-40 (Table 3).
  COUNT_BITS = {
    numeric: [10, 12, 14], alphanumeric: [9, 11, 13], byte: [8, 16, 16], kanji: [8, 10, 12], hanzi: [8, 10, 12]
  }.freeze

  ALPHANUMERIC_CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
  ALPHANUMERIC_VALUES = ALPHANUMERIC_CHARSET.each_char.with_index.to_h.freeze
  # Alphanumeric value by byte (nil for bytes outside the character set).
  ALPHANUMERIC_BYTES = Array.new(256) { |b| ALPHANUMERIC_VALUES[b.chr] }.freeze

  # After FNC1, alphanumeric segments write GS as "%" and "%" as "%%"; a GS
  # followed by "%" has no unambiguous encoding within one segment.
  AMBIGUOUS_GS = "\x1D%".b.freeze

  # GB2312 subset indicator following the Hanzi mode indicator.
  HANZI_SUBSET_GB2312 = 0b0001

  # Pad codewords appended alternately after the terminator (§7.4.10).
  PAD_CODEWORDS = [0xEC, 0x11].freeze

  FORMAT_GENERATOR = 0x537
  FORMAT_MASK = 0x5412
  VERSION_GENERATOR = 0x1F25

  # GF(256) with the QR primitive polynomial x^8 + x^4 + x^3 + x^2 + 1.
  GF_EXP = Array.new(512, 0)
  GF_LOG = Array.new(256, 0)
  value = 1
  255.times do |i|
    GF_EXP[i] = value
    GF_LOG[value] = i
    value <<= 1
    value ^= 0x11D if value > 0xFF
  end
  255.upto(511) { |i| GF_EXP[i] = GF_EXP[i - 255] }
  GF_EXP.freeze
  GF_LOG.freeze

  # Penalty rule N3 (§7.8.3.1, Table 11): a dark:light:dark:light:dark
  # 1:1:3:1:1 run preceded or followed by 4 light modules scores once; the
  # area outside the symbol counts as light. This reading agrees with zint
  # (zxing-cpp's writer) on every mask choice; counting both sides or
  # requiring a light module after the outer dark run does not.
  FINDER_CORE = "\1\0\1\1\1\0\1".b.freeze
  LIGHT4 = "\0\0\0\0".b.freeze
  # Rule N1: runs of 5 or more same-coloured modules (rows separated by "\x02").
  LIGHT_RUN = /\x00{5,}/n
  DARK_RUN = /\x01{5,}/n
  ROW_BREAK = "\x02".b.freeze

  # Per-version module layout (function pattern template and data module order).
  Layout = Data.define(:version, :dimension, :function, :template, :data_positions, :format_positions) do
    def raw_codewords
      data_positions.size / 8
    end

    def remainder_bits
      data_positions.size % 8
    end
  end

  class << self
    # Encodes +content+ and returns the symbol as a QrReader::BitMatrix.
    # See #build for the options.
    def encode(content, **options)
      build(content, **options).matrix
    end

    # Encodes +content+ and returns an Encoded with the matrix and all
    # intermediate data.
    #
    # content: a String (single segment; +mode+ picks the mode, nil = the
    #   most compact of numeric/alphanumeric/byte) or an Array of segments:
    #   [:numeric | :alphanumeric | :byte | :kanji | :hanzi, String], [:eci, Integer],
    #   [:fnc1_first], [:fnc1_second, Integer | letter], [:structured_append, index, count, parity],
    #   or a plain String (auto mode). Byte segments use the String's bytes
    #   as-is (UTF-8 for ordinary literals); kanji/hanzi segments are
    #   transcoded to Shift_JIS/GB2312. After an FNC1 indicator, "\x1D" (GS)
    #   in alphanumeric segments is written as "%" and "%" as "%%" (a GS
    #   directly followed by "%" has no such encoding: explicit alphanumeric
    #   segments raise, automatic mode picks byte mode).
    # version: 1..40 or nil (smallest that fits)
    # level: :L, :M, :Q, :H (lowercase Symbols and Strings are accepted too)
    # mask: 0..7 or nil (lowest penalty score, §7.8.3)
    # eci: designator inserted before the data (after any structured append header)
    # fnc1: :first or [:second, application_indicator] inserted before the data
    # structured_append: [index, count, parity] (or Hash/StructuredAppend);
    #   parity nil = XOR of this symbol's own data bytes
    # corrupt_codewords: n distinct random codewords are XORed with a random
    #   non-zero value (anywhere in the symbol)
    # corrupt_per_block: n (or :max = floor(ecc/2)) random codewords in every block
    # corrupt_modules: n distinct random data-region modules are flipped (a
    #   flipped remainder bit damages no codeword)
    # seed: Integer seed for all corruption randomness
    def build(content, version: nil, level: :M, mask: nil, mode: nil, eci: nil, fnc1: nil,
              structured_append: nil, corrupt_codewords: 0, corrupt_per_block: 0,
              corrupt_modules: 0, seed: 0)
      level = check_level(level)
      check_mask(mask) unless mask.nil?
      check_count(:corrupt_codewords, corrupt_codewords)
      check_count(:corrupt_per_block, corrupt_per_block) unless corrupt_per_block == :max
      check_count(:corrupt_modules, corrupt_modules)
      raise Error, "seed must be an Integer" unless seed.is_a?(Integer)

      segments = segments_for(content, mode, eci, fnc1, structured_append)
      version = choose_version(segments, level, version)
      bits = segments_bits(segments, version)
      data = data_codewords(bits, version, level)
      blocks, codewords, block_positions = error_correct(data, version, level)

      rng = Random.new(seed)
      damaged = codewords.dup
      corrupted_codewords = corrupt!(damaged, block_positions, corrupt_codewords, corrupt_per_block, level, version, rng)

      layout = layout(version)
      cells = place(layout, damaged)
      mask ||= best_mask(layout, cells, level)
      cells = apply_mask(layout, cells, mask)
      draw_format(layout, cells, level, mask)
      corrupted_modules = flip_modules!(layout, cells, corrupt_modules, rng)

      Encoded.new(matrix: QrReader::BitMatrix.new(layout.dimension, layout.dimension, cells),
                  version: version, level: level, mask: mask, segments: segments.freeze,
                  bit_length: bits.size, data_codewords: data.freeze, blocks: blocks.freeze,
                  codewords: codewords.freeze,
                  corrupted: { codewords: corrupted_codewords, modules: corrupted_modules }.freeze)
    end

    # Smallest version that holds +content+ at +level+ (same content options
    # as #build), without building the symbol.
    def version_for(content, level: :M, mode: nil, eci: nil, fnc1: nil, structured_append: nil)
      choose_version(segments_for(content, mode, eci, fnc1, structured_append), check_level(level), nil)
    end

    # Data codeword count of every RS block (shorter blocks first) and the
    # EC codewords per block: [[data1, data2, ...], ecc].
    def block_sizes(version, level)
      raw = layout(version).raw_codewords
      level = check_level(level)
      num_blocks = NUM_BLOCKS[level][version]
      ecc = ECC_PER_BLOCK[level][version]
      short_blocks = num_blocks - (raw % num_blocks)
      short_data = (raw / num_blocks) - ecc
      [Array.new(num_blocks) { |b| b < short_blocks ? short_data : short_data + 1 }, ecc]
    end

    # Splits +text+ into exactly +count+ symbols (character counts differing
    # by at most one) linked by Structured Append headers. The parity is the
    # XOR of the whole message as transmitted in 8-bit form (Shift_JIS for
    # :kanji, GB2312 for :hanzi). Returns an Array of Encoded.
    def structured_append_series(text, count, mode: :byte, **options)
      raise Error, "structured append supports 2..16 symbols" unless count.is_a?(Integer) && count.between?(2, 16)
      raise Error, "text must be a String" unless text.is_a?(String)

      chars = text.each_char.to_a
      raise Error, "text too short for #{count} symbols" if chars.size < count

      base, extra = chars.size.divmod(count)
      offset = 0
      parts = Array.new(count) do |i|
        size = i < extra ? base + 1 : base
        offset += size
        chars[offset - size, size].join
      end
      fnc1 = !options[:fnc1].nil?
      parity = parts.sum("".b) { |part| segment_payload_bytes(segment(mode, part, fnc1: fnc1), fnc1) }.bytes.reduce(0, :^)
      parts.each_with_index.map do |part, i|
        build([[mode, part]], structured_append: [i, count, parity], **options)
      end
    end

    # Number of data bits available in a symbol of +version+ and +level+.
    def capacity_bits(version, level)
      data_codeword_count(version, level) * 8
    end

    def data_codeword_count(version, level)
      raw = layout(version).raw_codewords
      level = check_level(level)
      raw - ECC_PER_BLOCK[level][version] * NUM_BLOCKS[level][version]
    end

    # Axis-aligned rendering of a module matrix as a QrReader::Image.
    def render(matrix, module_size: 4, quiet: 4, dark: 0, light: 255)
      raise Error, "module_size must be a positive Integer" unless module_size.is_a?(Integer) && module_size.positive?
      raise Error, "quiet must be a non-negative Integer" unless quiet.is_a?(Integer) && !quiet.negative?
      raise Error, "dark and light must be gray levels 0..255" unless [dark, light].all? { |v| v.is_a?(Integer) && v.between?(0, 255) }

      n = matrix.width
      m = matrix.height
      side_w = (n + 2 * quiet) * module_size
      side_h = (m + 2 * quiet) * module_size
      light_row = light.chr.b * side_w
      out = String.new(capacity: side_w * side_h, encoding: Encoding::BINARY)
      (quiet * module_size).times { out << light_row }
      dark_run = dark.chr.b * module_size
      light_run = light.chr.b * module_size
      margin = light.chr.b * (quiet * module_size)
      bits = matrix.bits
      y = 0
      while y < m
        line = margin.dup
        x = 0
        off = y * n
        while x < n
          line << (bits.getbyte(off + x) == 1 ? dark_run : light_run)
          x += 1
        end
        line << margin
        module_size.times { out << line }
        y += 1
      end
      (quiet * module_size).times { out << light_row }
      QrReader::Image.new(side_w, side_h, out)
    end

    # 15-bit format information word (BCH(15,5), XOR-masked) for +level+/+mask+.
    def format_bits(level, mask)
      check_mask(mask)
      data = (LEVEL_BITS[check_level(level)] << 3) | mask
      rem = data
      10.times { rem = (rem << 1) ^ ((rem >> 9) * FORMAT_GENERATOR) }
      ((data << 10) | rem) ^ FORMAT_MASK
    end

    # 18-bit version information word (BCH(18,6)) for versions 7..40.
    def version_bits(version)
      rem = version
      12.times { rem = (rem << 1) ^ ((rem >> 11) * VERSION_GENERATOR) }
      (version << 12) | rem
    end

    # Reads the format information (first copy, around the top-left finder)
    # of a symbol: [level, mask] or nil if it is not a valid code word.
    def read_format(matrix)
      positions = layout(dimension_version(matrix.width)).format_positions[0]
      bits = 0
      14.downto(0) { |i| bits = (bits << 1) | matrix.bits.getbyte(positions[i]) }
      LEVELS.each do |level|
        8.times { |mask| return [level, mask] if format_bits(level, mask) == bits }
      end
      nil
    end

    # Reads the interleaved codewords back from a symbol (mask taken from the
    # first format information copy, which must be error free). Handy to
    # compare a sampled grid with Encoded#codewords codeword by codeword.
    def read_codewords(matrix)
      layout = layout(dimension_version(matrix.width))
      format = read_format(matrix) or raise Error, "format information unreadable"
      cells = apply_mask(layout, matrix.bits, format[1])
      positions = layout.data_positions
      bits = String.new(capacity: positions.size)
      (layout.raw_codewords * 8).times { |i| bits << (cells.getbyte(positions[i]) == 1 ? "1" : "0") }
      [bits].pack("B*").bytes
    end

    # Penalty score of a finished symbol (§7.8.3.1, rules N1..N4).
    def penalty(matrix)
      raise Error, "penalty needs a square matrix" unless matrix.width == matrix.height

      score_cells(matrix.bits, matrix.width)
    end

    # Module layout for +version+ (memoized).
    def layout(version)
      raise Error, "version must be 1..40" unless version.is_a?(Integer) && version.between?(1, 40)

      (@layouts ||= {})[version] ||= build_layout(version)
    end

    # Reed-Solomon error correction codewords for +data+ (Array<Integer>).
    def rs_remainder(data, degree)
      gen = generator_log(degree)
      res = Array.new(degree, 0)
      data.each do |byte|
        factor = byte ^ res.shift
        res << 0
        next if factor.zero?

        lf = GF_LOG[factor]
        i = 0
        while i < degree
          res[i] ^= GF_EXP[lf + gen[i]]
          i += 1
        end
      end
      res
    end

    private

    # --- segments ----------------------------------------------------------

    def check_level(level)
      return level if LEVEL_BITS.key?(level)

      normalized = level.to_s.upcase.to_sym if level.is_a?(Symbol) || level.is_a?(String)
      raise Error, "unknown EC level #{level.inspect}" unless LEVEL_BITS.key?(normalized)

      normalized
    end

    def check_mask(mask)
      raise Error, "mask must be 0..7" unless mask.is_a?(Integer) && mask.between?(0, 7)
    end

    def check_count(name, value)
      raise Error, "#{name} must be a non-negative Integer" unless value.is_a?(Integer) && !value.negative?
    end

    # The characters of a numeric/alphanumeric segment as a binary String
    # (ASCII-incompatible encodings such as UTF-16 are transcoded first).
    def plain_bytes(value)
      text = value.to_s
      text = text.encode(Encoding::UTF_8) unless text.encoding.ascii_compatible?
      text.b
    rescue EncodingError => e
      raise Error, "cannot read #{text.inspect} as characters: #{e.message}"
    end

    def segments_for(content, mode, eci, fnc1, structured_append)
      fill_structured_append_parity(header_segments(structured_append, eci, fnc1) + parse_content(content, mode, fnc1))
    end

    def header_segments(structured_append, eci, fnc1)
      out = []
      if structured_append
        sa = case structured_append
             when Hash then structured_append.values_at(:index, :count, :parity)
             when Array then structured_append
             when QrReader::StructuredAppend then structured_append.to_h.values_at(:index, :count, :parity)
             else raise Error, "structured_append must be [index, count, parity]"
             end
        out << segment(:structured_append, *sa)
      end
      out << segment(:eci, eci) if eci
      case fnc1
      when nil then nil
      when :first then out << segment(:fnc1_first)
      when Array
        raise Error, "fnc1 must be :first or [:second, indicator]" unless fnc1[0] == :second

        out << segment(:fnc1_second, fnc1[1])
      else raise Error, "fnc1 must be :first or [:second, indicator]"
      end
      out
    end

    def parse_content(content, mode, fnc1)
      fnc1_active = !fnc1.nil?
      if content.is_a?(String)
        return [segment(mode || auto_mode(content, fnc1_active), content, fnc1: fnc1_active)]
      end
      raise Error, "content must be a String or an Array of segments" unless content.is_a?(Array)

      content.map do |item|
        seg = case item
              when String then segment(auto_mode(item, fnc1_active), item, fnc1: fnc1_active)
              when Array
                raise Error, "empty segment specification" if item.empty?

                segment(*item, fnc1: fnc1_active)
              else raise Error, "segment must be a String or [mode, data...], got #{item.inspect}"
              end
        fnc1_active ||= %i[fnc1_first fnc1_second].include?(seg.mode)
        seg
      end
    end

    # Most compact of numeric/alphanumeric/byte. Strings with invalid or
    # ASCII-incompatible encodings are byte data.
    def auto_mode(text, fnc1)
      return :byte unless text.encoding.ascii_compatible? && text.valid_encoding?

      bytes = text.b
      if bytes.match?(/\A[0-9]*\z/n)
        :numeric
      elsif bytes.each_byte.all? { |c| ALPHANUMERIC_BYTES[c] || (fnc1 && c == 0x1D) } &&
            !(fnc1 && bytes.include?(AMBIGUOUS_GS))
        :alphanumeric
      else
        :byte
      end
    end

    # Validates and normalizes one segment specification.
    def segment(mode, *args, fnc1: false)
      mode = :byte if mode == :byte_8bit
      mode = :numeric if mode == :number
      value = args.first
      case mode
      when :numeric
        text = plain_bytes(value)
        raise Error, "invalid numeric data #{text.inspect}" unless text.match?(/\A[0-9]*\z/n)

        Segment.new(:numeric, text)
      when :alphanumeric
        text = plain_bytes(value)
        if fnc1
          # GS% would be written as %%%, which decoders read as %GS.
          raise Error, "GS followed by % cannot be encoded in one alphanumeric segment; split it" if text.include?(AMBIGUOUS_GS)

          text = text.gsub("%", "%%").tr("\x1D", "%")
        end
        bad = text.each_byte.reject { |c| ALPHANUMERIC_BYTES[c] }
        raise Error, "invalid alphanumeric characters #{bad.uniq.pack('C*').inspect}" unless bad.empty?

        Segment.new(:alphanumeric, text)
      when :byte then Segment.new(:byte, value.to_s.b)
      when :kanji, :hanzi then Segment.new(mode, double_byte_values(value.to_s, mode))
      when :eci
        raise Error, "ECI designator must be 0..999999" unless value.is_a?(Integer) && value.between?(0, 999_999)

        Segment.new(:eci, value)
      when :fnc1_first then Segment.new(:fnc1_first, nil)
      when :fnc1_second
        value = value.ord + 100 if value.is_a?(String) && value.match?(/\A[A-Za-z]\z/)
        raise Error, "FNC1 application indicator must be 0..255 or a letter" unless value.is_a?(Integer) && value.between?(0, 255)

        Segment.new(:fnc1_second, value)
      when :structured_append
        index, count, parity = args
        unless index.is_a?(Integer) && count.is_a?(Integer) && count.between?(1, 16) && index.between?(0, count - 1)
          raise Error, "structured append needs 0 <= index < count <= 16"
        end
        raise Error, "parity must be 0..255" unless parity.nil? || (parity.is_a?(Integer) && parity.between?(0, 255))

        Segment.new(:structured_append, [index, count, parity])
      else
        raise Error, "unknown segment mode #{mode.inspect}"
      end
    end

    # 13-bit values of Kanji (Shift_JIS, §7.4.6) or Hanzi (GB2312) characters.
    def double_byte_values(text, mode)
      encoded = mode == :kanji ? to_shift_jis(text) : transcode(text, "GB2312")
      encoded.each_char.map do |char|
        raise Error, "#{char.inspect} is not a double-byte #{mode} character" unless char.bytesize == 2

        code = (char.getbyte(0) << 8) | char.getbyte(1)
        if mode == :kanji
          code -= if code.between?(0x8140, 0x9FFC) then 0x8140
                  elsif code.between?(0xE040, 0xEBBF) then 0xC140
                  else raise Error, "Shift_JIS 0x#{code.to_s(16)} outside the Kanji mode ranges"
                  end
          ((code >> 8) * 0xC0) + (code & 0xFF)
        else
          code -= if code.between?(0xA1A1, 0xAAFE) then 0xA1A1
                  elsif code.between?(0xB0A1, 0xFAFE) then 0xA6A1
                  else raise Error, "GB2312 0x#{code.to_s(16)} outside the Hanzi mode ranges"
                  end
          ((code >> 8) * 0x60) + (code & 0xFF)
        end
      end
    end

    def to_shift_jis(text)
      transcode(text, "Shift_JIS")
    rescue Error
      transcode(text, "Windows-31J")
    end

    def transcode(text, encoding)
      return text if text.encoding == Encoding.find(encoding)

      text.encode(encoding)
    rescue EncodingError => e
      raise Error, "cannot encode #{text.inspect} as #{encoding}: #{e.message}"
    end

    def fill_structured_append_parity(segments)
      segments.map do |seg|
        next seg unless seg.mode == :structured_append && seg.data[2].nil?

        Segment.new(:structured_append, [seg.data[0], seg.data[1], message_parity(segments)])
      end
    end

    # XOR of the bytes of all data segments (see #segment_payload_bytes).
    def message_parity(segments)
      fnc1 = false
      parity = 0
      segments.each do |seg|
        fnc1 ||= %i[fnc1_first fnc1_second].include?(seg.mode)
        segment_payload_bytes(seg, fnc1).each_byte { |b| parity ^= b }
      end
      parity
    end

    # Bytes contributing to the structured append parity: the data as it
    # would be transmitted in 8-bit form (the Shift_JIS / GB2312 code of
    # every Kanji / Hanzi, recovered from its 13-bit value; GS and "%" in
    # alphanumeric segments after FNC1, not their "%" / "%%" escapes).
    def segment_payload_bytes(seg, fnc1 = false)
      case seg.mode
      when :alphanumeric
        fnc1 ? seg.data.gsub(/%%?/n) { |m| m == "%%" ? "%" : "\x1D" } : seg.data.b
      when :numeric, :byte then seg.data.b
      when :kanji
        seg.data.map do |v|
          code = ((v / 0xC0) << 8) | (v % 0xC0)
          code + (code < 0x1F00 ? 0x8140 : 0xC140)
        end.pack("n*")
      when :hanzi
        seg.data.map do |v|
          code = ((v / 0x60) << 8) | (v % 0x60)
          code + (code < 0x0A00 ? 0xA1A1 : 0xA6A1)
        end.pack("n*")
      else "".b
      end
    end

    # --- bit stream --------------------------------------------------------

    def version_class(version)
      if version <= 9 then 0
      elsif version <= 26 then 1
      else 2
      end
    end

    def choose_version(segments, level, version)
      if version
        raise Error, "version must be 1..40" unless version.is_a?(Integer) && version.between?(1, 40)

        needed = segments_bits(segments, version).size
        capacity = capacity_bits(version, level)
        raise Error, "data needs #{needed} bits, version #{version}-#{level} holds #{capacity}" if needed > capacity

        return version
      end

      # The bit length only changes with the character count lengths (three
      # version ranges); nil when a count overflows that range.
      lengths = {}
      1.upto(40) do |v|
        vc = version_class(v)
        unless lengths.key?(vc)
          lengths[vc] = begin
            segments_bits(segments, v).size
          rescue CountOverflow
            nil
          end
        end
        return v if lengths[vc] && lengths[vc] <= capacity_bits(v, level)
      end
      raise Error, "data does not fit in a version 40-#{level} symbol"
    end

    # The bit stream of all segments as a String of "0"/"1" characters.
    def segments_bits(segments, version)
      vc = version_class(version)
      out = +""
      segments.each { |seg| append_segment(out, seg, vc) }
      out
    end

    def put(out, value, length)
      out << value.to_s(2).rjust(length, "0")
    end

    def append_segment(out, seg, vc)
      put(out, MODE_INDICATORS.fetch(seg.mode), 4)
      data = seg.data
      case seg.mode
      when :numeric
        count_indicator(out, :numeric, data.size, vc)
        data.scan(/\d{1,3}/) { |g| put(out, g.to_i, g.size * 3 + 1) }
      when :alphanumeric
        count_indicator(out, :alphanumeric, data.bytesize, vc)
        values = data.bytes.map { |b| ALPHANUMERIC_BYTES[b] }
        values.each_slice(2) { |a, b| b ? put(out, a * 45 + b, 11) : put(out, a, 6) }
      when :byte
        count_indicator(out, :byte, data.bytesize, vc)
        data.each_byte { |b| put(out, b, 8) }
      when :kanji, :hanzi
        put(out, HANZI_SUBSET_GB2312, 4) if seg.mode == :hanzi
        count_indicator(out, seg.mode, data.size, vc)
        data.each { |v| put(out, v, 13) }
      when :eci
        if data < 128 then put(out, data, 8)
        elsif data < 16_384 then put(out, 0b10 << 14 | data, 16)
        else put(out, 0b110 << 21 | data, 24)
        end
      when :fnc1_second then put(out, data, 8)
      when :structured_append
        index, count, parity = data
        put(out, index, 4)
        put(out, count - 1, 4)
        put(out, parity, 8)
      end
    end

    def count_indicator(out, mode, count, vc)
      bits = COUNT_BITS.fetch(mode)[vc]
      raise CountOverflow, "#{mode} segment too long (#{count} characters, max #{(1 << bits) - 1})" if count >= (1 << bits)

      put(out, count, bits)
    end

    # Terminator (up to 4 zero bits), zero bits to the next codeword
    # boundary, then alternating pad codewords (§7.4.9, §7.4.10).
    def data_codewords(bits, version, level)
      capacity = capacity_bits(version, level)
      stream = bits + ("0" * [4, capacity - bits.size].min)
      stream << ("0" * (-stream.size % 8))
      codewords = [stream].pack("B*").bytes
      pads = codewords.size
      codewords << PAD_CODEWORDS[(codewords.size - pads) % 2] while codewords.size < capacity / 8
      codewords
    end

    # --- error correction --------------------------------------------------

    # Splits +data+ into RS blocks (shorter blocks first), appends the EC
    # codewords and interleaves them (§7.6). Returns [blocks, codewords,
    # block_positions] where block_positions[b] lists the interleaved index
    # of every codeword of block b (data first, then EC).
    def error_correct(data, version, level)
      sizes, ecc = block_sizes(version, level)
      offset = 0
      blocks = sizes.map do |size|
        chunk = data[offset, size]
        offset += size
        [chunk, rs_remainder(chunk, ecc)]
      end

      codewords = []
      positions = Array.new(blocks.size) { [] }
      sizes.max.times do |i|
        blocks.each_with_index do |(chunk, _), b|
          next if i >= chunk.size

          positions[b] << codewords.size
          codewords << chunk[i]
        end
      end
      ecc.times do |i|
        blocks.each_with_index do |(_, ec), b|
          positions[b] << codewords.size
          codewords << ec[i]
        end
      end
      [blocks, codewords, positions]
    end

    # Log-domain coefficients of the RS generator polynomial prod (x - a^i),
    # i = 0...degree, highest power first, leading 1 omitted.
    def generator_log(degree)
      (@generators ||= {})[degree] ||= begin
        poly = [1]
        degree.times do |i|
          next_poly = poly + [0]
          poly.each_with_index { |c, j| next_poly[j + 1] ^= gf_mul(c, GF_EXP[i]) }
          poly = next_poly
        end
        poly.drop(1).map { |c| GF_LOG[c] }.freeze
      end
    end

    def gf_mul(a, b)
      a.zero? || b.zero? ? 0 : GF_EXP[GF_LOG[a] + GF_LOG[b]]
    end

    def corrupt!(codewords, block_positions, count, per_block, level, version, rng)
      indices = []
      if per_block == :max || (per_block.is_a?(Integer) && per_block.positive?)
        k = per_block == :max ? ECC_PER_BLOCK.fetch(level)[version] / 2 : per_block
        block_positions.each do |positions|
          raise Error, "cannot corrupt #{k} codewords of a #{positions.size}-codeword block" if k > positions.size

          indices.concat(positions.sample(k, random: rng))
        end
      end
      if count.positive?
        raise Error, "cannot corrupt #{count} of #{codewords.size} codewords" if count > codewords.size

        indices.concat((0...codewords.size).to_a.sample(count, random: rng))
      end
      indices = indices.uniq.sort
      indices.each { |i| codewords[i] ^= rng.rand(1..255) }
      indices.freeze
    end

    # --- matrix ------------------------------------------------------------

    def dimension_version(dimension)
      version = (dimension - 17) / 4
      raise Error, "invalid symbol dimension #{dimension}" unless 17 + 4 * version == dimension && version.between?(1, 40)

      version
    end

    # Draws all function patterns of +version+ into a template and records
    # which modules they occupy; the remaining modules, in placement order,
    # are the data region.
    def build_layout(version)
      n = 17 + 4 * version
      cells = "\0".b * (n * n)
      function = "\0".b * (n * n)
      set = lambda do |x, y, dark|
        cells.setbyte(y * n + x, dark ? 1 : 0)
        function.setbyte(y * n + x, 1)
      end

      # Timing patterns (finders and alignment patterns overwrite their ends).
      n.times do |i|
        set.call(6, i, i.even?)
        set.call(i, 6, i.even?)
      end
      # Finder patterns with their light separators.
      [[3, 3], [n - 4, 3], [3, n - 4]].each do |cx, cy|
        (-4..4).each do |dy|
          (-4..4).each do |dx|
            x = cx + dx
            y = cy + dy
            next unless x.between?(0, n - 1) && y.between?(0, n - 1)

            dist = [dx.abs, dy.abs].max
            set.call(x, y, dist != 2 && dist != 4)
          end
        end
      end
      # Alignment patterns, except the three that would overlap finders.
      centers = ALIGNMENT_POSITIONS[version]
      last = centers.size - 1
      centers.each_with_index do |cy, j|
        centers.each_with_index do |cx, i|
          next if (i.zero? && j.zero?) || (i.zero? && j == last) || (i == last && j.zero?)

          (-2..2).each { |dy| (-2..2).each { |dx| set.call(cx + dx, cy + dy, [dx.abs, dy.abs].max != 1) } }
        end
      end
      # Format information areas (filled per mask later) and the dark module.
      format = format_positions(n)
      format.flatten.each { |pos| function.setbyte(pos, 1) }
      set.call(8, n - 8, true)
      # Version information blocks (6x3 below/left of the top-right/bottom-left finders).
      if version >= 7
        bits = version_bits(version)
        18.times do |i|
          dark = bits[i] == 1
          a = n - 11 + i % 3
          b = i / 3
          set.call(a, b, dark)
          set.call(b, a, dark)
        end
      end

      Layout.new(version: version, dimension: n, function: function.freeze, template: cells.freeze,
                 data_positions: data_positions(n, function).freeze, format_positions: format)
    end

    # Linear indices of format bits 0..14 for both copies (Figure 25).
    def format_positions(n)
      first = Array.new(15)
      second = Array.new(15)
      15.times do |i|
        x, y = if i < 6 then [8, i]
               elsif i == 6 then [8, 7]
               elsif i == 7 then [8, 8]
               elsif i == 8 then [7, 8]
               else [14 - i, 8]
               end
        first[i] = y * n + x
        x, y = i < 8 ? [n - 1 - i, 8] : [8, n - 15 + i]
        second[i] = y * n + x
      end
      [first.freeze, second.freeze].freeze
    end

    # Data module order: two-module wide columns from the right, alternating
    # upwards and downwards, skipping the vertical timing pattern (§7.7.3).
    def data_positions(n, function)
      out = []
      right = n - 1
      upward = true
      while right >= 1
        right = 5 if right == 6
        n.times do |vert|
          y = upward ? n - 1 - vert : vert
          [right, right - 1].each do |x|
            pos = y * n + x
            out << pos if function.getbyte(pos).zero?
          end
        end
        upward = !upward
        right -= 2
      end
      out
    end

    # Unmasked matrix with the codewords placed (remainder bits light).
    def place(layout, codewords)
      cells = layout.template.dup
      positions = layout.data_positions
      bit_count = codewords.size * 8
      i = 0
      while i < bit_count
        cells.setbyte(positions[i], (codewords[i >> 3] >> (7 - (i & 7))) & 1)
        i += 1
      end
      cells
    end

    # Copy of +cells+ with data mask +mask+ applied to the encoding region
    # (remainder bits included).
    def apply_mask(layout, cells, mask)
      out = cells.dup
      flips = mask_flips(layout, mask)
      count = flips.size
      i = 0
      while i < count
        pos = flips[i]
        out.setbyte(pos, out.getbyte(pos) ^ 1)
        i += 1
      end
      out
    end

    # Data module indices that mask +mask+ inverts (memoized per version).
    def mask_flips(layout, mask)
      (@mask_flips ||= {})[layout.version * 8 + mask] ||= begin
        n = layout.dimension
        layout.data_positions.select { |pos| mask_bit?(mask, pos % n, pos / n) }.freeze
      end
    end

    # Data mask conditions (Table 10); i = row (y), j = column (x).
    def mask_bit?(mask, x, y)
      case mask
      when 0 then (y + x).even?
      when 1 then y.even?
      when 2 then (x % 3).zero?
      when 3 then ((y + x) % 3).zero?
      when 4 then ((y / 2) + (x / 3)).even?
      when 5 then ((y * x) % 2) + ((y * x) % 3) == 0
      when 6 then (((y * x) % 2) + ((y * x) % 3)).even?
      else (((y + x) % 2) + ((y * x) % 3)).even?
      end
    end

    def draw_format(layout, cells, level, mask)
      bits = format_bits(level, mask)
      layout.format_positions.each do |positions|
        15.times { |i| cells.setbyte(positions[i], bits[i]) }
      end
    end

    def best_mask(layout, cells, level)
      (0..7).min_by do |mask|
        candidate = apply_mask(layout, cells, mask)
        draw_format(layout, candidate, level, mask)
        score_cells(candidate, layout.dimension)
      end
    end

    def flip_modules!(layout, cells, count, rng)
      return [].freeze unless count.positive?

      positions = layout.data_positions
      raise Error, "cannot flip #{count} of #{positions.size} data modules" if count > positions.size

      n = layout.dimension
      positions.sample(count, random: rng).sort.map do |pos|
        cells.setbyte(pos, cells.getbyte(pos) ^ 1)
        pos.divmod(n).reverse
      end.freeze
    end

    # --- mask penalty (§7.8.3.1) -------------------------------------------

    # Rows and columns are scanned at C speed (Regexp, String#index); the
    # 2x2 rule uses Integer arithmetic over the whole grid.
    def score_cells(cells, n)
      transposed = transpose_cells(cells, n)
      row_format = (@row_formats ||= {})[n] ||= "a#{n}" * n
      score = 0
      [cells, transposed].each do |grid|
        lines = grid.unpack(row_format)
        score += run_penalty(lines.join(ROW_BREAK))
        score += 40 * finder_penalty_count(LIGHT4 + lines.join(LIGHT4) + LIGHT4)
      end
      score + (3 * uniform_blocks(cells, n)) + balance_penalty(cells, n)
    end

    def transpose_cells(cells, n)
      out = "\0".b * (n * n)
      y = 0
      while y < n
        x = 0
        off = y * n
        while x < n
          out.setbyte(x * n + y, cells.getbyte(off + x))
          x += 1
        end
        y += 1
      end
      out
    end

    # N1: 3 + (length - 5) for every run of >= 5 same-coloured modules.
    def run_penalty(lines)
      score = 0
      lines.scan(LIGHT_RUN) { |run| score += run.bytesize - 2 }
      lines.scan(DARK_RUN) { |run| score += run.bytesize - 2 }
      score
    end

    # N3: finder-like patterns in +lines+ (rows joined and framed by 4
    # light modules, so the symbol's surroundings count as light).
    def finder_penalty_count(lines)
      count = 0
      pos = 0
      while (pos = lines.index(FINDER_CORE, pos))
        count += 1 if lines.byteslice(pos - 4, 4) == LIGHT4 || lines.byteslice(pos + 7, 4) == LIGHT4
        pos += 1
      end
      count
    end

    # N2: number of 2x2 blocks of one colour. Each cell is one byte of a
    # big Integer; XOR with the grid shifted by one cell, one row and one
    # row + one cell leaves a zero byte exactly where a block ends.
    def uniform_blocks(cells, n)
      size = n * n
      grid = cells.unpack1("H*").to_i(16)
      diff = (grid ^ (grid >> 8)) | (grid ^ (grid >> (8 * n))) | (grid ^ (grid >> (8 * (n + 1))))
      ends = [diff.to_s(16).rjust(2 * size, "0")].pack("H*")
      count = ends.byteslice(n, size - n).count("\0")
      # Column 0 has no block ending there.
      y = 1
      while y < n
        count -= 1 if ends.getbyte(y * n).zero?
        y += 1
      end
      count
    end

    # N4: 10 points per 5 % deviation of the dark proportion from 50 %
    # (Table 11: k for 50 +- 5k % to 50 +- 5(k + 1) %). At an exact multiple
    # of 5 % the lower k is taken; ZXing takes the higher one. Symbols can
    # only hit that boundary at exactly 40/60 % (n divisible by 5), which
    # masked data practically never does.
    def balance_penalty(cells, n)
      total = n * n
      dark = cells.count("\x01")
      steps = ((((dark * 20) - (total * 10)).abs + total - 1) / total) - 1
      10 * [steps, 0].max # exactly 50 % is only possible for even sizes (not symbols)
    end
  end
end
