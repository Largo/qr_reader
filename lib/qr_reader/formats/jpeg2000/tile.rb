# frozen_string_literal: true

module QrReader
  module Formats
    module JPEG2000
      # Raised internally when a tile's packet data is truncated or
      # corrupt: decoding keeps what was read before.
      class PacketError < StandardError; end

      # Reads packet header bits (B.10.1): MSB first, and after an 0xFF byte
      # only 7 bits of the next one are used. Reading past the end yields
      # zero bits and sets #overrun.
      class BitReader
        attr_reader :data, :pos, :overrun

        def initialize(data, pos, stop)
          @data = data
          @pos = pos
          @stop = stop
          @buf = 0
          @ct = 0
          @overrun = false
        end

        # Starts a new packet header at +pos+.
        def restart(pos)
          @pos = pos
          @buf = 0
          @ct = 0
        end

        def bit
          if @ct.zero?
            @buf = (@buf << 8) & 0xFFFF
            @ct = @buf == 0xFF00 ? 7 : 8
            if @pos < @stop
              @buf |= @data.getbyte(@pos)
              @pos += 1
            else
              @overrun = true
            end
          end
          @ct -= 1
          (@buf >> @ct) & 1
        end

        def bits(n)
          v = 0
          while n.positive?
            v = (v << 1) | bit
            n -= 1
          end
          v
        end

        # Skips to the next byte boundary (and over a stuffed byte after 0xFF).
        def align
          if @buf & 0xFF == 0xFF
            @buf = (@buf << 8) & 0xFFFF
            if @pos < @stop
              @pos += 1
            else
              @overrun = true
            end
          end
          @ct = 0
        end
      end

      # Tag tree (B.10.2) over a +w+ x +h+ grid of code-blocks.
      class TagTree
        INFINITY = 1 << 40

        def initialize(w, h)
          parents = []
          lw = w
          lh = h
          offset = 0
          loop do
            n = lw * lh
            nw = (lw + 1) >> 1
            nh = (lh + 1) >> 1
            root = n == 1
            y = 0
            while y < lh
              x = 0
              while x < lw
                parents << (root ? -1 : offset + n + (y >> 1) * nw + (x >> 1))
                x += 1
              end
              y += 1
            end
            break if root

            offset += n
            lw = nw
            lh = nh
          end
          @parent = parents
          @value = Array.new(parents.size, INFINITY)
          @low = Array.new(parents.size, 0)
        end

        # Decodes whether leaf +leaf+'s value is below +threshold+.
        def decode(bits, leaf, threshold)
          stack = []
          node = leaf
          while (p = @parent[node]) >= 0
            stack << node
            node = p
          end
          low = 0
          loop do
            if low > @low[node]
              @low[node] = low
            else
              low = @low[node]
            end
            while low < threshold && low < @value[node]
              if bits.bit == 1
                @value[node] = low
              else
                low += 1
              end
            end
            @low[node] = low
            break if stack.empty?

            node = stack.pop
          end
          @value[node] < threshold
        end
      end

      # Decoding state of one code-block: its rectangle in subband
      # coordinates, bit-planes, Lblock, and the codeword segments
      # received so far ([bytes, passes]).
      class CodeBlock
        attr_reader :x0, :y0, :x1, :y1, :segments
        attr_accessor :numbps, :lblock, :included, :seg_max, :seg_passes, :seg_count

        def initialize(x0, y0, x1, y1)
          @x0 = x0
          @y0 = y0
          @x1 = x1
          @y1 = y1
          @included = false
          @segments = []
          @seg_max = 0
          @seg_passes = 0
          @seg_count = 0
        end
      end

      # The code-blocks of one subband inside a precinct.
      PrecinctBand = Struct.new(:cblks, :inclusion, :zero_planes)

      # Subband of a tile-component resolution: orientation (0 LL, 1 HL,
      # 2 LH, 3 HH), rectangle, magnitude bit-planes Mb, step (nil when
      # reversible) and, while decoding, its coefficient rows.
      class Band
        attr_reader :orient, :x0, :y0, :x1, :y1
        attr_accessor :mb, :step, :rows

        def initialize(orient, x0, y0, x1, y1)
          @orient = orient
          @x0 = x0
          @y0 = y0
          @x1 = x1
          @y1 = y1
        end

        def width
          @x1 - @x0
        end

        def height
          @y1 - @y0
        end
      end

      # One resolution level of a tile-component.
      class Resolution
        attr_reader :r, :x0, :y0, :x1, :y1, :ppx, :ppy, :npx, :npy, :px0, :py0, :xcb, :ycb, :bands, :precincts

        def initialize(r, rect, ppx, ppy, xcb, ycb, bands)
          @r = r
          @x0, @y0, @x1, @y1 = rect
          @ppx = ppx
          @ppy = ppy
          @xcb = xcb
          @ycb = ycb
          @bands = bands
          if @x0 < @x1 && @y0 < @y1
            @px0 = @x0 >> ppx
            @py0 = @y0 >> ppy
            @npx = ((@x1 + (1 << ppx) - 1) >> ppx) - @px0
            @npy = ((@y1 + (1 << ppy) - 1) >> ppy) - @py0
          else
            @px0 = @py0 = @npx = @npy = 0
          end
          @precincts = []
        end

        def width
          @x1 - @x0
        end

        def height
          @y1 - @y0
        end

        def precinct_count
          @npx * @npy
        end

        def release
          @precincts = []
        end
      end

      # One component of a tile: geometry and coding parameters.
      class TileComponent
        attr_reader :index, :x0, :y0, :x1, :y1, :style, :roi, :resolutions, :levels, :decoded_levels

        def initialize(index, rect, style, roi, resolutions, decoded_levels)
          @index = index
          @x0, @y0, @x1, @y1 = rect
          @style = style
          @roi = roi
          @resolutions = resolutions
          @levels = style.levels
          @decoded_levels = decoded_levels
        end

        def reversible?
          @style.reversible
        end

        # Size of the decoded (possibly reduced) tile-component.
        def output_rect
          res = @resolutions[@decoded_levels]
          [res.x0, res.y0, res.x1, res.y1]
        end
      end

      # Decodes one tile: geometry (B.5-B.7), packets (tier-2, B.9-B.12),
      # code-blocks (tier-1, via Tier1) and the inverse wavelet transform.
      class TileDecoder
        # Limits for corrupt or hostile headers (per tile).
        MAX_PRECINCTS = 1 << 20
        MAX_CODEBLOCKS = 1 << 21
        # Bit-planes beyond any valid codestream (Mb <= 37 plus ROI shift).
        MAX_BITPLANES = 74
        # Largest tile-component decoded at once (samples at the decoded
        # resolution): the wavelet planes take 8 bytes per sample. Larger
        # ones need a +reduce+ factor (or tiles).
        MAX_DECODE_SAMPLES = 1 << 25

        attr_reader :components, :rect, :mct

        def initialize(codestream, info, reduce, tier1)
          @cs = codestream
          @info = info
          @reduce = reduce
          @t1 = tier1
          @rect = codestream.tile_rect(info.index)
          @layers = codestream.tile_param(info, :layers)
          @sop = codestream.tile_param(info, :sop)
          @eph = codestream.tile_param(info, :eph)
          @mct = codestream.tile_param(info, :mct)
          @codeblocks = 0
          @components = codestream.components.each_with_index.map { |comp, c| build_component(comp, c) }
          @components.each do |tc|
            x0, y0, x1, y1 = tc.output_rect
            next if (x1 - x0) * (y1 - y0) <= MAX_DECODE_SAMPLES

            raise UnsupportedImageError, "JPEG 2000 tile too large to decode at full resolution " \
                                         "(#{x1 - x0}x#{y1 - y0}); decode with reduce: 1 or more"
          end
          precincts = @components.sum { |tc| tc.resolutions.sum(&:precinct_count) }
          return if precincts <= MAX_PRECINCTS

          raise UnsupportedImageError, "too many JPEG 2000 precincts in a tile (#{precincts})"
        end

        # Reads all packets of the tile (tier-2). Truncated or damaged
        # packet data ends the tile's packets early.
        def read_packets
          data = @info.ranges.map { |a, b| @cs.data.byteslice(a, b - a) }.join.b
          @data = data
          @pos = 0
          @stop = data.bytesize
          headers = @info.ppm || @info.params.ppt
          if headers
            @hbits = BitReader.new(headers, 0, headers.bytesize)
            @separate = true
          else
            @hbits = BitReader.new(data, 0, @stop)
            @separate = false
          end
          each_packet { |layer, res, c, p| read_packet(layer, res, c, p) }
        rescue PacketError
          nil
        ensure
          @data = nil
        end

        # Tier-1 decodes component +c+ and runs the inverse DWT: the rows
        # (Arrays of Integers or Floats) of the decoded tile-component, or
        # nil when all its coefficients are zero (no DWT needed: every
        # sample is 0).
        def component_rows(c)
          tc = @components[c]
          top = tc.decoded_levels
          zero = tc.reversible? ? 0 : 0.0
          style = tc.style.cblk_style
          r = 0
          while r <= top
            res = tc.resolutions[r]
            res.bands.each do |band|
              band.rows = Array.new(band.height) # rows are allocated by Tier1#store
            end
            res.precincts.each do |prec|
              next unless prec

              prec.each_with_index do |pb, bi|
                next unless pb

                band = res.bands[bi]
                pb.cblks.each { |cb| decode_codeblock(cb, band, tc.roi, style) }
              end
            end
            res.release
            r += 1
          end
          if tc.resolutions[0..top].all? { |rr| rr.bands.all? { |b| b.rows.none? } }
            tc.resolutions.each { |rr| rr.bands.each { |b| b.rows = nil } }
            return nil
          end

          rows = tc.resolutions[0].bands[0].rows
          r = 1
          while r <= top
            res = tc.resolutions[r]
            prev = tc.resolutions[r - 1]
            hl, lh, hh = res.bands
            rows = DWT.synthesize(rows, hl.rows, lh.rows, hh.rows, res.width, res.height, prev.width, prev.height,
                                  res.x0 & 1, res.y0 & 1, tc.reversible?)
            r += 1
          end
          tc.resolutions.each { |rr| rr.bands.each { |b| b.rows = nil } }
          width = tc.resolutions[top].width
          rows.map! { |row| row || Array.new(width, zero) } if top.zero?
          rows
        end

        private

        def ceil_div(a, b)
          -(-a / b)
        end

        def ceil_shift(a, k)
          -((-a) >> k)
        end

        def build_component(comp, c)
          style, quant, roi = @cs.component_params(@info, c)
          tx0, ty0, tx1, ty1 = @rect
          rect = [ceil_div(tx0, comp.dx), ceil_div(ty0, comp.dy), ceil_div(tx1, comp.dx), ceil_div(ty1, comp.dy)]
          levels = style.levels
          if levels < @reduce
            raise UnsupportedImageError, "cannot reduce a JPEG 2000 tile with #{levels} levels by #{@reduce}"
          end

          top = levels - @reduce
          resolutions = Array.new(levels + 1) do |r|
            lev = levels - r
            rrect = rect.map { |v| ceil_shift(v, lev) }
            ppx, ppy = style.precincts[r] || [15, 15]
            xcb = [style.xcb, r.zero? ? ppx : ppx - 1].min
            ycb = [style.ycb, r.zero? ? ppy : ppy - 1].min
            bands = if r.zero?
                      [Band.new(0, *rrect)]
                    else
                      [1, 2, 3].map do |o|
                        xo = o & 1
                        yo = o >> 1
                        Band.new(o, ceil_shift(rect[0] - (xo << lev), lev + 1),
                                 ceil_shift(rect[1] - (yo << lev), lev + 1),
                                 ceil_shift(rect[2] - (xo << lev), lev + 1),
                                 ceil_shift(rect[3] - (yo << lev), lev + 1))
                      end
                    end
            Resolution.new(r, rrect, ppx, ppy, xcb, ycb, bands)
          end
          setup_quantization(comp, style, quant, resolutions, top)
          TileComponent.new(c, rect, style, roi, resolutions, top)
        end

        # Mb and step size of every subband (E.1).
        def setup_quantization(comp, style, quant, resolutions, top)
          steps = quant.steps
          resolutions.each do |res|
            r = res.r
            res.bands.each do |band|
              if quant.style == 1
                exp, mant = steps[0]
                exp -= r - 1 if r > 1
                exp = 0 if exp.negative?
              else
                idx = r.zero? ? 0 : 3 * (r - 1) + band.orient
                exp, mant = steps[idx] || steps[-1]
              end
              band.mb = quant.guard_bits + exp - 1
              next if style.reversible || r > top

              factor = band_scale(resolutions, res, band, top)
              # OpenJPEG keeps the step size in single precision.
              base = [(1.0 + mant / 2048.0) * (2.0**(comp.precision - exp))].pack("e").unpack1("e")
              band.step = base * 0.5 * factor
            end
          end
        end

        # The 9/7 normalization factors of +band+ folded into its step.
        def band_scale(resolutions, res, band, top)
          widths = (res.r..top).map { |r| resolutions[r].width }
          heights = (res.r..top).map { |r| resolutions[r].height }
          if res.r.zero?
            widths.shift
            heights.shift
          end
          DWT.scale_factor(band.orient & 1 == 1, widths) * DWT.scale_factor(band.orient & 2 == 2, heights)
        end

        # Enumerates the packets of the tile in progression order (B.12),
        # honouring POC progression changes (each packet at most once).
        def each_packet(&)
          seen = @info.params.pocs || @cs.main.pocs ? {} : nil
          ncomp = @components.size
          @cs.progressions(@info).each do |prog|
            layers = [prog.layer_end, @layers].min
            c0 = prog.comp_start
            c1 = [prog.comp_end, ncomp].min
            r0 = prog.res_start
            r1 = [prog.res_end, 33].min
            next if layers <= 0 || c0 >= c1 || r0 >= r1

            case prog.order
            when 0 then lrcp(layers, r0, r1, c0, c1, seen, &)
            when 1 then rlcp(layers, r0, r1, c0, c1, seen, &)
            else positional(prog.order, layers, r0, r1, c0, c1, seen, &)
            end
          end
        end

        def emit(layer, r, c, p, seen)
          if seen
            key = [layer, r, c, p]
            return if seen[key]

            seen[key] = true
          end
          yield layer, @components[c].resolutions[r], c, p
        end

        def lrcp(layers, r0, r1, c0, c1, seen, &)
          layers.times do |l|
            (r0...r1).each do |r|
              (c0...c1).each do |c|
                res = @components[c].resolutions[r] or next
                res.precinct_count.times { |p| emit(l, r, c, p, seen, &) }
              end
            end
          end
        end

        def rlcp(layers, r0, r1, c0, c1, seen, &)
          (r0...r1).each do |r|
            layers.times do |l|
              (c0...c1).each do |c|
                res = @components[c].resolutions[r] or next
                res.precinct_count.times { |p| emit(l, r, c, p, seen, &) }
              end
            end
          end
        end

        # RPCL (2), PCRL (3) and CPRL (4): precincts ordered by the
        # reference-grid position at which B.12.1.3-5 visit them.
        def positional(order, layers, r0, r1, c0, c1, seen, &)
          entries = []
          (c0...c1).each do |c|
            tc = @components[c]
            (r0...r1).each do |r|
              res = tc.resolutions[r] or next
              precinct_positions(tc, res) do |y, x, p|
                entries << case order
                           when 2 then [r, y, x, c, p]
                           when 3 then [y, x, c, r, p]
                           else [c, y, x, r, p]
                           end
              end
            end
          end
          entries.sort!
          entries.each do |e|
            r, c, p = case order
                      when 2 then [e[0], e[3], e[4]]
                      when 3 then [e[3], e[2], e[4]]
                      else [e[3], e[0], e[4]]
                      end
            layers.times { |l| emit(l, r, c, p, seen, &) }
          end
        end

        # Yields [y, x, precinct] for each precinct of +res+: the first
        # tile position (on the reference grid) where the progression loops
        # of B.12.1.3 reach it.
        def precinct_positions(tc, res)
          return if res.precinct_count.zero?

          comp = @cs.components[tc.index]
          lev = tc.levels - res.r
          tx0, ty0, = @rect
          ystep = comp.dy << (res.ppy + lev)
          xstep = comp.dx << (res.ppx + lev)
          y_misaligned = res.y0 % (1 << res.ppy) != 0
          x_misaligned = res.x0 % (1 << res.ppx) != 0
          res.npy.times do |j|
            y = j.zero? && y_misaligned ? ty0 : (res.py0 + j) * ystep
            res.npx.times do |i|
              x = i.zero? && x_misaligned ? tx0 : (res.px0 + i) * xstep
              yield y, x, j * res.npx + i
            end
          end
        end

        # The precinct +p+ of +res+ (created on first use): per subband its
        # code-blocks and tag trees.
        def precinct(res, p)
          prec = res.precincts[p]
          return prec if prec

          i = p % res.npx
          j = p / res.npx
          shift_x = res.r.zero? ? res.ppx : res.ppx - 1
          shift_y = res.r.zero? ? res.ppy : res.ppy - 1
          px = (res.px0 + i) << shift_x
          py = (res.py0 + j) << shift_y
          prec = res.bands.map do |band|
            x0 = [px, band.x0].max
            y0 = [py, band.y0].max
            x1 = [px + (1 << shift_x), band.x1].min
            y1 = [py + (1 << shift_y), band.y1].min
            next nil if x0 >= x1 || y0 >= y1

            xcb = res.xcb
            ycb = res.ycb
            cx0 = x0 >> xcb
            cy0 = y0 >> ycb
            ncx = ((x1 + (1 << xcb) - 1) >> xcb) - cx0
            ncy = ((y1 + (1 << ycb) - 1) >> ycb) - cy0
            @codeblocks += ncx * ncy
            raise UnsupportedImageError, "too many JPEG 2000 code-blocks in a tile" if @codeblocks > MAX_CODEBLOCKS

            cblks = Array.new(ncx * ncy) do |k|
              bx = cx0 + k % ncx
              by = cy0 + k / ncx
              CodeBlock.new([bx << xcb, x0].max, [by << ycb, y0].max,
                            [(bx + 1) << xcb, x1].min, [(by + 1) << ycb, y1].min)
            end
            PrecinctBand.new(cblks, TagTree.new(ncx, ncy), TagTree.new(ncx, ncy))
          end
          res.precincts[p] = prec
        end

        # Reads one packet (B.9, B.10): header, then the code-block data.
        def read_packet(layer, res, c, p)
          raise PacketError if @pos >= @stop && !@separate

          tc = @components[c]
          keep = res.r <= tc.decoded_levels
          cblk_style = tc.style.cblk_style
          prec = precinct(res, p)
          data = @data
          if @sop && @pos + 6 <= @stop && data.getbyte(@pos) == 0xFF && data.getbyte(@pos + 1) == 0x91
            @pos += 6
          end
          bits = @hbits
          bits.restart(@separate ? bits.pos : @pos)
          contributions = []
          if bits.bit == 1
            res.bands.each_with_index do |band, bi|
              pb = prec[bi] or next
              pb.cblks.each_with_index do |cb, k|
                if cb.included
                  next if bits.bit.zero?
                else
                  next unless pb.inclusion.decode(bits, k, layer + 1)

                  planes = 0
                  planes += 1 until pb.zero_planes.decode(bits, k, planes + 1) || planes > MAX_BITPLANES
                  raise PacketError if planes > MAX_BITPLANES || bits.overrun

                  cb.numbps = band.mb - planes
                  cb.lblock = 3
                  cb.included = true
                end
                passes = coding_passes(bits)
                while bits.bit == 1
                  cb.lblock += 1
                  raise PacketError if cb.lblock > 32
                end
                segment_lengths(bits, cb, passes, cblk_style, keep, contributions)
              end
            end
          end
          bits.align
          raise PacketError if bits.overrun

          hpos = bits.pos
          hdata = bits.data
          if @eph && hdata.getbyte(hpos) == 0xFF && hdata.getbyte(hpos + 1) == 0x92
            hpos += 2
          end
          if @separate
            bits.restart(hpos)
          else
            @pos = hpos
          end
          read_body(contributions)
        end

        # Number of coding passes (Table B.4).
        def coding_passes(bits)
          return 1 if bits.bit.zero?
          return 2 if bits.bit.zero?

          n = bits.bits(2)
          return 3 + n if n != 3

          n = bits.bits(5)
          return 6 + n if n != 31

          37 + bits.bits(7)
        end

        # Reads the codeword segment lengths of a code-block's new passes
        # (B.10.7), splitting them into segments where the code-block style
        # terminates the arithmetic coder.
        def segment_lengths(bits, cb, passes, style, keep, contributions)
          new_seg = cb.seg_count.zero? || cb.seg_passes == cb.seg_max
          seg = keep ? cb.segments[-1] : nil
          while passes.positive?
            if new_seg
              cb.seg_max = segment_max_passes(cb, style)
              cb.seg_passes = 0
              cb.seg_count += 1
              if keep
                seg = ["".b, 0]
                cb.segments << seg
              end
            end
            n = cb.seg_max - cb.seg_passes
            n = passes if passes < n
            nbits = cb.lblock + (n.bit_length - 1)
            raise PacketError if nbits > 32

            contributions << [seg, n, bits.bits(nbits)]
            cb.seg_passes += n
            passes -= n
            new_seg = true
          end
        end

        # Passes of the next segment (OpenJPEG's opj_t2_init_seg).
        def segment_max_passes(cb, style)
          return 1 if style & 4 != 0 # termination on each pass
          return 109 if style & 1 == 0 # no bypass: one segment
          return 10 if cb.seg_count.zero?

          prev = cb.seg_max
          prev == 1 || prev == 10 ? 2 : 1
        end

        def read_body(contributions)
          data = @data
          truncated = false
          contributions.each do |seg, passes, length|
            avail = @stop - @pos
            if length > avail
              length = avail
              truncated = true
            end
            if seg
              seg[0] << data.byteslice(@pos, length) if length.positive?
              seg[1] += passes
            end
            @pos += length
          end
          raise PacketError if truncated
        end

        def decode_codeblock(cb, band, roi, style)
          segments = cb.segments
          return if segments.empty?

          w = cb.x1 - cb.x0
          h = cb.y1 - cb.y0
          numbps = cb.numbps
          return if numbps + roi > MAX_BITPLANES

          @t1.decode(w, h, segments, numbps, roi, band.orient, style)
          @t1.store(band.rows, cb.x0 - band.x0, cb.y0 - band.y0, w, h, roi, band.step, band.width)
        end
      end
    end
  end
end
