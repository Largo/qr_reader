# frozen_string_literal: true

module QrReader
  # Image file decoders. Each one turns encoded bytes into an 8-bit luminance
  # QrReader::Image: colour is converted with Image.luma and alpha is composited
  # over white, exactly like Image.from_pixels, so every format agrees.
  #
  #   QrReader::Formats.decode(File.binread("code.png"))   # => #<QrReader::Image 290x290>
  #   QrReader::Formats.format_of(bytes)                    # => :png
  #   QrReader::Formats.dimensions(bytes)                   # => [290, 290]
  #
  # Unknown data raises ImageError; formats that are recognised but not
  # supported (WebP, HEIC, AVIF, JPEG XL, ...) raise UnsupportedImageError.
  module Formats
    # Largest image, in pixels, that the decoders will allocate. Larger
    # (or maliciously declared) sizes raise UnsupportedImageError.
    MAX_PIXELS = 1 << 27

    GIF_MAGIC = /\AGIF8[79]a/n
    PNM_MAGIC = /\AP[1-7][\s#]/n
    TIFF_MAGIC = ["II*\0", "MM\0*", "II+\0", "MM\0+"].map(&:b).freeze
    WHITESPACE = " \t\n\v\f\r"
    ALL_BYTES = (0..255).to_a.freeze
    WHITE = "\xFF".b

    # Recognised formats that Formats.decode does not read: [pattern, name,
    # module that reads them (nil if none)].
    UNSUPPORTED = [
      [/\ARIFF....WEBP/mn, "WebP"],
      [/\A....ftyp(?:avif|avis)/mn, "AVIF"],
      [/\A....ftyp(?:heic|heix|hevc|hevx|heim|heis|mif1|msf1)/mn, "HEIC/HEIF"],
      [/\A(?:\xFF\x0A|\0\0\0\x0CJXL \r\n\x87\n)/n, "JPEG XL"],
      [/\A(?:\0\0\0\x0CjP  \r\n\x87\n|\xFF\x4F\xFF\x51)/n, "JPEG 2000"],
      [/\AP[Ff][\s#]/n, "PFM (floating point PNM)"],
      [/\A8BPS/n, "Photoshop PSD"],
      [/\A\s*<(?:\?xml|svg|!DOCTYPE svg)/n, "SVG"]
    ].freeze
    private_constant :GIF_MAGIC, :PNM_MAGIC, :TIFF_MAGIC, :WHITESPACE, :ALL_BYTES, :WHITE, :UNSUPPORTED

    class << self
      # Decodes an encoded image (format sniffed from its magic bytes) into a
      # luminance Image. +scale+ (1, 2, 4 or 8) is honoured by JPEG only.
      def decode(bytes, scale: 1)
        bytes = Support.binary(bytes)
        case format_of(bytes)
        when :png then PNG.decode(bytes)
        when :jpeg then JPEG.decode(bytes, scale: scale)
        when :gif then GIF.decode(bytes)
        when :bmp then BMP.decode(bytes)
        when :pnm then PNM.decode(bytes)
        when :tiff then TIFF.decode(bytes)
        when :pdf then first_pdf_image(bytes)
        else raise unrecognized(bytes)
        end
      end

      # :png, :jpeg, :gif, :bmp, :pnm, :tiff, :pdf, or nil when the magic
      # bytes are not those of a supported format. TIFF and PDF are
      # multi-page: Formats.decode returns their first page or image.
      def format_of(bytes)
        return nil unless bytes.is_a?(String) && bytes.bytesize >= 2

        head = bytes.byteslice(0, 32).b
        b0 = head.getbyte(0)
        if b0 == 0x89 then :png if head.start_with?(PNG::SIGNATURE)
        elsif b0 == 0xFF then :jpeg if head.getbyte(1) == 0xD8 && head.getbyte(2) == 0xFF
        elsif b0 == 0x47 then :gif if GIF_MAGIC.match?(head)
        elsif b0 == 0x42 then :bmp if BMP.bmp?(head)
        elsif b0 == 0x50 then :pnm if PNM_MAGIC.match?(head)
        elsif b0 == 0x49 || b0 == 0x4D then :tiff if TIFF_MAGIC.include?(head.byteslice(0, 4))
        elsif b0 == 0x25 then :pdf if head.start_with?("%PDF-")
        end
      end

      # [width, height] of an encoded image, read from its header only (the
      # same size Formats.decode would produce at scale 1).
      def dimensions(bytes)
        bytes = Support.binary(bytes)
        case format_of(bytes)
        when :png then PNG.dimensions(bytes)
        when :jpeg then JPEG.dimensions(bytes)
        when :gif then GIF.dimensions(bytes)
        when :bmp then BMP.dimensions(bytes)
        when :pnm then PNM.dimensions(bytes)
        when :tiff then TIFF.dimensions(bytes)
        when :pdf then first_pdf_image(bytes).then { |image| [image.width, image.height] }
        else raise unrecognized(bytes)
        end
      end

      private

      def first_pdf_image(bytes)
        PDF.each_image(bytes) { |image, _info| return image }
        raise UnsupportedImageError, "PDF contains no decodable raster image"
      end

      def unrecognized(bytes)
        head = bytes.byteslice(0, 64)
        UNSUPPORTED.each do |pattern, name, container|
          next unless pattern.match?(head)

          where = " here (QrReader.read and QrReader::Formats::#{container} read them)" if container
          return UnsupportedImageError.new(
            "#{name} images are not supported#{where}; convert to PNG, JPEG, GIF, BMP or PNM first, " \
            "e.g. `magick input output.png`"
          )
        end
        return ImageError.new("empty image data") if bytes.empty?

        ImageError.new("unrecognised image format (magic bytes #{head.byteslice(0, 8).unpack1('H*')})")
      end
    end

    # Helpers shared by the decoders.
    module Support
      module_function

      # An empty binary String with room for +size+ bytes. Hot methods call
      # this instead of String.new(capacity:, encoding:) themselves: YJIT
      # side-exits on that keyword-argument call, and the caller's loop
      # would then run in the interpreter for the rest of the call.
      def buffer(size)
        String.new(capacity: size, encoding: Encoding::BINARY)
      end

      # +bytes+ as a binary String (decoders work on bytes, never characters).
      def binary(bytes)
        raise ImageError, "expected a String of encoded image data, got #{bytes.class}" unless bytes.is_a?(String)

        bytes.encoding == Encoding::BINARY ? bytes : bytes.b
      end

      # Validates declared image dimensions before anything is allocated.
      def check_dimensions(width, height, format)
        raise ImageError, "invalid #{format} dimensions #{width}x#{height}" unless width.positive? && height.positive?
        return if width * height <= MAX_PIXELS

        raise UnsupportedImageError, "#{format} image too large (#{width}x#{height}, limit #{MAX_PIXELS} pixels)"
      end

      # Composites luminance +v+ with alpha +a+ over white (Image.from_pixels).
      def over_white(v, a)
        a == 255 ? v : (v * a + 255 * (255 - a) + 127) / 255
      end

      # over_white for every alpha and luminance as a 64 KiB String indexed
      # by a << 8 | v: one getbyte instead of a division per pixel. Built on
      # first use (about 65k iterations), then shared.
      def over_white_table
        @over_white_table ||= begin
          table = "\0".b * 65_536
          a = 0
          while a < 256
            fill_over_white_row(table, a)
            a += 1
          end
          table.freeze
        end
      end

      def fill_over_white_row(table, a)
        base = a << 8
        rest = 255 * (255 - a) + 127
        v = 0
        while v < 256
          table.setbyte(base | v, (v * a + rest) / 255)
          v += 1
        end
      end

      # Translates every byte of +str+ in place: from_bytes[i] -> to_bytes[i].
      def translate!(str, from_bytes, to_bytes)
        str.tr!(Image::TR_ESCAPE.call(from_bytes), Image::TR_ESCAPE.call(to_bytes))
        str
      end

      # Luminance of 256 palette entries; +palette+ holds packed colour
      # triples (+order+ :rgb or :bgr, +entry_size+ bytes apart), +alpha+ is
      # an optional String of per-entry alpha. Missing entries are black.
      def palette_lumas(palette, entry_size: 3, order: :rgb, alpha: nil)
        count = [palette.bytesize / entry_size, 256].min
        ro, bo = order == :rgb ? [0, 2] : [2, 0]
        lumas = Array.new(256, 0)
        i = 0
        while i < count
          o = i * entry_size
          v = Image.luma(palette.getbyte(o + ro), palette.getbyte(o + 1), palette.getbyte(o + bo))
          a = alpha&.getbyte(i)
          lumas[i] = a ? over_white(v, a) : v
          i += 1
        end
        lumas
      end
    end
    private_constant :Support

    # Per-row pixel converters shared by the decoders: they read +n+ pixels
    # of +stride+ bytes starting at byte +off+ of +src+ and append one
    # luminance byte per pixel to +out+, with the arithmetic of
    # Image.from_pixels inlined. Channel offsets select the layout (BGR,
    # BGRX, or the high bytes of big-endian 16-bit samples). Decoders call
    # them once per row so that YJIT compiles them: it never compiles a
    # method that is entered only once, however long its loop runs.
    module Rows
      # Byte -> its four 2-bit samples as bytes 0..3.
      TWO_BIT = Array.new(256) { |b| [b >> 6, (b >> 4) & 3, (b >> 2) & 3, b & 3].pack("C4").freeze }.freeze

      module_function

      def rgb(src, off, n, out, ro = 0, go = 1, bo = 2, stride = 3)
        i = off
        stop = off + n * stride
        while i < stop
          out << ((306 * src.getbyte(i + ro) + 601 * src.getbyte(i + go) + 117 * src.getbyte(i + bo) + 0x200) >> 10)
          i += stride
        end
        out
      end

      # Colour + alpha, composited over white through +table+
      # (Support.over_white_table).
      def rgba(src, off, n, out, table, ro = 0, go = 1, bo = 2, ao = 3, stride = 4)
        i = off
        stop = off + n * stride
        while i < stop
          v = (306 * src.getbyte(i + ro) + 601 * src.getbyte(i + go) + 117 * src.getbyte(i + bo) + 0x200) >> 10
          out << table.getbyte((src.getbyte(i + ao) << 8) | v)
          i += stride
        end
        out
      end

      # Gray + alpha, composited over white through +table+.
      def gray_alpha(src, off, n, out, table, ao = 1, stride = 2)
        i = off
        stop = off + n * stride
        while i < stop
          out << table.getbyte((src.getbyte(i + ao) << 8) | src.getbyte(i))
          i += stride
        end
        out
      end

      # The high byte of +n+ big-endian 16-bit samples. (A plain loop: it
      # beats unpack("v*").pack("C*") by 6x with YJIT and 1.3x without.)
      def high_bytes(src, off, n, out)
        i = off
        stop = off + 2 * n
        while i < stop
          out << src.getbyte(i)
          i += 2
        end
        out
      end

      # 2-bit samples (MSB first) -> one byte 0..3 per pixel.
      def unpack2(src, off, n, out)
        full = n >> 2
        i = off
        stop = off + full
        while i < stop
          out << TWO_BIT[src.getbyte(i)]
          i += 1
        end
        rest = n & 3
        out << TWO_BIT[src.getbyte(stop)].byteslice(0, rest) if rest.positive?
        out
      end
    end
    private_constant :Rows
  end
end

require_relative "formats/png"
require_relative "formats/gif"
require_relative "formats/bmp"
require_relative "formats/pnm"
require_relative "formats/jpeg"
