# frozen_string_literal: true

require_relative "../test_helper"

# Test support for the decoder: an rqrcode_core encoder with a caller-chosen
# mask, a bit writer for hand-built bit streams, and an independent minimal
# symbol builder (codewords -> module grid) written straight from ISO/IEC
# 18004 without using any of the decoder's own tables.
module DecoderTestHelper
  LEVELS = %i[L M Q H].freeze

  # rqrcode_core QRCode that uses a fixed data mask instead of evaluating all
  # eight (8x faster, and lets tests cover every mask).
  class FixedMaskQRCode < RQRCodeCore::QRCode
    def initialize(data, mask:, **options)
      @fixed_mask = mask
      super(data, **options)
    end

    private

    def get_best_mask_pattern # rubocop:disable Naming/AccessorMethodName
      @fixed_mask
    end
  end

  module_function

  # BitMatrix encoded by rqrcode_core. +data+ is a String or an Array of
  # { data:, mode: } segments; mode is :number, :alphanumeric or :byte_8bit.
  def rqr(data, version:, level:, mask:, mode: nil)
    options = { level: level.downcase, size: version }
    options[:mode] = mode if mode && data.is_a?(String)
    qr = FixedMaskQRCode.new(data, mask: mask, **options)
    QrReader::BitMatrix.from_rows(qr.modules)
  end

  # Maximum characters of one segment in +mode+ that fit the data capacity.
  def capacity(version, level, mode)
    bits = QrReader::SymbolVersion[version].data_codewords(level) * 8 - 4
    count_bits = { number: [10, 12, 14], alphanumeric: [9, 11, 13], byte_8bit: [8, 16, 16] }[mode]
    bits -= count_bits[version <= 9 ? 0 : (version <= 26 ? 1 : 2)]
    max = case mode
          when :number then bits / 10 * 3 + [0, 0, 0, 0, 1, 1, 1, 2, 2, 2][bits % 10]
          when :alphanumeric then bits / 11 * 2 + (bits % 11 >= 6 ? 1 : 0)
          else bits / 8
          end
    [max, { number: 7089, alphanumeric: 4296, byte_8bit: 2953 }[mode]].min
  end

  ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

  # Random payload of +length+ characters valid for +mode+.
  def payload(rng, mode, length)
    case mode
    when :number then Array.new(length) { rng.rand(10).to_s }.join
    when :alphanumeric then Array.new(length) { ALNUM[rng.rand(45)] }.join
    else Array.new(length) { (32 + rng.rand(95)).chr }.join
    end
  end

  # Collects bits MSB first; #to_data returns padded data codewords.
  class BitWriter
    attr_reader :size

    def initialize
      @bits = +""
      @size = 0
    end

    def put(value, count)
      raise ArgumentError, "#{value} does not fit in #{count} bits" if value.negative? || value >= (1 << count)

      @bits << value.to_s(2).rjust(count, "0") if count.positive?
      @size += count
      self
    end

    # Convenience writers for segments (+version+ selects count lengths).
    def numeric(digits, version)
      put(0b0001, 4).put(digits.size, count_bits(version, [10, 12, 14]))
      digits.scan(/\d{1,3}/).each { |g| put(g.to_i, [0, 4, 7, 10][g.size]) }
      self
    end

    def alphanumeric(text, version)
      put(0b0010, 4).put(text.size, count_bits(version, [9, 11, 13]))
      text.chars.each_slice(2) do |a, b|
        b ? put(ALNUM.index(a) * 45 + ALNUM.index(b), 11) : put(ALNUM.index(a), 6)
      end
      self
    end

    def bytes(data, version)
      data = data.b
      put(0b0100, 4).put(data.bytesize, count_bits(version, [8, 16, 16]))
      data.each_byte { |b| put(b, 8) }
      self
    end

    # +sjis+: Shift_JIS bytes of double-byte characters.
    def kanji(sjis, version)
      sjis = sjis.b
      put(0b1000, 4).put(sjis.bytesize / 2, count_bits(version, [8, 10, 12]))
      sjis.bytes.each_slice(2) do |hi, lo|
        code = (hi << 8) | lo
        code -= code <= 0x9FFC ? 0x8140 : 0xC140
        put((code >> 8) * 0xC0 + (code & 0xFF), 13)
      end
      self
    end

    # +gb+: GB 2312 bytes of double-byte characters.
    def hanzi(gb, version, subset: 1)
      gb = gb.b
      put(0b1101, 4).put(subset, 4).put(gb.bytesize / 2, count_bits(version, [8, 10, 12]))
      gb.bytes.each_slice(2) do |hi, lo|
        code = (hi << 8) | lo
        code -= code <= 0xAAFE ? 0xA1A1 : 0xA6A1
        put((code >> 8) * 0x60 + (code & 0xFF), 13)
      end
      self
    end

    def eci(value)
      put(0b0111, 4)
      if value < 128 then put(value, 8)
      elsif value < 16_384 then put(0b10, 2).put(value, 14)
      else put(0b110, 3).put(value, 21)
      end
    end

    def fnc1_first
      put(0b0101, 4)
    end

    def fnc1_second(indicator)
      put(0b1001, 4).put(indicator, 8)
    end

    def structured_append(index, count, parity)
      put(0b0011, 4).put(index, 4).put(count - 1, 4).put(parity, 8)
    end

    def terminator
      put(0, 4)
    end

    # Bits packed into bytes (zero padded to a byte boundary). With
    # +capacity+ (data codewords), adds a terminator as far as it fits and
    # the 0xEC/0x11 pad codewords.
    def to_data(capacity = nil)
      bits = @bits.dup
      if capacity
        raise ArgumentError, "#{bits.size} bits exceed #{capacity} codewords" if bits.size > capacity * 8

        bits << "0" * [4, capacity * 8 - bits.size].min
      end
      bits << "0" * (-bits.size % 8)
      data = [bits].pack("B*")
      if capacity
        pad = [0xEC, 0x11]
        data << pad[(data.bytesize - bits.size / 8) % 2] while data.bytesize < capacity
      end
      data
    end

    private

    def count_bits(version, sizes)
      sizes[version <= 9 ? 0 : (version <= 26 ? 1 : 2)]
    end
  end

  # Independent symbol builder: data codewords -> BitMatrix.
  module SymbolBuilder
    EXP = Array.new(512)
    LOG = Array.new(256)
    x = 1
    255.times do |i|
      EXP[i] = EXP[i + 255] = x
      LOG[x] = i
      x = (x << 1) ^ (x >= 128 ? 0x11D : 0)
    end
    EXP[510] = EXP[0]
    EXP[511] = EXP[1]

    module_function

    def gf_mul(a, b)
      a.zero? || b.zero? ? 0 : EXP[LOG[a] + LOG[b]]
    end

    # Generator polynomial coefficients, highest degree first.
    def generator(ec)
      g = [1]
      ec.times do |i|
        g = (g + [0]).each_with_index.map { |c, k| c ^ (k.positive? ? gf_mul(g[k - 1], EXP[i]) : 0) }
      end
      g
    end

    def rs_encode(data, ec)
      g = generator(ec)
      rem = Array.new(ec, 0)
      data.each do |d|
        factor = d ^ rem.shift
        rem << 0
        ec.times { |k| rem[k] ^= gf_mul(g[k + 1], factor) }
      end
      rem
    end

    # Data codewords (binary String or Array) -> all codewords, interleaved.
    def codewords(data, version, level)
      data = data.bytes if data.is_a?(String)
      blocks = QrReader::SymbolVersion[version].ec_blocks(level)
      raise ArgumentError, "need #{blocks.total_data_codewords} data codewords" if data.size != blocks.total_data_codewords

      offset = 0
      data_blocks = blocks.data_codewords_per_block.map do |count|
        offset += count
        data[offset - count, count]
      end
      ec_blocks = data_blocks.map { |d| rs_encode(d, blocks.ec_codewords_per_block) }
      out = []
      data_blocks.map(&:size).max.times { |i| data_blocks.each { |d| out << d[i] if i < d.size } }
      blocks.ec_codewords_per_block.times { |i| ec_blocks.each { |e| out << e[i] } }
      out
    end

    def bch(value, data_bits, generator, total_bits)
      rem = value << (total_bits - data_bits)
      (total_bits - 1).downto(total_bits - data_bits) do |bit|
        rem ^= generator << (bit - (total_bits - data_bits)) if rem[bit] == 1
      end
      (value << (total_bits - data_bits)) | rem
    end

    def masked?(mask, i, j) # i = row, j = column (ISO notation)
      case mask
      when 0 then (i + j) % 2 == 0
      when 1 then i % 2 == 0
      when 2 then j % 3 == 0
      when 3 then (i + j) % 3 == 0
      when 4 then ((i / 2) + (j / 3)) % 2 == 0
      when 5 then (i * j) % 2 + (i * j) % 3 == 0
      when 6 then ((i * j) % 2 + (i * j) % 3) % 2 == 0
      when 7 then ((i + j) % 2 + (i * j) % 3) % 2 == 0
      end
    end

    # Builds the symbol. +format_bits+ / +version_bits+ override the BCH
    # words (e.g. to write broken ones); +corrupt+ may modify the final
    # interleaved codewords (an Array) before they are placed.
    def build(data, version:, level:, mask:, format_bits: nil, version_bits: nil, corrupt: nil)
      n = 17 + 4 * version
      grid = Array.new(n) { Array.new(n) } # nil = free for data
      finder = lambda do |row, col|
        (-1..7).each do |r|
          (-1..7).each do |c|
            rr = row + r
            cc = col + c
            next unless rr.between?(0, n - 1) && cc.between?(0, n - 1)

            ring = [r, c].max == 6 || [r, c].min.zero?
            grid[rr][cc] = r.between?(0, 6) && c.between?(0, 6) && (ring || (r.between?(2, 4) && c.between?(2, 4)))
          end
        end
      end
      finder.call(0, 0)
      finder.call(0, n - 7)
      finder.call(n - 7, 0)
      # Alignment patterns (before timing: centres on row/column 6 must be drawn).
      centers = QrReader::SymbolVersion[version].alignment_centers
      centers.product(centers).each do |r, c|
        next unless grid[r][c].nil?

        (-2..2).each { |dr| (-2..2).each { |dc| grid[r + dr][c + dc] = [dr.abs, dc.abs].max != 1 } }
      end
      (8..n - 9).each do |k|
        grid[6][k] = k.even?
        grid[k][6] = k.even?
      end
      grid[n - 8][8] = true # dark module

      level_bits = { L: 1, M: 0, Q: 3, H: 2 }.fetch(level)
      format = format_bits || (bch((level_bits << 3) | mask, 5, 0x537, 15) ^ 0x5412)
      15.times do |i|
        dark = format[i] == 1
        grid[i < 6 ? i : (i < 8 ? i + 1 : n - 15 + i)][8] = dark
        grid[8][i < 8 ? n - 1 - i : (i == 8 ? 7 : 14 - i)] = dark
      end
      if version >= 7
        info = version_bits || bch(version, 6, 0x1F25, 18)
        18.times do |i|
          dark = info[i] == 1
          grid[i / 3][n - 11 + i % 3] = dark
          grid[n - 11 + i % 3][i / 3] = dark
        end
      end

      all = codewords(data, version, level)
      corrupt&.call(all)
      bits = all.flat_map { |cw| 7.downto(0).map { |b| cw[b] } }
      index = 0
      upward = true
      col = n - 1
      while col.positive?
        col -= 1 if col == 6
        rows = upward ? (n - 1).downto(0) : 0.upto(n - 1)
        rows.each do |row|
          [col, col - 1].each do |c|
            next unless grid[row][c].nil?

            bit = index < bits.size ? bits[index] : 0
            index += 1
            grid[row][c] = (bit == 1) ^ masked?(mask, row, c)
          end
        end
        upward = !upward
        col -= 2
      end
      QrReader::BitMatrix.from_rows(grid)
    end

    # Bit stream (BitWriter) -> padded data -> symbol.
    def build_stream(writer, version:, level:, mask: 0, **options)
      capacity = QrReader::SymbolVersion[version].data_codewords(level)
      build(writer.to_data(capacity), version: version, level: level, mask: mask, **options)
    end
  end

  # Flips +count+ distinct random modules among +candidates+ (indices into
  # the module String).
  def flip_modules(matrix, candidates, count, rng)
    out = matrix.dup
    candidates.sample(count, random: rng).each { |i| out.bits.setbyte(i, out.bits.getbyte(i) ^ 1) }
    out
  end
end
