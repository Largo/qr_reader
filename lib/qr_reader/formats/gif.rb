# frozen_string_literal: true

module QrReader
  module Formats
    # GIF decoder (87a/89a). Decodes the first frame only, drawn on a white
    # canvas of the logical screen size (grown to fit the frame if the
    # screen is smaller); transparent pixels (graphic control extension)
    # show the white canvas. Global and local palettes and interlacing are
    # supported.
    module GIF
      # Interlaced row order: [first row, step] of the four passes.
      INTERLACE_PASSES = [[0, 8], [4, 8], [2, 4], [1, 2]].freeze

      # One-byte Strings, the initial LZW dictionary entries.
      BYTES = Array.new(256) { |b| b.chr.b.freeze }.freeze

      class << self
        def decode(bytes)
          Decoder.new(Support.binary(bytes)).decode
        end

        def dimensions(bytes)
          Decoder.new(Support.binary(bytes)).dimensions
        end
      end

      # Reads the stream up to the first image descriptor on creation.
      class Decoder
        def initialize(bytes)
          raise ImageError, "not a GIF file" unless GIF_MAGIC.match?(bytes)
          raise ImageError, "truncated GIF header" if bytes.bytesize < 13

          @bytes = bytes
          screen_w, screen_h, flags = bytes.unpack("vvC", offset: 6)
          pos = 13
          if flags.anybits?(0x80)
            @palette = read_palette(pos, flags)
            pos += @palette.bytesize
          end
          read_first_image(pos)
          @canvas_w = [screen_w, @left + @frame_w].max
          @canvas_h = [screen_h, @top + @frame_h].max
          Support.check_dimensions(@canvas_w, @canvas_h, "GIF")
        end

        def dimensions
          [@canvas_w, @canvas_h]
        end

        def decode
          n = @frame_w * @frame_h
          return Image.new(@canvas_w, @canvas_h, WHITE * (@canvas_w * @canvas_h)) if n.zero?

          min_size = @bytes.getbyte(@data_pos) or raise ImageError, "truncated GIF image data"
          indices = LZW.new(read_sub_blocks(@data_pos + 1), min_size).decode(n)
          pixels = Support.translate!(indices, ALL_BYTES, lumas)
          pixels << (WHITE * (n - pixels.bytesize)) if pixels.bytesize < n # stream ended early
          pixels = deinterlace(pixels) if @interlaced
          Image.new(@canvas_w, @canvas_h, compose(pixels))
        end

        private

        def read_palette(pos, flags)
          size = 3 << ((flags & 7) + 1)
          raise ImageError, "truncated GIF palette" if pos + size > @bytes.bytesize

          @bytes.byteslice(pos, size)
        end

        # Skips extensions (remembering the transparent colour of a graphic
        # control extension) up to the first image descriptor.
        def read_first_image(pos)
          bytes = @bytes
          loop do
            case bytes.getbyte(pos)
            when 0x2C
              raise ImageError, "truncated GIF image descriptor" if pos + 10 > bytes.bytesize

              @left, @top, @frame_w, @frame_h, flags = bytes.unpack("vvvvC", offset: pos + 1)
              @interlaced = flags.anybits?(0x40)
              pos += 10
              if flags.anybits?(0x80)
                @palette = read_palette(pos, flags)
                pos += @palette.bytesize
              end
              @data_pos = pos
              return
            when 0x21
              label = bytes.getbyte(pos + 1)
              if label == 0xF9 && bytes.getbyte(pos + 2) == 4 && pos + 7 <= bytes.bytesize
                @transparent = (bytes.getbyte(pos + 6) if bytes.getbyte(pos + 3).anybits?(1))
              end
              pos = skip_sub_blocks(pos + 2)
            when 0x3B then raise ImageError, "GIF contains no image"
            when nil then raise ImageError, "truncated GIF (no image)"
            else raise ImageError, format("corrupt GIF (unexpected block 0x%02X)", bytes.getbyte(pos))
            end
          end
        end

        def skip_sub_blocks(pos)
          bytes = @bytes
          while (n = bytes.getbyte(pos))
            return pos + 1 if n.zero?

            pos += n + 1
          end
          raise ImageError, "truncated GIF extension"
        end

        # Concatenated data sub-blocks (shorter if the file is truncated).
        def read_sub_blocks(pos)
          bytes = @bytes
          data = Support.buffer(0)
          while (n = bytes.getbyte(pos)) && n.positive?
            data << bytes.byteslice(pos + 1, n)
            pos += n + 1
          end
          data
        end

        # Palette luminance per index; the transparent index is white.
        # Without any palette the indices are used as gray levels.
        def lumas
          lumas = @palette ? Support.palette_lumas(@palette) : Array.new(256) { |i| i }
          lumas[@transparent] = 255 if @transparent
          lumas
        end

        def deinterlace(pixels)
          w = @frame_w
          h = @frame_h
          rows = Array.new(h)
          src = 0
          INTERLACE_PASSES.each do |first, step|
            y = first
            while y < h
              rows[y] = pixels.byteslice(src, w)
              src += w
              y += step
            end
          end
          rows.join
        end

        # Places the frame on the white canvas.
        def compose(pixels)
          cw = @canvas_w
          fw = @frame_w
          return pixels if fw == cw && @frame_h == @canvas_h

          canvas = WHITE * (cw * @canvas_h)
          r = 0
          while r < @frame_h
            canvas.bytesplice((@top + r) * cw + @left, fw, pixels.byteslice(r * fw, fw))
            r += 1
          end
          canvas
        end
      end
      private_constant :Decoder

      # Variable-width LZW decoder (LSB-first codes, 12 bits max, deferred
      # clear). Dictionary entries are Strings, so each code costs one
      # C-level copy. Decoding resumes in slices of SLICE output bytes, with
      # the state in instance variables in between: YJIT only compiles
      # methods that are entered repeatedly, never a single long loop.
      class LZW
        SLICE = 2048

        def initialize(data, min_size)
          raise ImageError, "invalid GIF LZW code size #{min_size}" unless min_size.between?(1, 8)

          @data = data
          @min_size = min_size
          @clear = 1 << min_size
          @dict = BYTES.first(@clear)
          @size = min_size + 1
          @avail = @clear + 2
          @prev = nil
          @buf = @bits = @pos = 0
          @finished = false
        end

        # Up to +n+ palette indices; fewer only if an end code arrives early.
        def decode(n)
          out = Support.buffer(n)
          decode_slice(out, [out.bytesize + SLICE, n].min) until @finished || out.bytesize >= n
          out.bytesize > n ? out.byteslice(0, n) : out
        end

        private

        def decode_slice(out, target)
          data = @data
          len = data.bytesize
          dict = @dict
          clear = @clear
          size = @size
          mask = (1 << size) - 1
          avail = @avail
          prev = @prev
          buf = @buf
          bits = @bits
          pos = @pos
          while out.bytesize < target
            while bits < size
              raise ImageError, "truncated GIF image data" if pos >= len

              buf |= data.getbyte(pos) << bits
              bits += 8
              pos += 1
            end
            code = buf & mask
            buf >>= size
            bits -= size

            if code == clear
              size = @min_size + 1
              mask = (1 << size) - 1
              avail = clear + 2
              prev = nil
              next
            end
            if code == clear + 1 # end of information
              @finished = true
              break
            end

            added = nil
            if prev.nil? # first code after a clear: a literal
              raise ImageError, "corrupt GIF LZW data" unless code < clear

              entry = dict[code]
            elsif code < avail
              entry = dict[code]
              added = prev + BYTES[entry.getbyte(0)]
            elsif code == avail # the entry being defined: prev + its own first byte
              entry = added = prev + BYTES[prev.getbyte(0)]
            else
              raise ImageError, "corrupt GIF LZW data"
            end
            out << entry
            if added && avail < 4096
              dict[avail] = added
              avail += 1
            end
            # Grow once the next free code needs another bit (with minimum
            # code size 1 that is already the case after the first literal).
            if avail > mask && size < 12
              size += 1
              mask = (1 << size) - 1
            end
            prev = entry
          end
          @size = size
          @avail = avail
          @prev = prev
          @buf = buf
          @bits = bits
          @pos = pos
        end
      end
      private_constant :LZW
    end
  end
end
