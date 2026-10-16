# frozen_string_literal: true

require "zlib"
require_relative "../kernels/png"

module QrReader
  module Formats
    # PNG decoder: every colour type and bit depth (1/2/4/8/16), PLTE + tRNS,
    # alpha composited over white, Adam7 interlacing, any number of IDAT chunks.
    # Ancillary chunks (gamma, colour profiles, text, APNG frames, ...) are
    # ignored, and chunk CRCs are not verified (like most lenient decoders).
    #
    # The image data is inflated as a stream and handed to the PNG kernel
    # (QrReaderKernels.png_rows, kernels/png.rb) about a megabyte at a time:
    # the kernel unfilters the rows and converts them to luminance in one
    # pass, so the whole inflated image never exists at once. Palette and
    # grayscale images of up to 8 bits come out of the kernel as unfiltered
    # rows; 1 and 4-bit samples are spread to one character per sample with
    # String#unpack1 ("B" / "H", C speed) and everything is mapped to
    # luminance with a single String#tr at the end. 16-bit samples keep
    # their high byte.
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

      # Bytes standing for the sample values 0, 1, ... after String#unpack1
      # spread 1-bit ("B") and 4-bit ("H") rows: the String#tr sources.
      UNPACKED_CODES = { 1 => "01".bytes.freeze, 4 => "0123456789abcdef".bytes.freeze }.freeze

      # Compressed bytes fed to zlib at a time (bounds the work done for
      # zip bombs: the output of one slice is at most ~66 MB, streamed).
      INFLATE_SLICE = 16_384
      # Inflated bytes collected before a kernel call (bounds memory).
      KERNEL_SLICE = 1 << 20

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
            raw = inflate_all(ADAM7.sum { |pass| pass_size(pass) })
            out = QrReaderKernels.png_adam7(raw, w, h, @depth, @channels, @key)
            codes = ALL_BYTES
          else
            out = decode_stream
            codes = ALL_BYTES
            out, codes = unpack_samples(out) if @depth < 8
          end
          Support.translate!(out, codes.first(@tr_to.size), @tr_to) if @tr_to
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
          @channels, depths = COLOR_TYPES[@color_type]
          raise ImageError, "invalid PNG colour type #{@color_type}" unless @channels
          unless depths.include?(@depth)
            raise ImageError, "invalid PNG bit depth #{@depth} for colour type #{@color_type}"
          end
          raise ImageError, "unknown PNG compression/filter method" unless compression.zero? && filter.zero?
          raise ImageError, "unknown PNG interlace method #{interlace}" if interlace > 1
          raise ImageError, "PNG dimensions exceed 2^31 - 1" if @width > 0x7FFFFFFF || @height > 0x7FFFFFFF

          Support.check_dimensions(@width, @height, "PNG")
          @interlaced = interlace == 1
        end

        def row_bytes(width)
          (width * @channels * @depth + 7) >> 3
        end

        # Raw (filtered) byte count of an Adam7 pass.
        def pass_size((x0, y0, dx, dy))
          pw = (@width - x0 + dx - 1) / dx
          ph = (@height - y0 + dy - 1) / dy
          pw <= 0 || ph <= 0 ? 0 : ph * (1 + row_bytes(pw))
        end

        # Chooses the colour key passed to the kernel and the final
        # String#tr mapping of sample values (@tr_to[value] = luminance).
        def setup_conversion
          depth = @depth
          trns = @trns
          @key = "".b
          case @color_type
          when 0
            key = trns.unpack1("n") if trns && trns.bytesize >= 2
            max = (1 << depth) - 1
            if depth == 16
              @key = trns.byteslice(0, 2) if key
            elsif depth == 8
              if key && key <= 255
                @tr_to = ALL_BYTES.dup
                @tr_to[key] = 255
              end
            else
              @tr_to = Array.new(max + 1) { |v| v * 255 / max }
              @tr_to[key] = 255 if key && key <= max
            end
          when 2
            if trns && trns.bytesize >= 6
              rgb = trns.unpack("nnn")
              # (an 8-bit image cannot contain a key beyond 255: no key)
              @key = depth == 16 ? trns.byteslice(0, 6) : (rgb.max <= 255 ? rgb.pack("C3") : "".b)
            end
          when 3
            @tr_to = Support.palette_lumas(@palette, alpha: trns).first(1 << depth)
          end
        end

        # Packed 1, 2 and 4-bit rows -> one byte per sample, and the bytes
        # that stand for the sample values 0, 1, ...
        def unpack_samples(packed)
          w = @width
          depth = @depth
          len = row_bytes(w)
          if depth == 2
            return [QrReaderKernels.png_unpack_rows(packed, @height, w, len, 2), ALL_BYTES]
          end

          format = depth == 1 ? "B" : "H"
          if (w * depth) % 8 == 0
            out = packed.unpack1("#{format}*")
          else
            out = Support.buffer(w * @height)
            spec = "#{format}#{w}"
            off = 0
            while off < packed.bytesize
              out << packed.unpack1(spec, offset: off)
              off += len
            end
          end
          [out.b, UNPACKED_CODES[depth]]
        end

        # Inflates the image data in slices and feeds complete rows to the
        # kernel; returns the converted image (width * height bytes, or the
        # unfiltered rows of gray/palette images of less than 8 bits).
        def decode_stream
          w = @width
          rows_left = @height
          len = row_bytes(w)
          stride = len + 1
          @row_out = @channels == 1 && @depth <= 8 ? len : w
          batch = [KERNEL_SLICE / stride, 1].max * stride
          out = Support.buffer([@row_out * @height, compressed_size * 1032 + 1024].min)
          prev = "".b
          pending = nil
          each_inflated do |data|
            next if @enough

            if pending
              pending << data
            else
              pending = +data
            end
            next if pending.bytesize < batch

            n = [pending.bytesize / stride, rows_left].min
            prev = convert_rows(pending, n, w, prev, out)
            rows_left -= n
            @enough = rows_left.zero?
            pending = @enough ? nil : pending.byteslice(n * stride, pending.bytesize - n * stride)
          end
          if rows_left.positive?
            n = pending ? pending.bytesize / stride : 0
            truncated!(@height - rows_left + n, @height, "rows") if n < rows_left

            convert_rows(pending, rows_left, w, prev, out)
          end
          out
        end

        def truncated!(got, expected, unit)
          raise ImageError, "corrupt PNG image data (zlib: #{@zlib_error.message})" if @zlib_error

          raise ImageError, "truncated PNG image data (#{got} of #{expected} #{unit})"
        end

        # Runs the kernel on +n+ rows at the start of +raw+, appends their
        # output to +out+; returns the last unfiltered row.
        def convert_rows(raw, n, w, prev, out)
          res = QrReaderKernels.png_rows(raw, 0, n, w, @depth, @channels, prev, @key)
          size = n * @row_out
          out << res.byteslice(0, size)
          res.byteslice(size, res.bytesize - size)
        end

        def compressed_size
          @idat.sum { |_, length| length }
        end

        # Yields the inflated IDAT payload in pieces, until the consumer
        # sets @enough. Not through the block form of Zlib::Inflate#inflate:
        # Ruby code running inside zlib's callback (allocating, collecting
        # garbage) crashes ruby.wasm, so each slice's output is yielded after
        # the C call has returned.
        def each_inflated
          zstream = Zlib::Inflate.new
          @idat.each do |pos, length|
            stop = pos + length
            while pos < stop
              return if @enough

              n = [stop - pos, INFLATE_SLICE].min
              data = zstream.inflate(@bytes.byteslice(pos, n))
              pos += n
              yield data unless data.empty?
            end
          end
        rescue Zlib::Error => e
          # Data inflated before the error is used; what is missing is
          # reported as truncation by the caller.
          @zlib_error = e
          rest = zstream.flush_next_out.to_s
          yield rest unless rest.empty? || @enough
        ensure
          if zstream
            zstream.reset # an unfinished stream would warn on close
            zstream.close
          end
        end

        # Inflates the whole IDAT payload; returns at least +expected+ bytes.
        def inflate_all(expected)
          # Deflate expands at most 1032:1, so a few bytes of data that
          # claim a huge image never reserve (and touch) the claimed size.
          out = Support.buffer([expected, compressed_size * 1032 + 1024].min)
          each_inflated do |data|
            out << data unless @enough
            @enough = out.bytesize >= expected
          end
          truncated!(out.bytesize, expected, "bytes") if out.bytesize < expected
          out
        end
      end
      private_constant :Decoder
    end
  end
end
