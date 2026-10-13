# frozen_string_literal: true

require "zlib"

module QrReader
  module Formats
    # PNG decoder: every colour type and bit depth (1/2/4/8/16), PLTE + tRNS,
    # alpha composited over white, Adam7 interlacing, any number of IDAT chunks.
    # Ancillary chunks (gamma, colour profiles, text, APNG frames, ...) are
    # ignored, and chunk CRCs are not verified (like most lenient decoders).
    #
    # Rows are unfiltered into a fresh String per row (appending with
    # String#<< is much cheaper than setbyte) and converted to luminance right
    # away; palette, low bit depth and grayscale images are mapped to luma
    # with a single String#tr at the end. 16-bit samples keep their high byte.
    module PNG
      SIGNATURE = "\x89PNG\r\n\x1A\n".b

      # colour type => [channels, allowed bit depths]
      COLOR_TYPES = {
        0 => [1, [1, 2, 4, 8, 16]], # grayscale
        2 => [3, [8, 16]],          # RGB
        3 => [1, [1, 2, 4, 8]],     # palette
        4 => [2, [8, 16]],          # grayscale + alpha
        6 => [4, [8, 16]]           # RGBA
      }.freeze

      # Adam7 passes: [x0, y0, dx, dy].
      ADAM7 = [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]].freeze

      # Bytes of sample values produced when unpacking 1, 2 and 4-bit rows
      # (unpack "B" / two-bit table / unpack "H"), i.e. the String#tr sources.
      SAMPLE_CODES = {
        1 => "01".bytes.freeze,
        2 => [0, 1, 2, 3].freeze,
        4 => "0123456789abcdef".bytes.freeze,
        8 => ALL_BYTES
      }.freeze

      # Compressed bytes fed to zlib at a time (bounds memory for zip bombs).
      INFLATE_SLICE = 1 << 16

      class << self
        def decode(bytes)
          Decoder.new(Support.binary(bytes)).decode
        end

        def dimensions(bytes)
          Decoder.new(Support.binary(bytes), header_only: true).dimensions
        end
      end

      # Parses the chunk structure and produces the luminance image.
      class Decoder
        def initialize(bytes, header_only: false)
          @bytes = bytes
          raise ImageError, "not a PNG file" unless bytes.start_with?(SIGNATURE)

          read_chunks(header_only)
        end

        def dimensions
          [@width, @height]
        end

        def decode
          raise ImageError, "PNG has no image data (IDAT)" if @idat.empty?
          raise ImageError, "palette PNG without PLTE chunk" if @color_type == 3 && @palette.nil?

          setup_conversion
          w = @width
          h = @height
          if @interlaced
            out = deinterlace(inflate(ADAM7.sum { |pass| pass_size(pass)[2] }))
          else
            raw = inflate(h * (1 + row_bytes(w))) # before allocating: it may be truncated
            out = Support.buffer(w * h)
            decode_rows(raw, 0, w, h, out)
          end
          Support.translate!(out, @tr_from, @tr_to) if @tr_from
          Image.new(w, h, out)
        end

        private

        def read_chunks(header_only)
          bytes = @bytes
          size = bytes.bytesize
          pos = 8
          @idat = []
          while pos + 8 <= size
            length, type = bytes.unpack("Na4", offset: pos)
            body_pos = pos + 8
            if body_pos + length > size
              # Once image data has started, keep what is there: the pixel
              # data may be complete (decode raises if it is not).
              raise ImageError, "truncated PNG chunk #{type.inspect}" if @idat.empty? && type != "IDAT"

              @idat << [body_pos, size - body_pos] if type == "IDAT"
              break
            end

            if pos == 8
              raise UnsupportedImageError, "Apple-optimised (CgBI) PNGs are not supported" if type == "CgBI"
              raise ImageError, "PNG does not start with IHDR" unless type == "IHDR"

              read_header(bytes.byteslice(body_pos, length))
              return if header_only
            else
              case type
              when "IDAT" then @idat << [body_pos, length]
              when "PLTE" then @palette ||= bytes.byteslice(body_pos, length - length % 3)
              when "tRNS" then @trns ||= bytes.byteslice(body_pos, length)
              when "IEND" then break
              end
            end
            pos = body_pos + length + 4 # skip CRC
          end
          raise ImageError, "truncated PNG (no IHDR)" unless @width
        end

        def read_header(ihdr)
          raise ImageError, "invalid PNG IHDR chunk" if ihdr.bytesize < 13

          @width, @height, @depth, @color_type, compression, filter, interlace = ihdr.unpack("NNCCCCC")
          channels, depths = COLOR_TYPES[@color_type]
          raise ImageError, "invalid PNG colour type #{@color_type}" unless channels
          unless depths.include?(@depth)
            raise ImageError, "invalid PNG bit depth #{@depth} for colour type #{@color_type}"
          end
          raise ImageError, "unknown PNG compression/filter method" unless compression.zero? && filter.zero?
          raise ImageError, "unknown PNG interlace method #{interlace}" if interlace > 1
          raise ImageError, "PNG dimensions exceed 2^31 - 1" if @width > 0x7FFFFFFF || @height > 0x7FFFFFFF

          Support.check_dimensions(@width, @height, "PNG")
          @interlaced = interlace == 1
          @bits_per_pixel = channels * @depth
          @filter_bpp = (@bits_per_pixel + 7) >> 3 # filter distance in bytes
        end

        def row_bytes(width)
          (width * @bits_per_pixel + 7) >> 3
        end

        # [width, height, raw byte count] of an Adam7 pass.
        def pass_size((x0, y0, dx, dy))
          pw = (@width - x0 + dx - 1) / dx
          ph = (@height - y0 + dy - 1) / dy
          pw = ph = 0 if pw <= 0 || ph <= 0
          [pw, ph, pw.zero? ? 0 : ph * (1 + row_bytes(pw))]
        end

        # Inflates the concatenated IDAT payload; returns at least +expected+ bytes.
        def inflate(expected)
          zstream = Zlib::Inflate.new
          # Deflate expands at most 1032:1, so a few bytes of data that
          # claim a huge image never reserve (and touch) the claimed size.
          compressed = @idat.sum { |_, length| length }
          out = Support.buffer([expected, compressed * 1032 + 1024].min)
          @idat.each do |pos, length|
            stop = pos + length
            while pos < stop && out.bytesize < expected
              n = [stop - pos, INFLATE_SLICE].min
              out << zstream.inflate(@bytes.byteslice(pos, n))
              pos += n
            end
            break if out.bytesize >= expected
          end
          raise ImageError, "truncated PNG image data (#{out.bytesize} of #{expected} bytes)" if out.bytesize < expected

          out
        rescue Zlib::Error => e
          raise ImageError, "corrupt PNG image data (zlib: #{e.message})"
        ensure
          if zstream
            zstream.reset # an unfinished stream would warn on close
            zstream.close
          end
        end

        # Chooses the per-row conversion and the final String#tr mapping.
        def setup_conversion
          depth = @depth
          trns = @trns
          @row_kind = depth < 8 ? :"unpack#{depth}" : :copy
          case @color_type
          when 0
            key = trns.unpack1("n") if trns && trns.bytesize >= 2
            if depth == 16
              @row_kind = :gray16
              @trns_key = trns.byteslice(0, 2) if key
            elsif depth == 8
              @tr_from, @tr_to = [key], [255] if key && key <= 255
            else
              max = (1 << depth) - 1
              @tr_from = SAMPLE_CODES[depth]
              @tr_to = Array.new(max + 1) { |v| v * 255 / max }
              @tr_to[key] = 255 if key && key <= max
            end
          when 2
            @row_kind = depth == 8 ? :rgb8 : :rgb16
            if trns && trns.bytesize >= 6
              rgb = trns.unpack("nnn")
              @trns_key = depth == 16 ? trns.byteslice(0, 6) : (rgb.pack("C3") if rgb.max <= 255)
            end
          when 3
            @tr_from = SAMPLE_CODES[depth]
            @tr_to = Support.palette_lumas(@palette, alpha: trns).first(1 << depth)
          when 4 then @row_kind = depth == 8 ? :gray_alpha8 : :gray_alpha16
          when 6 then @row_kind = depth == 8 ? :rgba8 : :rgba16
          end
          @alpha_table = Support.over_white_table if @color_type >= 4
        end

        # Adam7: decodes each pass into its own buffer and scatters the pixels.
        def deinterlace(raw)
          w = @width
          out = "\0".b * (w * @height)
          pos = 0
          ADAM7.each do |pass|
            pw, ph, size = pass_size(pass)
            next if size.zero?

            x0, y0, dx, dy = pass
            sub = Support.buffer(pw * ph)
            decode_rows(raw, pos, pw, ph, sub)
            pos += size
            r = 0
            while r < ph
              dst = (y0 + r * dy) * w + x0
              if dx == 1
                out.bytesplice(dst, pw, sub.byteslice(r * pw, pw))
              else
                scatter(sub, r * pw, pw, out, dst, dx)
              end
              r += 1
            end
          end
          out
        end

        # Copies +n+ bytes from +src+ to every +step+-th byte of +out+.
        def scatter(src, from, n, out, dst, step)
          stop = from + n
          while from < stop
            out.setbyte(dst, src.getbyte(from))
            dst += step
            from += 1
          end
        end

        # Unfilters +rows+ rows of +width+ pixels starting at +pos+ in +raw+
        # and appends their luminance (or sample codes) to +out+.
        def decode_rows(raw, pos, width, rows, out)
          len = row_bytes(width)
          bpp = @filter_bpp
          kind = @row_kind
          prev = "\0".b * len
          y = 0
          while y < rows
            ri = pos + 1
            cur =
              case raw.getbyte(pos)
              when 0 then raw.byteslice(ri, len)
              when 1 then Filters.sub(raw, ri, len, bpp)
              when 2 then Filters.up(raw, ri, prev, len)
              when 3 then Filters.average(raw, ri, prev, len, bpp)
              when 4 then Filters.paeth(raw, ri, prev, len, bpp)
              else raise ImageError, "invalid PNG filter type #{raw.getbyte(pos)}"
              end
            convert_row(kind, cur, width, out)
            prev = cur
            pos = ri + len
            y += 1
          end
        end

        def convert_row(kind, row, width, out)
          case kind
          when :copy then out << row
          when :unpack1 then out << row.unpack1("B#{width}")
          when :unpack4 then out << row.unpack1("H#{width}")
          when :unpack2 then Rows.unpack2(row, 0, width, out)
          when :rgb8
            start = out.bytesize
            Rows.rgb(row, 0, width, out)
            mark_transparent(row, 3, start, out) if @trns_key
          when :rgba8 then Rows.rgba(row, 0, width, out, @alpha_table)
          when :gray_alpha8 then Rows.gray_alpha(row, 0, width, out, @alpha_table)
          when :gray16
            start = out.bytesize
            Rows.high_bytes(row, 0, width, out)
            mark_transparent(row, 2, start, out) if @trns_key
          when :rgb16 # 16-bit samples: read their high bytes in place
            start = out.bytesize
            Rows.rgb(row, 0, width, out, 0, 2, 4, 6)
            mark_transparent(row, 6, start, out) if @trns_key
          when :rgba16 then Rows.rgba(row, 0, width, out, @alpha_table, 0, 2, 4, 6, 8)
          when :gray_alpha16 then Rows.gray_alpha(row, 0, width, out, @alpha_table, 2, 4)
          end
        end

        # Pixels equal to the tRNS colour key become white (transparent).
        def mark_transparent(row, pixel_bytes, start, out)
          key = @trns_key
          i = 0
          while (i = row.byteindex(key, i))
            if (i % pixel_bytes).zero?
              out.setbyte(start + i / pixel_bytes, 255)
              i += pixel_bytes
            else
              i += 1
            end
          end
        end
      end
      private_constant :Decoder

      # The five PNG filter types, reversed. Each takes the filtered row at
      # raw[ri, len] and the previous unfiltered row, returns the unfiltered
      # row. +bpp+ is the distance to the corresponding byte of the previous
      # pixel. The common pixel sizes get unrolled versions that keep the
      # left neighbours in local variables.
      #
      # Dispatch and loops live in separate methods on purpose: when YJIT
      # has compiled a dispatch for one pixel size, another size side-exits
      # to the interpreter, and a loop in the same method would then run
      # interpreted (5-7x slower) for the rest of the call.
      module Filters
        module_function

        def sub(raw, ri, len, bpp)
          bpp == 1 ? sub1(raw, ri, len) : sub_n(raw, ri, len, bpp)
        end

        def sub_n(raw, ri, len, bpp)
          cur = raw.byteslice(ri, bpp)
          k = bpp
          while k < len
            cur << ((raw.getbyte(ri + k) + cur.getbyte(k - bpp)) & 0xff)
            k += 1
          end
          cur
        end

        def sub1(raw, ri, len)
          cur = Support.buffer(len)
          a = 0
          stop = ri + len
          while ri < stop
            a = (raw.getbyte(ri) + a) & 0xff
            cur << a
            ri += 1
          end
          cur
        end

        def up(raw, ri, prev, len)
          cur = Support.buffer(len)
          k = 0
          while k < len
            cur << ((raw.getbyte(ri + k) + prev.getbyte(k)) & 0xff)
            k += 1
          end
          cur
        end

        def average(raw, ri, prev, len, bpp)
          case bpp
          when 1 then average1(raw, ri, prev, len)
          when 2 then average2(raw, ri, prev, len)
          when 3 then average3(raw, ri, prev, len)
          when 4 then average4(raw, ri, prev, len)
          else average_n(raw, ri, prev, len, bpp)
          end
        end

        def average_n(raw, ri, prev, len, bpp)
          cur = Support.buffer(len)
          k = 0
          while k < bpp && k < len
            cur << ((raw.getbyte(ri + k) + (prev.getbyte(k) >> 1)) & 0xff)
            k += 1
          end
          while k < len
            cur << ((raw.getbyte(ri + k) + ((cur.getbyte(k - bpp) + prev.getbyte(k)) >> 1)) & 0xff)
            k += 1
          end
          cur
        end

        def average1(raw, ri, prev, len)
          cur = Support.buffer(len)
          a = 0
          k = 0
          while k < len
            a = (raw.getbyte(ri + k) + ((a + prev.getbyte(k)) >> 1)) & 0xff
            cur << a
            k += 1
          end
          cur
        end

        def average2(raw, ri, prev, len)
          cur = Support.buffer(len)
          a0 = a1 = 0
          k = 0
          while k < len
            a0 = (raw.getbyte(ri + k) + ((a0 + prev.getbyte(k)) >> 1)) & 0xff
            a1 = (raw.getbyte(ri + k + 1) + ((a1 + prev.getbyte(k + 1)) >> 1)) & 0xff
            cur << a0 << a1
            k += 2
          end
          cur
        end

        def average3(raw, ri, prev, len)
          cur = Support.buffer(len)
          a0 = a1 = a2 = 0
          k = 0
          while k < len
            a0 = (raw.getbyte(ri + k) + ((a0 + prev.getbyte(k)) >> 1)) & 0xff
            a1 = (raw.getbyte(ri + k + 1) + ((a1 + prev.getbyte(k + 1)) >> 1)) & 0xff
            a2 = (raw.getbyte(ri + k + 2) + ((a2 + prev.getbyte(k + 2)) >> 1)) & 0xff
            cur << a0 << a1 << a2
            k += 3
          end
          cur
        end

        def average4(raw, ri, prev, len)
          cur = Support.buffer(len)
          a0 = a1 = a2 = a3 = 0
          k = 0
          while k < len
            a0 = (raw.getbyte(ri + k) + ((a0 + prev.getbyte(k)) >> 1)) & 0xff
            a1 = (raw.getbyte(ri + k + 1) + ((a1 + prev.getbyte(k + 1)) >> 1)) & 0xff
            a2 = (raw.getbyte(ri + k + 2) + ((a2 + prev.getbyte(k + 2)) >> 1)) & 0xff
            a3 = (raw.getbyte(ri + k + 3) + ((a3 + prev.getbyte(k + 3)) >> 1)) & 0xff
            cur << a0 << a1 << a2 << a3
            k += 4
          end
          cur
        end

        # Paeth prediction without branches: with da = b - c and db = a - c
        # (a = left, b = up, c = up-left) the predictor is c + PAETH[...],
        # where the table holds db (choose a), da (choose b) or 0 (choose c).
        def paeth(raw, ri, prev, len, bpp)
          case bpp
          when 1 then paeth1(raw, ri, prev, len, PAETH)
          when 2 then paeth2(raw, ri, prev, len, PAETH)
          when 3 then paeth3(raw, ri, prev, len, PAETH)
          when 4 then paeth4(raw, ri, prev, len, PAETH)
          else paeth_n(raw, ri, prev, len, bpp, PAETH)
          end
        end

        def paeth_n(raw, ri, prev, len, bpp, table)
          cur = Support.buffer(len)
          k = 0
          while k < bpp && k < len
            cur << ((raw.getbyte(ri + k) + prev.getbyte(k)) & 0xff)
            k += 1
          end
          while k < len
            c = prev.getbyte(k - bpp)
            delta = table[(prev.getbyte(k) - c) * 511 + cur.getbyte(k - bpp) - c + PAETH_CENTER]
            cur << ((raw.getbyte(ri + k) + c + delta) & 0xff)
            k += 1
          end
          cur
        end

        def paeth1(raw, ri, prev, len, table)
          cur = Support.buffer(len)
          a = c = 0
          k = 0
          while k < len
            b = prev.getbyte(k)
            a = (raw.getbyte(ri + k) + c + table[(b - c) * 511 + a - c + PAETH_CENTER]) & 0xff
            cur << a
            c = b
            k += 1
          end
          cur
        end

        def paeth2(raw, ri, prev, len, table)
          cur = Support.buffer(len)
          a0 = a1 = c0 = c1 = 0
          k = 0
          while k < len
            b = prev.getbyte(k)
            a0 = (raw.getbyte(ri + k) + c0 + table[(b - c0) * 511 + a0 - c0 + PAETH_CENTER]) & 0xff
            c0 = b
            b = prev.getbyte(k + 1)
            a1 = (raw.getbyte(ri + k + 1) + c1 + table[(b - c1) * 511 + a1 - c1 + PAETH_CENTER]) & 0xff
            c1 = b
            cur << a0 << a1
            k += 2
          end
          cur
        end

        def paeth3(raw, ri, prev, len, table)
          cur = Support.buffer(len)
          a0 = a1 = a2 = c0 = c1 = c2 = 0
          k = 0
          while k < len
            b = prev.getbyte(k)
            a0 = (raw.getbyte(ri + k) + c0 + table[(b - c0) * 511 + a0 - c0 + PAETH_CENTER]) & 0xff
            c0 = b
            b = prev.getbyte(k + 1)
            a1 = (raw.getbyte(ri + k + 1) + c1 + table[(b - c1) * 511 + a1 - c1 + PAETH_CENTER]) & 0xff
            c1 = b
            b = prev.getbyte(k + 2)
            a2 = (raw.getbyte(ri + k + 2) + c2 + table[(b - c2) * 511 + a2 - c2 + PAETH_CENTER]) & 0xff
            c2 = b
            cur << a0 << a1 << a2
            k += 3
          end
          cur
        end

        def paeth4(raw, ri, prev, len, table)
          cur = Support.buffer(len)
          a0 = a1 = a2 = a3 = c0 = c1 = c2 = c3 = 0
          k = 0
          while k < len
            b = prev.getbyte(k)
            a0 = (raw.getbyte(ri + k) + c0 + table[(b - c0) * 511 + a0 - c0 + PAETH_CENTER]) & 0xff
            c0 = b
            b = prev.getbyte(k + 1)
            a1 = (raw.getbyte(ri + k + 1) + c1 + table[(b - c1) * 511 + a1 - c1 + PAETH_CENTER]) & 0xff
            c1 = b
            b = prev.getbyte(k + 2)
            a2 = (raw.getbyte(ri + k + 2) + c2 + table[(b - c2) * 511 + a2 - c2 + PAETH_CENTER]) & 0xff
            c2 = b
            b = prev.getbyte(k + 3)
            a3 = (raw.getbyte(ri + k + 3) + c3 + table[(b - c3) * 511 + a3 - c3 + PAETH_CENTER]) & 0xff
            c3 = b
            cur << a0 << a1 << a2 << a3
            k += 4
          end
          cur
        end

        # Row-wise construction of the Paeth table, indexed by
        # (da + 255) * 511 + (db + 255). For fixed da the choice is a
        # function of db made of a few intervals (derived from
        # |da| <= |db|, |da| <= |da + db| and |db| <= |da + db|), so each row
        # is built from C-level fills instead of 261k Ruby iterations.
        def build_paeth_table
          base = (-255..255).to_a # choose a: predictor offset db
          table = []
          (-255..255).each do |da|
            row = base.dup
            d = da.abs
            if da.positive?
              # b for ceil(-d/2) <= db < d, c for -2d < db < ceil(-d/2)
              split = -(d / 2)
              fill(row, 0, -2 * d + 1, split - 1)
              fill(row, da, split, d - 1)
            elsif da.negative?
              # b for -d < db <= floor(d/2), c for floor(d/2) < db < 2d
              fill(row, da, -d + 1, d / 2)
              fill(row, 0, d / 2 + 1, 2 * d - 1)
            end
            table.concat(row)
          end
          table.freeze
        end

        def fill(row, value, from, to)
          from = [from, -255].max
          to = [to, 255].min
          row.fill(value, from + 255, to - from + 1) if to >= from
        end

        PAETH_CENTER = 255 * 511 + 255
        PAETH = build_paeth_table
      end
      private_constant :Filters
    end
  end
end
