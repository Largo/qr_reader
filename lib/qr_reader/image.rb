# frozen_string_literal: true

module QrReader
  # An 8-bit grayscale (luminance) image: one byte per pixel, row-major,
  # 0 = black, 255 = white. +data+ is a binary String of width * height bytes.
  #
  # This is the common currency of the library: every image format decoder
  # produces one and the detector consumes one.
  class Image
    attr_reader :width, :height, :data

    # Channel layouts accepted by Image.from_pixels.
    PIXEL_FORMATS = {
      gray: 1, gray_alpha: 2, rgb: 3, rgba: 4, bgr: 3, bgra: 4, argb: 4, abgr: 4
    }.freeze

    # String#tr tables mapping every byte v to 255 - v ('\\', '-' and '^' escaped).
    TR_ESCAPE = ->(bytes) { bytes.map { |b| c = b.chr.b; "\\-^".include?(c) ? "\\".b + c : c }.join.b.freeze }
    INVERT_FROM = TR_ESCAPE.call((0..255).to_a)
    INVERT_TO = TR_ESCAPE.call(255.downto(0).to_a)

    def initialize(width, height, data)
      unless width.is_a?(Integer) && height.is_a?(Integer) && width.positive? && height.positive?
        raise ArgumentError, "invalid image size #{width.inspect}x#{height.inspect}"
      end
      unless data.bytesize == width * height
        raise ArgumentError, "expected #{width * height} bytes of pixel data, got #{data.bytesize}"
      end

      @width = width
      @height = height
      @data = data.encoding == Encoding::BINARY ? data : data.b
    end

    class << self
      def from_gray(width, height, data)
        new(width, height, data)
      end

      # Builds an image from interleaved 8-bit samples. Alpha is composited
      # over a white background (transparent QR codes are usually dark modules
      # on a transparent background).
      def from_pixels(width, height, data, format = :rgba)
        channels = PIXEL_FORMATS.fetch(format) { raise ArgumentError, "unknown pixel format #{format.inspect}" }
        expected = width * height * channels
        raise ArgumentError, "expected #{expected} bytes of #{format} data, got #{data.bytesize}" if data.bytesize != expected
        return new(width, height, data) if format == :gray

        n = width * height
        out = "\0".b * n
        case format
        when :gray_alpha then convert_gray_alpha(data, out, n)
        when :rgb then convert_rgb(data, out, n, 0, 1, 2, 3)
        when :bgr then convert_rgb(data, out, n, 2, 1, 0, 3)
        when :rgba then convert_rgba(data, out, n, 0, 1, 2, 3)
        when :bgra then convert_rgba(data, out, n, 2, 1, 0, 3)
        when :argb then convert_rgba(data, out, n, 1, 2, 3, 0)
        when :abgr then convert_rgba(data, out, n, 3, 2, 1, 0)
        end
        new(width, height, out)
      end

      def from_rgb(width, height, data)
        from_pixels(width, height, data, :rgb)
      end

      def from_rgba(width, height, data)
        from_pixels(width, height, data, :rgba)
      end

      # Rec. 601 luma with 10-bit fixed point weights (same as zxing-cpp).
      def luma(r, g, b)
        (306 * r + 601 * g + 117 * b + 0x200) >> 10
      end

      private

      def convert_gray_alpha(src, out, n)
        i = 0
        while i < n
          v = src.getbyte(2 * i)
          a = src.getbyte(2 * i + 1)
          out.setbyte(i, a == 255 ? v : (v * a + 255 * (255 - a) + 127) / 255)
          i += 1
        end
      end

      def convert_rgb(src, out, n, ro, go, bo, stride)
        i = 0
        j = 0
        while i < n
          out.setbyte(i, (306 * src.getbyte(j + ro) + 601 * src.getbyte(j + go) + 117 * src.getbyte(j + bo) + 0x200) >> 10)
          i += 1
          j += stride
        end
      end

      def convert_rgba(src, out, n, ro, go, bo, ao)
        i = 0
        j = 0
        while i < n
          v = (306 * src.getbyte(j + ro) + 601 * src.getbyte(j + go) + 117 * src.getbyte(j + bo) + 0x200) >> 10
          a = src.getbyte(j + ao)
          out.setbyte(i, a == 255 ? v : (v * a + 255 * (255 - a) + 127) / 255)
          i += 1
          j += 4
        end
      end
    end

    # Luminance at (x, y).
    def [](x, y)
      @data.getbyte(y * @width + x)
    end

    def size
      @width * @height
    end

    # Bytes of row y as a binary String.
    def row(y)
      @data.byteslice(y * @width, @width)
    end

    # Photographic negative (for light-on-dark codes).
    def invert
      Image.new(@width, @height, @data.tr(INVERT_FROM, INVERT_TO))
    end

    def rotate180
      Image.new(@width, @height, @data.reverse)
    end

    # Rotates 90 degrees clockwise.
    def rotate90
      w = @width
      h = @height
      src = @data
      out = "\0".b * (w * h)
      y = 0
      while y < h
        x = 0
        dst = h - 1 - y
        off = y * w
        while x < w
          out.setbyte(dst, src.getbyte(off + x))
          dst += h
          x += 1
        end
        y += 1
      end
      Image.new(h, w, out)
    end

    # Rotates 90 degrees counter-clockwise.
    def rotate270
      rotate90.rotate180
    end

    # Rotates by a multiple of 90 degrees (clockwise).
    def rotate(degrees)
      case degrees % 360
      when 0 then self
      when 90 then rotate90
      when 180 then rotate180
      when 270 then rotate270
      else raise ArgumentError, "rotation must be a multiple of 90 degrees"
      end
    end

    # Horizontal mirror image.
    def mirror
      w = @width
      out = String.new(capacity: @data.bytesize, encoding: Encoding::BINARY)
      @height.times { |y| out << @data.byteslice(y * w, w).reverse }
      Image.new(w, @height, out)
    end

    def crop(x, y, w, h)
      raise ArgumentError, "crop rectangle outside image" if x.negative? || y.negative? || w < 1 || h < 1 || x + w > @width || y + h > @height

      out = String.new(capacity: w * h, encoding: Encoding::BINARY)
      h.times { |dy| out << @data.byteslice((y + dy) * @width + x, w) }
      Image.new(w, h, out)
    end

    # Box-filter downscale by an integer factor (partial edge blocks are dropped).
    def downscale(factor)
      return self if factor <= 1

      w = @width / factor
      h = @height / factor
      raise ArgumentError, "downscale factor too large" if w < 1 || h < 1

      src = @data
      sw = @width
      area = factor * factor
      half = area / 2
      out = "\0".b * (w * h)
      sums = Array.new(w, 0)
      y = 0
      while y < h
        sums.fill(0)
        sy = y * factor
        sy_end = sy + factor
        while sy < sy_end
          off = sy * sw
          x = 0
          sx = off
          while x < w
            s = 0
            e = sx + factor
            while sx < e
              s += src.getbyte(sx)
              sx += 1
            end
            sums[x] += s
            x += 1
          end
          sy += 1
        end
        base = y * w
        x = 0
        while x < w
          out.setbyte(base + x, (sums[x] + half) / area)
          x += 1
        end
        y += 1
      end
      Image.new(w, h, out)
    end

    def inspect
      "#<QrReader::Image #{@width}x#{@height}>"
    end
  end
end
