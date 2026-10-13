# frozen_string_literal: true

module QrReader
  module Formats
    module JPEG2000
      # A JP2 palette (pclr box): +entries+ is an Array of rows, one Integer
      # per column; +depths+ / +signed+ describe each column.
      Palette = Struct.new(:entries, :depths, :signed)

      # Channel definition (cdef): channel index, type (0 colour, 1
      # opacity, 2 premultiplied opacity, 65535 unspecified) and the colour
      # it belongs to (0 whole image, 1..n colour n, 65535 none).
      ChannelDef = Struct.new(:channel, :type, :assoc)

      # What the JP2 boxes say about a codestream.
      Header = Struct.new(:codestream, :enum_cs, :icc_space, :palette, :cmap, :cdef)

      # JP2 / JPX file format boxes (ITU-T T.800 Annex I): finds the
      # codestream and the colour information. Raw codestreams (starting
      # with SOC SIZ) are accepted too.
      module Container
        SIGNATURE = "\x00\x00\x00\x0CjP  \r\n\x87\n".b.freeze
        SOC_SIZ = "\xFF\x4F\xFF\x51".b.freeze

        module_function

        # Parses +bytes+ (a binary String) into a Header.
        def parse(bytes)
          return Header.new(bytes) if bytes.start_with?(SOC_SIZ)
          raise ImageError, "not a JPEG 2000 file" unless bytes.start_with?(SIGNATURE)

          header = Header.new
          each_box(bytes, 0, bytes.bytesize, true) do |type, start, stop|
            case type
            when "jp2h" then parse_jp2h(bytes, start, stop, header)
            when "jp2c"
              header.codestream = bytes.byteslice(start, stop - start)
              break
            end
          end
          raise ImageError, "JPEG 2000 file contains no codestream" unless header.codestream

          header
        end

        # Yields [type, content start, content end] of the boxes in
        # bytes[pos...stop]. A box running past the end is clipped (a
        # truncated file) when +lenient+.
        def each_box(bytes, pos, stop, lenient)
          while pos + 8 <= stop
            length = bytes.byteslice(pos, 4).unpack1("N")
            type = bytes.byteslice(pos + 4, 4)
            header = 8
            if length == 1
              raise ImageError, "truncated JPEG 2000 box" if pos + 16 > stop

              length = bytes.byteslice(pos + 8, 8).unpack1("Q>")
              header = 16
            elsif length.zero?
              length = stop - pos
            end
            raise ImageError, "invalid JPEG 2000 box length" if length < header

            box_end = pos + length
            if box_end > stop
              raise ImageError, "truncated JPEG 2000 box" unless lenient

              box_end = stop
            end
            yield type, pos + header, box_end
            pos = box_end
          end
        end

        def parse_jp2h(bytes, pos, stop, header)
          each_box(bytes, pos, stop, true) do |type, start, box_end|
            case type
            when "colr" then parse_colr(bytes, start, box_end, header)
            when "pclr" then header.palette = parse_pclr(bytes, start, box_end)
            when "cmap" then header.cmap = parse_cmap(bytes, start, box_end)
            when "cdef" then header.cdef = parse_cdef(bytes, start, box_end)
            end
          end
        end

        # Only the first colr box counts (I.5.3.3).
        def parse_colr(bytes, pos, stop, header)
          return if header.enum_cs || header.icc_space || stop - pos < 3

          method = bytes.getbyte(pos)
          if method == 1
            header.enum_cs = bytes.byteslice(pos + 3, 4).unpack1("N") if stop - pos >= 7
          elsif method == 2 || method == 3
            # The ICC profile header's colour space signature (offset 16).
            header.icc_space = bytes.byteslice(pos + 3 + 16, 4) if stop - pos >= 3 + 20
          end
        end

        def parse_pclr(bytes, pos, stop)
          raise ImageError, "invalid JPEG 2000 palette" if stop - pos < 3

          count = bytes.byteslice(pos, 2).unpack1("n")
          columns = bytes.getbyte(pos + 2)
          raise ImageError, "invalid JPEG 2000 palette" if count.zero? || count > 1024 || columns.zero?

          pos += 3
          raise ImageError, "truncated JPEG 2000 palette" if pos + columns > stop

          depths = Array.new(columns) { |i| (bytes.getbyte(pos + i) & 0x7F) + 1 }
          signed = Array.new(columns) { |i| bytes.getbyte(pos + i) >= 0x80 }
          raise UnsupportedImageError, "JPEG 2000 palette entries over 32 bits" if depths.max > 32

          pos += columns
          sizes = depths.map { |d| (d + 7) >> 3 }
          raise ImageError, "truncated JPEG 2000 palette" if pos + count * sizes.sum > stop

          entries = Array.new(count) do
            sizes.map do |size|
              v = 0
              size.times do
                v = (v << 8) | bytes.getbyte(pos)
                pos += 1
              end
              v
            end
          end
          Palette.new(entries, depths, signed)
        end

        def parse_cmap(bytes, pos, stop)
          list = []
          while pos + 4 <= stop
            list << [bytes.byteslice(pos, 2).unpack1("n"), bytes.getbyte(pos + 2), bytes.getbyte(pos + 3)]
            pos += 4
          end
          list
        end

        def parse_cdef(bytes, pos, stop)
          return nil if stop - pos < 2

          n = bytes.byteslice(pos, 2).unpack1("n")
          pos += 2
          list = []
          n.times do
            break if pos + 6 > stop

            list << ChannelDef.new(*bytes.byteslice(pos, 6).unpack("n3"))
            pos += 6
          end
          list
        end
      end
    end
  end
end
