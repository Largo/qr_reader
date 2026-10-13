# frozen_string_literal: true

module QrReader
  module Formats
    module JPEG2000
      # One image component as declared by SIZ: sample +precision+ in bits
      # (1..38), +signed+ samples, and the sub-sampling factors +dx+, +dy+.
      Component = Struct.new(:precision, :signed, :dx, :dy)

      # The component-specific coding style of COD / COC (SPcod / SPcoc):
      # decomposition +levels+, code-block exponents +xcb+, +ycb+ (2..10),
      # code-block style flags, +reversible+ (5/3) or not (9/7), and the
      # precinct exponents [[ppx, ppy], ...] per resolution (0 = lowest).
      CodingStyle = Struct.new(:levels, :xcb, :ycb, :cblk_style, :reversible, :precincts)

      # QCD / QCC: +style+ (0 none, 1 scalar derived, 2 scalar expounded),
      # +guard_bits+ and +steps+ [[exponent, mantissa], ...] per subband.
      Quantization = Struct.new(:style, :guard_bits, :steps)

      # One progression of a POC marker (or the single default one).
      Progression = Struct.new(:res_start, :comp_start, :layer_end, :res_end, :comp_end, :order)

      # Coding parameters that tile-part headers may override: the main
      # header holds the defaults, each tile its own overrides (nil = not
      # set at this level).
      class Params
        attr_accessor :order, :layers, :mct, :sop, :eph, :style, :coc, :qcd, :qcc, :rgn, :pocs, :ppt

        def initialize
          @coc = {}
          @qcc = {}
          @rgn = {}
          @pocs = nil
          @ppt = nil
        end
      end

      # A tile's tile-parts: header parameters and the byte ranges of the
      # packet data in the codestream.
      class TileInfo
        attr_reader :index, :params, :ranges, :ppm
        attr_accessor :parts

        def initialize(index)
          @index = index
          @params = Params.new
          @ranges = []
          @ppm = nil
          @parts = 0
        end

        def add_ppm(chunk)
          (@ppm ||= "".b) << chunk
        end
      end

      # Parser for a JPEG 2000 codestream (ITU-T T.800 / ISO 15444-1 Annex A):
      # the main header and the index of all tile-parts. Packet data is not
      # touched here.
      class Codestream
        # Part 2 (and later) marker segments that change the decoding.
        PART2_MARKERS = {
          0xFF70 => "DCO", 0xFF71 => "VMS", 0xFF72 => "DFS", 0xFF73 => "ADS", 0xFF74 => "MCT",
          0xFF75 => "MCC", 0xFF76 => "NLT", 0xFF77 => "MCO", 0xFF78 => "CBD", 0xFF79 => "ATK"
        }.freeze

        # Most tiles a codestream may have (Isot is 16 bits).
        MAX_TILES = 65_535

        attr_reader :data, :x0, :y0, :x1, :y1, :tile_x0, :tile_y0, :tile_w, :tile_h, :tiles_x, :tiles_y,
                    :components, :main, :tiles, :capabilities

        # Parses the codestream +data+ (a binary String starting with SOC).
        def initialize(data)
          @data = data
          @size = data.bytesize
          raise ImageError, "not a JPEG 2000 codestream" unless @size >= 4 && u16(0) == 0xFF4F

          raise ImageError, "JPEG 2000 codestream lacks the SIZ marker" unless u16(2) == 0xFF51

          @main = Params.new
          @tiles = {}
          @ppm_chunks = nil
          pos = parse_main_header(2)
          parse_tile_parts(pos)
        end

        # [width, height] of the image in codestream +data+, read from SIZ
        # only.
        def self.image_size(data)
          unless data.bytesize >= 4 + 2 + 38 && data.getbyte(0) == 0xFF && data.getbyte(1) == 0x4F &&
                 data.getbyte(2) == 0xFF && data.getbyte(3) == 0x51
            raise ImageError, "not a JPEG 2000 codestream"
          end

          x1, y1, x0, y0 = data.byteslice(8, 16).unpack("N4")
          raise ImageError, "invalid JPEG 2000 image area" unless x1 > x0 && y1 > y0

          [x1 - x0, y1 - y0]
        end

        # Number of tiles in the grid.
        def tile_count
          @tiles_x * @tiles_y
        end

        # Reference-grid rectangle [x0, y0, x1, y1] of tile +index+.
        def tile_rect(index)
          p = index % @tiles_x
          q = index / @tiles_x
          [[@tile_x0 + p * @tile_w, @x0].max, [@tile_y0 + q * @tile_h, @y0].max,
           [@tile_x0 + (p + 1) * @tile_w, @x1].min, [@tile_y0 + (q + 1) * @tile_h, @y1].min]
        end

        # The coding parameters of tile +info+ for component +c+:
        # [CodingStyle, Quantization, roi_shift].
        def component_params(info, c)
          t = info.params
          m = @main
          style = t.coc[c] || t.style || m.coc[c] || m.style
          raise ImageError, "JPEG 2000 codestream lacks a COD marker" unless style
          quant = t.qcc[c] || t.qcd || m.qcc[c] || m.qcd
          raise ImageError, "JPEG 2000 codestream lacks a QCD marker" unless quant

          roi = t.rgn.fetch(c) { m.rgn.fetch(c, 0) }
          [style, quant, roi]
        end

        # Tile-wide parameter +name+ (:order, :layers, :mct, :sop, :eph).
        def tile_param(info, name)
          value = info.params.public_send(name)
          value.nil? ? @main.public_send(name) : value
        end

        # The progressions of tile +info+ (its POC, else the main POC, else
        # the default progression order over everything).
        def progressions(info)
          pocs = info.params.pocs || @main.pocs
          return pocs if pocs

          [Progression.new(0, 0, tile_param(info, :layers), 33, @components.size, tile_param(info, :order))]
        end

        private

        def u16(pos)
          (@data.getbyte(pos) << 8) | @data.getbyte(pos + 1)
        end

        def u32(pos)
          (u16(pos) << 16) | u16(pos + 2)
        end

        # Reads the marker segment at +pos+: [marker, body start, body end].
        def segment(pos)
          raise ImageError, "truncated JPEG 2000 header" if pos + 4 > @size

          marker = u16(pos)
          raise ImageError, format("invalid JPEG 2000 marker 0x%04X", marker) if marker < 0xFF00

          length = u16(pos + 2)
          raise ImageError, format("invalid length of JPEG 2000 marker 0x%04X", marker) if length < 2
          raise ImageError, "truncated JPEG 2000 header" if pos + 2 + length > @size

          [marker, pos + 4, pos + 2 + length]
        end

        def parse_main_header(pos)
          _, body, stop = segment(pos)
          parse_siz(body, stop)
          pos = stop
          loop do
            raise ImageError, "truncated JPEG 2000 main header" if pos + 2 > @size

            marker = u16(pos)
            return pos if marker == 0xFF90
            raise ImageError, "JPEG 2000 codestream contains no tiles" if marker == 0xFFD9

            marker, body, stop = segment(pos)
            parse_header_marker(marker, body, stop, @main, true)
            pos = stop
          end
        end

        def parse_siz(pos, stop)
          raise ImageError, "invalid JPEG 2000 SIZ marker" if stop - pos < 38

          @capabilities = u16(pos)
          if @capabilities & 0x8000 != 0
            raise UnsupportedImageError, "JPEG 2000 Part 2 (JPX extension) codestreams are not supported"
          end
          if @capabilities & 0x4000 != 0
            raise UnsupportedImageError, "High-throughput JPEG 2000 (HTJ2K) codestreams are not supported"
          end

          @x1, @y1, @x0, @y0, @tile_w, @tile_h, @tile_x0, @tile_y0 = (0...8).map { |i| u32(pos + 2 + 4 * i) }
          count = u16(pos + 34)
          raise ImageError, "invalid JPEG 2000 component count #{count}" if count < 1 || stop - pos < 36 + 3 * count
          raise ImageError, "invalid JPEG 2000 image area" unless @x1 > @x0 && @y1 > @y0
          unless @tile_w.positive? && @tile_h.positive? && @tile_x0 <= @x0 && @tile_y0 <= @y0 &&
                 @tile_x0 + @tile_w > @x0 && @tile_y0 + @tile_h > @y0
            raise ImageError, "invalid JPEG 2000 tile grid"
          end

          @tiles_x = (@x1 - @tile_x0 + @tile_w - 1) / @tile_w
          @tiles_y = (@y1 - @tile_y0 + @tile_h - 1) / @tile_h
          raise ImageError, "too many JPEG 2000 tiles (#{@tiles_x}x#{@tiles_y})" if @tiles_x * @tiles_y > MAX_TILES

          @components = Array.new(count) do |i|
            ssiz = @data.getbyte(pos + 36 + 3 * i)
            dx = @data.getbyte(pos + 37 + 3 * i)
            dy = @data.getbyte(pos + 38 + 3 * i)
            raise ImageError, "invalid JPEG 2000 component sub-sampling" if dx.zero? || dy.zero?

            precision = (ssiz & 0x7F) + 1
            raise UnsupportedImageError, "JPEG 2000 samples of #{precision} bits are not supported" if precision > 30

            Component.new(precision, ssiz >= 0x80, dx, dy)
          end
        end

        # Parses a main or tile-part header marker segment into +params+.
        def parse_header_marker(marker, pos, stop, params, main)
          case marker
          when 0xFF52 then parse_cod(pos, stop, params)
          when 0xFF53 then parse_coc(pos, stop, params)
          when 0xFF5C then params.qcd = parse_quant(pos, stop)
          when 0xFF5D then parse_qcc(pos, stop, params)
          when 0xFF5E then parse_rgn(pos, stop, params)
          when 0xFF5F then parse_poc(pos, stop, params)
          when 0xFF60
            raise ImageError, "PPM marker in a JPEG 2000 tile-part header" unless main

            (@ppm_chunks ||= []) << [@data.getbyte(pos), @data.byteslice(pos + 1, stop - pos - 1)]
          when 0xFF61
            raise ImageError, "PPT marker in the JPEG 2000 main header" if main

            (params.ppt ||= []) << [@data.getbyte(pos), @data.byteslice(pos + 1, stop - pos - 1)]
          when 0xFF51 then raise ImageError, "duplicate JPEG 2000 SIZ marker"
          else
            name = PART2_MARKERS[marker]
            raise UnsupportedImageError, "JPEG 2000 Part 2 marker #{name} is not supported" if name
            # TLM, PLM, PLT, CRG, COM, CAP, CPF and unknown segments: skipped.
          end
        end

        def component_index(pos)
          if @components.size < 257
            [@data.getbyte(pos), pos + 1]
          else
            [u16(pos), pos + 2]
          end
        end

        def check_component(c)
          raise ImageError, "JPEG 2000 marker for nonexistent component #{c}" if c >= @components.size
        end

        def parse_cod(pos, stop, params)
          raise ImageError, "invalid JPEG 2000 COD marker" if stop - pos < 10

          scod = @data.getbyte(pos)
          order = @data.getbyte(pos + 1)
          raise ImageError, "invalid JPEG 2000 progression order #{order}" if order > 4

          layers = u16(pos + 2)
          raise ImageError, "invalid JPEG 2000 layer count" if layers.zero?

          mct = @data.getbyte(pos + 4)
          raise UnsupportedImageError, "JPEG 2000 Part 2 multi-component transforms are not supported" if mct > 1

          params.order = order
          params.layers = layers
          params.mct = mct
          params.sop = scod & 2 != 0
          params.eph = scod & 4 != 0
          params.style = parse_spcod(pos + 5, stop, scod & 1 != 0)
        end

        def parse_coc(pos, stop, params)
          c, pos = component_index(pos)
          check_component(c)
          raise ImageError, "invalid JPEG 2000 COC marker" if pos >= stop

          params.coc[c] = parse_spcod(pos + 1, stop, @data.getbyte(pos) & 1 != 0)
        end

        def parse_spcod(pos, stop, precincts)
          raise ImageError, "invalid JPEG 2000 coding style marker" if stop - pos < 5

          levels = @data.getbyte(pos)
          raise ImageError, "invalid JPEG 2000 decomposition level count #{levels}" if levels > 32

          xcb = @data.getbyte(pos + 1) + 2
          ycb = @data.getbyte(pos + 2) + 2
          raise ImageError, "invalid JPEG 2000 code-block size" if xcb > 10 || ycb > 10 || xcb + ycb > 12

          style = @data.getbyte(pos + 3)
          raise UnsupportedImageError, "high-throughput (HTJ2K) code-blocks are not supported" if style & 0xC0 != 0

          transform = @data.getbyte(pos + 4)
          raise UnsupportedImageError, "JPEG 2000 Part 2 wavelet kernels are not supported" if transform > 1

          sizes = Array.new(levels + 1) do |r|
            next [15, 15] unless precincts

            raise ImageError, "truncated JPEG 2000 precinct sizes" if pos + 5 + r >= stop

            b = @data.getbyte(pos + 5 + r)
            ppx = b & 15
            ppy = b >> 4
            raise ImageError, "invalid JPEG 2000 precinct size" if r.positive? && (ppx.zero? || ppy.zero?)

            [ppx, ppy]
          end
          CodingStyle.new(levels, xcb, ycb, style, transform == 1, sizes)
        end

        def parse_quant(pos, stop)
          raise ImageError, "invalid JPEG 2000 quantization marker" if pos >= stop

          sq = @data.getbyte(pos)
          style = sq & 0x1F
          guard = sq >> 5
          pos += 1
          steps = []
          case style
          when 0
            while pos < stop
              steps << [@data.getbyte(pos) >> 3, 0]
              pos += 1
            end
          when 1, 2
            while pos + 1 < stop
              v = u16(pos)
              steps << [v >> 11, v & 0x7FF]
              pos += 2
              break if style == 1
            end
          else
            raise ImageError, "invalid JPEG 2000 quantization style #{style}"
          end
          raise ImageError, "JPEG 2000 quantization marker without step sizes" if steps.empty?

          Quantization.new(style, guard, steps)
        end

        def parse_qcc(pos, stop, params)
          c, pos = component_index(pos)
          check_component(c)
          params.qcc[c] = parse_quant(pos, stop)
        end

        def parse_rgn(pos, stop, params)
          c, pos = component_index(pos)
          check_component(c)
          raise ImageError, "invalid JPEG 2000 RGN marker" if pos + 2 > stop
          raise UnsupportedImageError, "JPEG 2000 ROI style #{@data.getbyte(pos)}" unless @data.getbyte(pos).zero?

          params.rgn[c] = @data.getbyte(pos + 1)
        end

        def parse_poc(pos, stop, params)
          wide = @components.size >= 257
          entry = wide ? 9 : 7
          list = params.pocs || []
          while pos + entry <= stop
            rs = @data.getbyte(pos)
            cs, p = component_index(pos + 1)
            le = u16(p)
            re = @data.getbyte(p + 2)
            ce, p = component_index(p + 3)
            ce = 256 if ce.zero? && !wide
            order = @data.getbyte(p)
            raise ImageError, "invalid JPEG 2000 POC progression order" if order > 4

            list << Progression.new(rs, cs, le, re, ce, order)
            pos += entry
          end
          params.pocs = list
        end

        def parse_tile_parts(pos)
          ppm = ppm_stream
          ppm_pos = 0
          while pos + 12 <= @size && u16(pos) == 0xFF90
            raise ImageError, "invalid JPEG 2000 SOT marker" unless u16(pos + 2) == 10

            index = u16(pos + 4)
            psot = u32(pos + 6)
            raise ImageError, "invalid JPEG 2000 tile index #{index}" if index >= tile_count

            last = psot.zero?
            stop = last ? @size : pos + psot
            raise ImageError, "invalid JPEG 2000 tile-part length" if !last && psot < 14

            stop = @size if stop > @size
            info = (@tiles[index] ||= TileInfo.new(index))
            info.parts += 1
            hpos = pos + 12
            loop do
              break if hpos + 2 > stop

              marker = u16(hpos)
              if marker == 0xFF93
                hpos += 2
                break
              end
              marker, body, seg_end = segment(hpos)
              parse_header_marker(marker, body, seg_end, info.params, false)
              hpos = seg_end
            end
            info.ranges << [hpos, stop] if hpos < stop
            if ppm
              raise ImageError, "JPEG 2000 PPM marker too short" if ppm_pos + 4 > ppm.bytesize

              n = (ppm.getbyte(ppm_pos) << 24) | (ppm.getbyte(ppm_pos + 1) << 16) |
                  (ppm.getbyte(ppm_pos + 2) << 8) | ppm.getbyte(ppm_pos + 3)
              info.add_ppm(ppm.byteslice(ppm_pos + 4, n) || "".b)
              ppm_pos += 4 + n
            end
            pos = stop
            break if last
          end
          finish_ppt
        end

        # All PPM data of the main header in Zppm order, or nil.
        def ppm_stream
          return nil unless @ppm_chunks

          @ppm_chunks.sort_by.with_index { |(z, _), i| [z, i] }.map(&:last).join.b
        end

        # Joins each tile's PPT chunks in Zppt order.
        def finish_ppt
          @tiles.each_value do |info|
            chunks = info.params.ppt
            next unless chunks

            info.params.ppt = chunks.sort_by.with_index { |(z, _), i| [z, i] }.map(&:last).join.b
          end
        end
      end
    end
  end
end
