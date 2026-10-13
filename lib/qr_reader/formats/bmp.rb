# frozen_string_literal: true

module QrReader
  module Formats
    # Windows/OS2 bitmap decoder: 1/2/4/8 bpp palette images, 16/24/32 bpp
    # (BI_RGB, BI_BITFIELDS and BI_ALPHABITFIELDS, alpha masks included),
    # RLE8 and RLE4, bottom-up and top-down rows, OS/2 core headers and
    # BITMAPINFOHEADER through V5.
    #
    # Like browsers, the fourth byte of 32 bpp BI_RGB pixels is used as alpha,
    # but an alpha channel that leaves the whole image transparent is ignored
    # (many writers leave it zero). Pixels skipped by RLE deltas are
    # transparent, i.e. white. Mask fields narrower than 8 bits are widened
    # by bit replication (5 bits: v << 3 | v >> 2, like ImageMagick), wider
    # ones keep their top 8 bits.
    module BMP
      # DIB header sizes: OS/2 core (12), OS/2 2.x (16, 64), INFO (40), V2-V5.
      HEADER_SIZES = [12, 16, 40, 52, 56, 64, 108, 124].freeze

      BI_RGB = 0
      BI_RLE8 = 1
      BI_RLE4 = 2
      BI_BITFIELDS = 3
      BI_ALPHABITFIELDS = 6

      # Default channel masks for BI_RGB [red, green, blue, alpha].
      MASKS_555 = [0x7C00, 0x03E0, 0x001F, 0].freeze
      MASKS_8888 = [0xFF0000, 0xFF00, 0xFF, 0xFF000000].freeze

      HEX_DIGITS = "0123456789abcdef".bytes.freeze

      # RLE opcodes decoded per call of Decoder#rle_slice.
      RLE_SLICE = 256

      class << self
        # Plausibility check on the first bytes ("BM" + known DIB header size).
        def bmp?(head)
          head.bytesize >= 18 && head.start_with?("BM") && HEADER_SIZES.include?(head.unpack1("V", offset: 14))
        end

        def decode(bytes)
          Decoder.new(Support.binary(bytes)).decode
        end

        def dimensions(bytes)
          Decoder.new(Support.binary(bytes)).dimensions
        end
      end

      # Parses the headers on creation.
      class Decoder
        def initialize(bytes)
          raise ImageError, "not a BMP file" unless BMP.bmp?(bytes)

          @bytes = bytes
          header_size = bytes.unpack1("V", offset: 14)
          raise ImageError, "truncated BMP header" if bytes.bytesize < 14 + header_size

          read_header(header_size)
          Support.check_dimensions(@width, @height, "BMP")
          read_palette if @bpp <= 8
          @data_offset = @palette_end unless @data_offset.between?(@palette_end, bytes.bytesize - 1)
        end

        def dimensions
          [@width, @height]
        end

        def decode
          gray =
            case @compression
            when BI_RLE8, BI_RLE4 then decode_rle
            else decode_raw
            end
          Image.new(@width, @height, gray)
        end

        private

        def read_header(header_size)
          bytes = @bytes
          @data_offset = bytes.unpack1("V", offset: 10)
          @palette_entry = 4
          if header_size == 12 # OS/2 1.x BITMAPCOREHEADER: 16-bit sizes, RGB triples
            @width, @height, _planes, @bpp = bytes.unpack("vvvv", offset: 18)
            @compression = BI_RGB
            @palette_entry = 3
            colors = 0
          else
            @width, @height, _planes, @bpp = bytes.unpack("l<l<vv", offset: 18)
            @compression = header_size >= 20 ? bytes.unpack1("V", offset: 30) : BI_RGB
            colors = header_size >= 36 ? bytes.unpack1("V", offset: 46) : 0
          end
          @top_down = @height.negative?
          @height = -@height if @top_down
          @palette_start = 14 + header_size
          check_compression(header_size)
          read_masks(header_size)
          @palette_end = @palette_start
          @colors = colors
        end

        def check_compression(header_size)
          os2 = header_size == 16 || header_size == 64
          case @compression
          when BI_RGB then nil
          when BI_RLE8 then raise ImageError, "RLE8 BMP must have 8 bpp" unless @bpp == 8
          when BI_RLE4 then raise ImageError, "RLE4 BMP must have 4 bpp" unless @bpp == 4
          when BI_BITFIELDS, BI_ALPHABITFIELDS
            raise UnsupportedImageError, "OS/2 Huffman-compressed BMPs are not supported" if os2

            raise ImageError, "BI_BITFIELDS BMP must have 16 or 32 bpp" unless @bpp == 16 || @bpp == 32
          when 4, 5
            kind = os2 ? "RLE24" : (@compression == 4 ? "JPEG" : "PNG")
            raise UnsupportedImageError, "#{kind}-compressed BMPs are not supported"
          else
            raise UnsupportedImageError, "BMP compression type #{@compression} is not supported"
          end
          return if [1, 2, 4, 8, 16, 24, 32].include?(@bpp)

          raise UnsupportedImageError, "BMPs with #{@bpp} bits per pixel are not supported"
        end

        # Channel masks for 16 and 32 bpp; they follow a 40-byte header
        # when BI_(ALPHA)BITFIELDS is used and are part of V2+ headers.
        def read_masks(header_size)
          return unless @bpp == 16 || @bpp == 32

          bytes = @bytes
          @masks = @bpp == 16 ? MASKS_555 : MASKS_8888
          return if @compression == BI_RGB

          count = @compression == BI_ALPHABITFIELDS ? 4 : 3
          if header_size >= 52
            count = 4 if header_size >= 56
            pos = 54
          else
            # Some writers set BI_BITFIELDS but omit the masks (pixel data
            # starts right after the header); assume the defaults then.
            return if @data_offset == @palette_start

            pos = @palette_start
            @palette_start += count * 4
          end
          raise ImageError, "truncated BMP colour masks" if pos + count * 4 > bytes.bytesize

          @masks = bytes.unpack("V#{count}", offset: pos)
          @masks << 0 if count == 3
        end

        def read_palette
          entry = @palette_entry
          count = @colors.positive? ? [@colors, 256].min : 1 << @bpp
          if @data_offset.between?(@palette_start, @bytes.bytesize)
            count = [count, (@data_offset - @palette_start) / entry].min
          end
          palette = @bytes.byteslice(@palette_start, count * entry) || "".b
          @palette_end = @palette_start + palette.bytesize
          @lumas = Support.palette_lumas(palette, entry_size: entry, order: :bgr)
        end

        # Uncompressed pixel rows (stride padded to 4 bytes).
        def decode_raw
          w = @width
          h = @height
          bpp = @bpp
          stride = ((w * bpp + 31) >> 5) << 2
          row_bytes = (w * bpp + 7) >> 3
          # The padding of the last row is often missing; tolerate that.
          if @data_offset + stride * (h - 1) + row_bytes > @bytes.bytesize
            raise ImageError, "truncated BMP pixel data"
          end

          out = convert_rows(row_converter(alpha: true), stride)
          # An alpha channel that hides everything is an unset field (most
          # often all zero): decode the pixels as opaque instead.
          if @masks && @masks[3].positive? && out.count(WHITE) == out.bytesize
            out = convert_rows(row_converter(alpha: false), stride)
          end
          finish_palette(out)
        end

        def convert_rows(converter, stride)
          h = @height
          out = Support.buffer(@width * h)
          y = 0
          while y < h
            converter.call(@data_offset + (@top_down ? y : h - 1 - y) * stride, out)
            y += 1
          end
          out
        end

        # A lambda converting one row at a byte offset, appending luminance
        # (or palette indices, mapped later by finish_palette).
        def row_converter(alpha:)
          bytes = @bytes
          w = @width
          case @bpp
          when 1
            bits = "B#{w}"
            ->(off, out) { out << bytes.unpack1(bits, offset: off) }
          when 2 then ->(off, out) { Rows.unpack2(bytes, off, w, out) }
          when 4
            nibbles = "H#{w}"
            ->(off, out) { out << bytes.unpack1(nibbles, offset: off) }
          when 8 then ->(off, out) { out << bytes.byteslice(off, w) }
          when 24 then ->(off, out) { Rows.rgb(bytes, off, w, out, 2, 1, 0) }
          else masked_converter(alpha)
          end
        end

        def masked_converter(alpha)
          bytes = @bytes
          w = @width
          rm, gm, bm, am = @masks
          am = 0 unless alpha
          if @bpp == 32 && rm == 0xFF0000 && gm == 0xFF00 && bm == 0xFF
            return ->(off, out) { Rows.rgb(bytes, off, w, out, 2, 1, 0, 4) } if am.zero?
            if am == 0xFF000000
              table = Support.over_white_table
              return ->(off, out) { Rows.rgba(bytes, off, w, out, table, 2, 1, 0, 3) }
            end
          end

          fields = [rm, gm, bm, am].map { |mask| Field.new(mask) }
          wide = @bpp == 32
          table = Support.over_white_table unless am.zero?
          ->(off, out) { masked_row(bytes, off, w, wide, fields, table, out) }
        end

        # Converts a row of +n+ little-endian 16-bit (or, if +wide+, 32-bit)
        # pixels at +off+ with arbitrary channel masks; an alpha field
        # (non-zero mask) is composited over white through +table+.
        def masked_row(bytes, off, n, wide, fields, table, out)
          r, g, b, a = fields
          rm = r.mask
          rs = r.shift
          rt = r.table
          gm = g.mask
          gs = g.shift
          gt = g.table
          bm = b.mask
          bs = b.shift
          bt = b.table
          am = a.mask
          as = a.shift
          at = a.table
          i = off
          stop = off + n * (wide ? 4 : 2)
          while i < stop
            v = bytes.getbyte(i) | (bytes.getbyte(i + 1) << 8)
            if wide
              v |= (bytes.getbyte(i + 2) << 16) | (bytes.getbyte(i + 3) << 24)
              i += 4
            else
              i += 2
            end
            l = (306 * rt[(v & rm) >> rs] + 601 * gt[(v & gm) >> gs] + 117 * bt[(v & bm) >> bs] + 0x200) >> 10
            l = table.getbyte((at[(v & am) >> as] << 8) | l) if am != 0
            out << l
          end
          out
        end

        def finish_palette(out)
          from =
            case @bpp
            when 1 then [48, 49] # "0", "1"
            when 2 then [0, 1, 2, 3]
            when 4 then HEX_DIGITS
            when 8 then ALL_BYTES
            end
          from ? Support.translate!(out, from, @lumas.first(from.size)) : out
        end

        # RLE8/RLE4: runs and absolute groups of palette indices; deltas and
        # early line/bitmap ends leave pixels transparent (white). The
        # opcodes are read in slices (rle_slice) so that YJIT compiles the
        # loop; absolute groups are mapped pixel by pixel (rle_absolute).
        def decode_rle
          raise ImageError, "truncated BMP RLE data" if @data_offset + 2 > @bytes.bytesize

          @rle4 = @compression == BI_RLE4
          lum = @lumas.map { |v| v.chr.b }
          # RLE4 runs alternate the two nibbles of their byte.
          @runs = @rle4 ? Array.new(256) { |b| lum[b >> 4] + lum[b & 15] } : lum
          @out = WHITE * (@width * @height)
          @pos = @data_offset
          @x = @y = 0
          rle_slice while @y < @height
          @out
        end

        # Decodes up to RLE_SLICE opcodes from @pos; the position (@pos, @x,
        # @y) carries over to the next call. @y reaches the height at the end.
        def rle_slice
          bytes = @bytes
          size = bytes.bytesize
          w = @width
          h = @height
          pos = @pos
          x = @x
          y = @y
          ops = 0
          while y < h && ops < RLE_SLICE
            raise ImageError, "truncated BMP RLE data" if pos + 2 > size

            count = bytes.getbyte(pos)
            value = bytes.getbyte(pos + 1)
            pos += 2
            ops += 1
            if count.positive?
              rle_run(x, y, count, value) if x < w
              x += count
            elsif value.zero? # end of line
              x = 0
              y += 1
            elsif value == 1 # end of bitmap
              y = h
            elsif value == 2 # delta
              raise ImageError, "truncated BMP RLE data" if pos + 2 > size

              x += bytes.getbyte(pos)
              y += bytes.getbyte(pos + 1)
              pos += 2
            else # absolute mode: +value+ indices, padded to 16 bits
              nbytes = @rle4 ? (value + 1) >> 1 : value
              raise ImageError, "truncated BMP RLE data" if pos + nbytes > size

              rle_absolute(pos, x, y, value) if x < w
              x += value
              pos += nbytes + (nbytes & 1)
            end
          end
          @pos = pos
          @x = x
          @y = y
        end

        # A run of +count+ pixels at (x, y) in file row order, clipped
        # (x is inside the image). Short runs, the most common ones, are
        # written byte by byte rather than built as Strings.
        def rle_run(x, y, count, value)
          w = @width
          n = count < w - x ? count : w - x
          dst = row_offset(y) + x
          out = @out
          if n > 8
            run = @rle4 ? @runs[value] * ((n + 1) >> 1) : @runs[value] * n
            out.bytesplice(dst, n, run.bytesize > n ? run.byteslice(0, n) : run)
          elsif @rle4
            even = @lumas[value >> 4]
            odd = @lumas[value & 15]
            k = 0
            while k < n
              out.setbyte(dst + k, (k & 1).zero? ? even : odd)
              k += 1
            end
          else
            v = @lumas[value]
            stop = dst + n
            while dst < stop
              out.setbyte(dst, v)
              dst += 1
            end
          end
        end

        # An absolute group of +count+ indices at +pos+, drawn at (x, y),
        # clipped (x is inside the image).
        def rle_absolute(pos, x, y, count)
          w = @width
          n = count < w - x ? count : w - x
          bytes = @bytes
          lumas = @lumas
          out = @out
          dst = row_offset(y) + x
          stop = dst + n
          if @rle4
            k = 0
            while dst < stop
              b = bytes.getbyte(pos + (k >> 1))
              out.setbyte(dst, lumas[(k & 1).zero? ? b >> 4 : b & 15])
              dst += 1
              k += 1
            end
          else
            while dst < stop
              out.setbyte(dst, lumas[bytes.getbyte(pos)])
              dst += 1
              pos += 1
            end
          end
        end

        # Offset of file row +y+ in the top-down output.
        def row_offset(y)
          (@top_down ? y : @height - 1 - y) * @width
        end
      end
      private_constant :Decoder

      # A colour channel described by a bit mask, with a table from field
      # value to 8 bits: narrower fields are widened by bit replication,
      # wider ones keep their top 8 bits.
      class Field
        attr_reader :mask, :shift, :table

        def initialize(mask)
          @mask = mask
          @shift = mask.zero? ? 0 : (mask & -mask).bit_length - 1
          bits = (mask >> @shift).bit_length
          if bits > 8
            @shift += bits - 8
            bits = 8
          end
          @table = bits.zero? ? [0].freeze : Array.new(1 << bits) { |v| Field.widen(v, bits) }.freeze
        end

        def self.widen(value, bits)
          wide = 0
          filled = 0
          while filled < 8
            wide = (wide << bits) | value
            filled += bits
          end
          wide >> (filled - 8)
        end
      end
      private_constant :Field
    end
  end
end
