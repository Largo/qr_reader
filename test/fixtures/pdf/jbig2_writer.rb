# frozen_string_literal: true

# JBIG2 encoder for tests (ITU-T T.88): generic regions coded with the MQ
# arithmetic coder (Annex E encoder procedures), in PDF's embedded stream
# format. Written from the specification independently of the decoder in
# lib/qr_reader/formats/pdf.rb; Ghostscript (jbig2dec) renders its output
# identically to the source bitmaps.
module Jbig2Writer
  QE = [
    [0x5601, 1, 1, 1], [0x3401, 2, 6, 0], [0x1801, 3, 9, 0], [0x0AC1, 4, 12, 0],
    [0x0521, 5, 29, 0], [0x0221, 38, 33, 0], [0x5601, 7, 6, 1], [0x5401, 8, 14, 0],
    [0x4801, 9, 14, 0], [0x3801, 10, 14, 0], [0x3001, 11, 17, 0], [0x2401, 12, 18, 0],
    [0x1C01, 13, 20, 0], [0x1601, 29, 21, 0], [0x5601, 15, 14, 1], [0x5401, 16, 14, 0],
    [0x5101, 17, 15, 0], [0x4801, 18, 16, 0], [0x3801, 19, 17, 0], [0x3401, 20, 18, 0],
    [0x3001, 21, 19, 0], [0x2801, 22, 19, 0], [0x2401, 23, 20, 0], [0x2201, 24, 21, 0],
    [0x1C01, 25, 22, 0], [0x1801, 26, 23, 0], [0x1601, 27, 24, 0], [0x1401, 28, 25, 0],
    [0x1201, 29, 26, 0], [0x1101, 30, 27, 0], [0x0AC1, 31, 28, 0], [0x09C1, 32, 29, 0],
    [0x08A1, 33, 30, 0], [0x0521, 34, 31, 0], [0x0441, 35, 32, 0], [0x02A1, 36, 33, 0],
    [0x0221, 37, 34, 0], [0x0141, 38, 35, 0], [0x0111, 39, 36, 0], [0x0085, 40, 37, 0],
    [0x0049, 41, 38, 0], [0x0025, 42, 39, 0], [0x0015, 43, 40, 0], [0x0009, 44, 41, 0],
    [0x0005, 45, 42, 0], [0x0001, 45, 43, 0], [0x5601, 46, 46, 0]
  ].freeze

  # Context pixels of each template, least significant context bit first
  # (T.88 figures 3-6); :a1..:a4 are the adaptive pixels.
  TEMPLATES = [
    [[-1, 0], [-2, 0], [-3, 0], [-4, 0], :a1, [2, -1], [1, -1], [0, -1], [-1, -1], [-2, -1], :a2, :a3,
     [1, -2], [0, -2], [-1, -2], :a4],
    [[-1, 0], [-2, 0], [-3, 0], :a1, [2, -1], [1, -1], [0, -1], [-1, -1], [-2, -1], [2, -2], [1, -2],
     [0, -2], [-1, -2]],
    [[-1, 0], [-2, 0], :a1, [1, -1], [0, -1], [-1, -1], [-2, -1], [1, -2], [0, -2], [-1, -2]],
    [[-1, 0], [-2, 0], [-3, 0], [-4, 0], :a1, [1, -1], [0, -1], [-1, -1], [-2, -1], [-3, -1]]
  ].freeze
  NOMINAL_AT = [[[3, -1], [-3, -1], [2, -2], [-2, -2]], [[3, -1]], [[2, -1]], [[2, -1]]].freeze
  SLTP = [0x9B25, 0x0795, 0x00E5, 0x0195].freeze

  # MQ arithmetic encoder (T.88 E.2).
  class MQEncoder
    def initialize
      @a = 0x8000
      @c = 0
      @ct = 12
      @b = 0
      @started = false
      @out = []
      @states = Hash.new(0)
    end

    def encode(cx, bit)
      state = @states[cx]
      index = state >> 1
      mps = state & 1
      qe, nmps, nlps, switch = QE[index]
      @a -= qe
      if bit == mps
        if @a & 0x8000 == 0
          if @a < qe
            @a = qe
          else
            @c += qe
          end
          @states[cx] = (nmps << 1) | mps
          renormalize
        else
          @c += qe
        end
      else
        if @a < qe
          @c += qe
        else
          @a = qe
        end
        mps = 1 - mps if switch == 1
        @states[cx] = (nlps << 1) | mps
        renormalize
      end
    end

    # Terminates the code stream with the 0xFF 0xAC marker.
    def finish
      temp = @c + @a
      @c |= 0xFFFF
      @c -= 0x8000 if @c >= temp
      @c <<= @ct
      byte_out
      @c <<= @ct
      byte_out
      @out << @b
      @out << 0xFF unless @b == 0xFF
      @out << 0xAC
      @out.pack("C*")
    end

    private

    def renormalize
      loop do
        @a <<= 1
        @c <<= 1
        @ct -= 1
        byte_out if @ct.zero?
        break if @a & 0x8000 != 0
      end
    end

    # BP = BP + 1: the current byte is final.
    def advance(byte)
      @out << @b if @started
      @started = true
      @b = byte
    end

    def byte_out
      if @b == 0xFF
        advance(@c >> 20)
        @c &= 0xFFFFF
        @ct = 7
      elsif @c < 0x8000000
        advance(@c >> 19)
        @c &= 0x7FFFF
        @ct = 8
      else
        @b += 1
        if @b == 0xFF
          @c &= 0x7FFFFFF
          advance(@c >> 20)
          @c &= 0xFFFFF
          @ct = 7
        else
          advance(@c >> 19)
          @c &= 0x7FFFF
          @ct = 8
        end
      end
    end
  end

  module_function

  # Arithmetic-coded generic region data for +bits+ (Array of 0/1, 1 =
  # black, row-major).
  def generic_data(bits, width, height, template: 0, at: nil, typical: false)
    at ||= NOMINAL_AT[template]
    encoder = MQEncoder.new
    pixels = TEMPLATES[template].map { |p| p.is_a?(Symbol) ? at[p.to_s[1].to_i - 1] : p }
    pixel = ->(x, y) { x >= 0 && x < width && y >= 0 ? bits[y * width + x] : 0 }
    ltp = 0
    height.times do |y|
      row = bits[y * width, width]
      if typical
        above = y.zero? ? [0] * width : bits[(y - 1) * width, width]
        same = row == above ? 1 : 0
        encoder.encode(SLTP[template], same ^ ltp)
        ltp = same
        next if ltp == 1
      end
      width.times do |x|
        cx = 0
        pixels.each_with_index { |(dx, dy), i| cx |= pixel.call(x + dx, y + dy) << i }
        encoder.encode(cx, row[x])
      end
    end
    encoder.finish
  end

  def segment(number, type, data, page: 1)
    [number, type, 0, page, data.bytesize].pack("NCCCN") + data
  end

  def page_information(width, height, default_pixel: 0, operator: 0, override: false, stripe: 0)
    flags = (default_pixel << 2) | (operator << 3) | (override ? 0x40 : 0)
    [width, height, 0, 0, flags, stripe].pack("N4Cn")
  end

  # Region segment data of an arithmetic or MMR (+mmr_data+) generic region.
  def generic_region(width, height, x: 0, y: 0, operator: 0, template: 0, at: nil, typical: false,
                     data: nil, mmr_data: nil)
    head = [width, height, x, y, operator].pack("N4C")
    return head + [1].pack("C") + mmr_data if mmr_data

    at ||= NOMINAL_AT[template]
    head + [(template << 1) | (typical ? 8 : 0)].pack("C") + at.flatten.pack("c*") + data
  end

  # A complete embedded stream: page information and one generic region
  # covering the page.
  def stream(bits, width, height, **options)
    data = generic_data(bits, width, height, **options.slice(:template, :at, :typical))
    segment(0, 48, page_information(width, height)) +
      segment(1, 38, generic_region(width, height, data: data, **options.slice(:template, :at, :typical)))
  end
end
