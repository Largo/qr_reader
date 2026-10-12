# frozen_string_literal: true

module QrReader
  # A 2D grid of dark/light cells. Used both for binarized images (one cell
  # per pixel) and for sampled QR symbols (one cell per module).
  #
  # Storage is a binary String with one byte per cell, row-major:
  # "\x01" = dark (black), "\x00" = light (white). The byte representation is
  # deliberate: String#getbyte/#setbyte are fast (and YJIT-inlined), and runs
  # can be found at C speed with String#index("\x01", pos) / ("\x00", pos).
  class BitMatrix
    DARK = "\x01".b.freeze
    LIGHT = "\x00".b.freeze

    attr_reader :width, :height, :bits

    def initialize(width, height = width, bits = nil)
      @width = width
      @height = height
      if bits
        raise ArgumentError, "expected #{width * height} cells, got #{bits.bytesize}" if bits.bytesize != width * height

        @bits = bits.encoding == Encoding::BINARY ? bits : bits.b
      else
        @bits = "\0".b * (width * height)
      end
    end

    # Builds a matrix from rows given as Arrays of booleans/integers or as
    # Strings where '#', 'X', '1' or 'x' mark dark cells.
    def self.from_rows(rows)
      h = rows.size
      w = rows.first.size
      m = new(w, h)
      rows.each_with_index do |row, y|
        cells = row.is_a?(String) ? row.chars.map { |c| "#X1x".include?(c) } : row
        cells.each_with_index { |v, x| m.set(x, y) if v && v != 0 }
      end
      m
    end

    # 1 if dark, 0 if light.
    def get(x, y)
      @bits.getbyte(y * @width + x)
    end

    def dark?(x, y)
      @bits.getbyte(y * @width + x) == 1
    end
    alias [] dark?

    def set(x, y, value = 1)
      @bits.setbyte(y * @width + x, value == true || value == 1 ? 1 : 0)
    end

    def unset(x, y)
      @bits.setbyte(y * @width + x, 0)
    end

    def flip(x, y)
      i = y * @width + x
      @bits.setbyte(i, @bits.getbyte(i) ^ 1)
    end

    # Cells of row y as a binary String of "\x00"/"\x01" bytes.
    def row(y)
      @bits.byteslice(y * @width, @width)
    end

    def dark_count
      @bits.count(DARK)
    end

    def dup
      BitMatrix.new(@width, @height, @bits.dup)
    end

    # Matrix with all cells inverted (dark <-> light).
    def invert
      BitMatrix.new(@width, @height, @bits.tr("\x00\x01", "\x01\x00"))
    end

    # Mirror along the main diagonal (x <-> y).
    def transpose
      w = @width
      h = @height
      src = @bits
      out = "\0".b * (w * h)
      y = 0
      while y < h
        x = 0
        off = y * w
        while x < w
          out.setbyte(x * h + y, src.getbyte(off + x))
          x += 1
        end
        y += 1
      end
      BitMatrix.new(h, w, out)
    end

    def ==(other)
      other.is_a?(BitMatrix) && other.width == @width && other.height == @height && other.bits == @bits
    end
    alias eql? ==

    def hash
      [@width, @height, @bits].hash
    end

    # ASCII rendering for debugging ("##" = dark, "  " = light).
    def to_s(dark: "##", light: "  ")
      (0...@height).map { |y| row(y).bytes.map { |b| b == 1 ? dark : light }.join }.join("\n")
    end

    def inspect
      "#<QrReader::BitMatrix #{@width}x#{@height}>"
    end
  end
end
