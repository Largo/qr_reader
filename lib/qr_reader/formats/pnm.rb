# frozen_string_literal: true

module QrReader
  module Formats
    # Netpbm decoder: PBM/PGM/PPM in plain (P1-P3) and raw (P4-P6) form with
    # any maxval up to 65535 and comments anywhere in the header, and PAM (P7)
    # with the BLACKANDWHITE, GRAYSCALE and RGB tuple types (and their _ALPHA
    # variants, composited over white). Only the first image of a multi-image
    # file is read. Samples are scaled to 8 bits with rounding, except that
    # maxval 65535 keeps the high byte (like PNG).
    module PNM
      # Whitespace and comments (atomic, so a failed match cannot backtrack
      # through them), then the next header token.
      HEADER_INT = /\G(?>(?:\s|#[^\r\n]*)*)(\d+)/n
      PAM_LINE = /\G(?>(?:\s|#[^\r\n]*)*)([A-Za-z_]+)[ \t]*([^\r\n]*)/n
      COMMENT = /#[^\r\n]*/n
      LINE_END = /[\r\n]/n
      NOT_PLAIN_SAMPLE = /[^0-9 \t\n\v\f\r]/n
      LEADING_INT = /\A\s*(\d+)/n
      PBM_LUMA = "\xFF\x00".b # "0" white, "1" black
      SEPARATORS = WHITESPACE.bytes.freeze

      # PAM tuple type => channel count.
      TUPLE_TYPES = {
        "BLACKANDWHITE" => 1, "GRAYSCALE" => 1, "RGB" => 3,
        "BLACKANDWHITE_ALPHA" => 2, "GRAYSCALE_ALPHA" => 2, "RGB_ALPHA" => 4
      }.freeze

      class << self
        def decode(bytes)
          Decoder.new(Support.binary(bytes)).decode
        end

        def dimensions(bytes)
          Decoder.new(Support.binary(bytes)).dimensions
        end
      end

      # Parses the header on creation; @pos then points at the raster.
      class Decoder
        def initialize(bytes)
          raise ImageError, "not a PNM file" unless PNM_MAGIC.match?(bytes)

          @bytes = bytes
          @kind = bytes.getbyte(1) - 48
          @pos = 2
          if @kind == 7
            raise UnsupportedImageError, "XV thumbnail images (P7 332) are not supported" if bytes.start_with?("P7 332")

            read_pam_header
          else
            @width = read_int
            @height = read_int
            @maxval = @kind == 1 || @kind == 4 ? 1 : read_int
            @channels = @kind == 3 || @kind == 6 ? 3 : 1
          end
          raise ImageError, "invalid PNM maxval #{@maxval}" unless @maxval.between?(1, 65_535)

          Support.check_dimensions(@width, @height, "PNM")
          skip_raster_separator if @kind >= 4 && @kind <= 6
        end

        def dimensions
          [@width, @height]
        end

        def decode
          gray =
            case @kind
            when 1 then plain_bits
            when 2, 3 then luminance(plain_samples)
            when 4 then packed_bits
            else raw_luminance
            end
          Image.new(@width, @height, gray)
        end

        private

        def read_int
          m = HEADER_INT.match(@bytes, @pos) or raise ImageError, "invalid or truncated PNM header"
          raise ImageError, "invalid PNM header value" if m[1].bytesize > 10

          @pos = m.end(0)
          m[1].to_i
        end

        # Exactly one whitespace byte separates the header from raw rasters.
        # A comment may also follow the last header value directly; then the
        # end of its line is the separator (as in libnetpbm and ImageMagick).
        def skip_raster_separator
          byte = @bytes.getbyte(@pos)
          if byte == 35 # "#"
            eol = @bytes.byteindex(LINE_END, @pos) or raise ImageError, "truncated PNM header"
            @pos = eol + 1
            return
          end
          raise ImageError, "truncated PNM header" unless SEPARATORS.include?(byte)

          @pos += 1
        end

        def read_pam_header
          fields = {}
          tuple_type = []
          loop do
            m = PAM_LINE.match(@bytes, @pos) or raise ImageError, "invalid or truncated PAM header"
            @pos = m.end(0)
            key = m[1].upcase
            case key
            when "ENDHDR" then break
            when "TUPLTYPE" then tuple_type << m[2].strip
            when "WIDTH", "HEIGHT", "DEPTH", "MAXVAL"
              value = LEADING_INT.match(m[2]) or raise ImageError, "invalid PAM #{key}"
              raise ImageError, "invalid PAM #{key}" if value[1].bytesize > 10

              fields[key] = value[1].to_i
            end
          end
          @pos += 1 if @bytes.getbyte(@pos) == 13
          @pos += 1 if @bytes.getbyte(@pos) == 10

          missing = %w[WIDTH HEIGHT DEPTH MAXVAL] - fields.keys
          raise ImageError, "PAM header lacks #{missing.join(', ')}" unless missing.empty?

          @width, @height, @maxval = fields.values_at("WIDTH", "HEIGHT", "MAXVAL")
          @channels = fields["DEPTH"]
          check_tuple_type(tuple_type.join(" "))
        end

        # Unknown tuple types are inferred from the depth, except that four
        # channels of unknown meaning are most likely CMYK.
        def check_tuple_type(type)
          raise ImageError, "invalid PAM depth 0" if @channels.zero?
          raise UnsupportedImageError, "PAM depth #{@channels} is not supported" if @channels > 4

          expected = TUPLE_TYPES[type]
          if expected && expected != @channels
            raise ImageError, "PAM tuple type #{type} does not have depth #{@channels}"
          end
          return unless !expected && @channels == 4 && !type.empty?

          raise UnsupportedImageError, "PAM tuple type #{type.inspect} is not supported"
        end

        def sample_count
          @width * @height * @channels
        end

        # Luminance of a raw (binary) raster. Samples of maxval 65535 are
        # read in place (their high bytes); other maxvals are scaled first.
        def raw_luminance
          wide = @maxval > 255
          size = sample_count * (wide ? 2 : 1)
          raw = @bytes.byteslice(@pos, size)
          raise ImageError, "truncated PNM pixel data" if raw.nil? || raw.bytesize < size

          if !wide
            luminance(@maxval == 255 ? raw : Support.translate!(raw, ALL_BYTES, scale_table(255)))
          elsif @maxval == 65_535
            luminance(raw, 2)
          else
            luminance(scale16(raw))
          end
        end

        # Big-endian 16-bit samples (maxval 256..65534) scaled to 8 bits.
        def scale16(raw)
          max = @maxval
          table = scale_table(max)
          step = @width * @channels
          out = Support.buffer(raw.bytesize / 2)
          off = 0
          @height.times do # row by row, so that YJIT compiles scale16_row
            scale16_row(raw, off, step, table, max, out)
            off += 2 * step
          end
          out
        end

        def scale16_row(raw, i, n, table, max, out)
          stop = i + 2 * n
          while i < stop
            v = (raw.getbyte(i) << 8) | raw.getbyte(i + 1)
            out << (v >= max ? 255 : table[v])
            i += 2
          end
        end

        # 8-bit samples of a plain (ASCII) raster. Digits and whitespace
        # only (the usual case) are split at C speed, anything else is
        # scanned for numbers.
        def plain_samples
          text = @bytes.byteslice(@pos, @bytes.bytesize - @pos).gsub(COMMENT, "")
          values = NOT_PLAIN_SAMPLE.match?(text) ? text.scan(/\d+/) : text.split
          n = sample_count
          raise ImageError, "truncated PNM pixel data" if values.size < n

          scale_values(values.first(n).map!(&:to_i))
        end

        # Sample value -> 8 bits; values above maxval saturate. Maxval 65535
        # keeps the high byte, the same as raw rasters and 16-bit PNG.
        def scale_table(top)
          max = @maxval
          return Array.new(top + 1) { |v| v >> 8 } if max == 65_535

          Array.new(top + 1) { |v| v >= max ? 255 : (v * 255 + max / 2) / max }
        end

        def scale_values(values)
          max = @maxval
          table = scale_table(max)
          n = values.size
          out = Support.buffer(n)
          step = @width * @channels
          i = 0
          while i < n # row by row, so that YJIT compiles scale_row
            scale_row(values, i, [i + step, n].min, table, max, out)
            i += step
          end
          out
        end

        def scale_row(values, i, stop, table, max, out)
          while i < stop
            v = values[i]
            out << (v >= max ? 255 : table[v])
            i += 1
          end
        end

        # Gray, gray+alpha, RGB or RGBA samples -> luminance. +size+ is the
        # sample size in bytes: of 16-bit samples only the high byte is read.
        def luminance(samples, size = 1)
          return samples if @channels == 1 && size == 1

          w = @width
          step = w * @channels * size
          out = Support.buffer(w * @height)
          table = Support.over_white_table if @channels.even?
          off = 0
          @height.times do
            luminance_row(samples, off, size, table, out)
            off += step
          end
          out
        end

        def luminance_row(samples, off, s, table, out)
          w = @width
          case @channels
          when 1 then Rows.high_bytes(samples, off, w, out) # 16-bit only: 8-bit gray is returned as is
          when 2 then Rows.gray_alpha(samples, off, w, out, table, s, 2 * s)
          when 3 then Rows.rgb(samples, off, w, out, 0, s, 2 * s, 3 * s)
          else Rows.rgba(samples, off, w, out, table, 0, s, 2 * s, 3 * s, 4 * s)
          end
        end

        # P1: "1" is black; digits need not be separated.
        def plain_bits
          n = @width * @height
          bits = @bytes.byteslice(@pos, @bytes.bytesize - @pos).gsub(COMMENT, "").delete(WHITESPACE).byteslice(0, n)
          raise ImageError, "truncated PBM pixel data" if bits.bytesize < n || bits.count("01") < n

          bits.tr!("01", PBM_LUMA)
          bits
        end

        # P4: rows of MSB-first bits padded to whole bytes; 1 is black.
        def packed_bits
          w = @width
          stride = (w + 7) >> 3
          raise ImageError, "truncated PBM pixel data" if @pos + stride * @height > @bytes.bytesize

          out = Support.buffer(w * @height)
          format = "B#{w}"
          @height.times { |y| out << @bytes.unpack1(format, offset: @pos + y * stride) }
          out.tr!("01", PBM_LUMA)
          out
        end
      end
      private_constant :Decoder
    end
  end
end
