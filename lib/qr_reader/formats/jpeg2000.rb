# frozen_string_literal: true

require_relative "../errors"
require_relative "../image"
require_relative "jpeg2000/codestream"
require_relative "jpeg2000/container"
require_relative "jpeg2000/tier1"
require_relative "jpeg2000/dwt"
require_relative "jpeg2000/tile"

module QrReader
  module Formats
    # Pure-Ruby JPEG 2000 (ITU-T T.800 | ISO/IEC 15444-1, "Part 1") decoder
    # for JP2 files and raw codestreams, e.g. the JPXDecode images of PDFs.
    #
    #   JPEG2000.decode(bytes)               # => QrReader::Image (luminance)
    #   JPEG2000.decode(bytes, reduce: 2)    # => 1/4 of the size, cheaply
    #   JPEG2000.dimensions(bytes)           # => [width, height]
    #   JPEG2000.decode_components(bytes)    # => JPEG2000::Components
    #
    # Supported: everything in Part 1 - any number of components with 1 to
    # 30 bits (signed or not) and sub-sampling, tiles (any order, several
    # tile-parts, missing tiles), all progression orders with precincts and
    # POC changes, quality layers, PPM/PPT packed headers, SOP/EPH markers,
    # all code-block styles (bypass, reset, termall, vertically causal,
    # predictable termination, segmentation symbols), ROI max-shift, 5/3
    # and 9/7 wavelets with RCT/ICT, and the JP2 boxes colr (enumerated and
    # ICC), pclr/cmap palettes and cdef channel definitions. Part 2
    # extensions and HTJ2K raise UnsupportedImageError; truncated data
    # decodes what is present (missing tiles stay mid-gray); other
    # corruption raises ImageError.
    #
    # Samples are converted to 8 bits: level shift (unsigned) or offset
    # 2**(p-1) (signed), clamping, then v * 255 / (2**p - 1) rounded for
    # precisions other than 8. Luminance: gray and sYCC take the first
    # channel, RGB Image.luma, CMYK the PDF formula; without colour
    # information 1 or 2 channels are gray (+ alpha), 3 RGB and 4 CMYK.
    # Alpha channels (cdef) are ignored.
    #
    # +reduce: n+ discards the n highest resolution levels (like OpenJPEG's
    # reduce factor): the result is ceil(w / 2**n) x ceil(h / 2**n) for an
    # image at the grid origin, and the discarded code-blocks are not
    # decoded at all. It is limited to the decomposition levels present.
    #
    # Memory: tiles are decoded one by one and components one by one; the
    # wavelet planes of the tile-component being decoded take about 8 bytes
    # per sample (Ruby Arrays), the components 0 and 1 of an RGB tile wait
    # for the inverse colour transform packed at 4 bytes per sample, and the
    # output takes 1 byte per pixel and channel. A tile-component larger
    # than MAX_DECODE_SAMPLES at the decoded resolution raises
    # UnsupportedImageError: decode it with a +reduce+ factor.
    module JPEG2000
      # The decoded channels of an image (see JPEG2000.decode_components):
      # +components+ are binary Strings of width * height 8-bit samples
      # (after palette, inverse MCT and up-sampling, in codestream /
      # palette order), +color+ is :gray, :rgb, :ycc (sYCC), :cmyk or nil
      # (unknown), +palette_applied+ whether a JP2 palette mapped the
      # components, +alpha+ the indices of opacity channels (cdef).
      Components = Data.define(:width, :height, :components, :color, :palette_applied, :alpha)

      # Exceptions that only a bug triggered by corrupt input could raise;
      # they are reported as ImageError.
      INTERNAL_ERRORS = [NoMethodError, TypeError, ArgumentError, RangeError, IndexError, ZeroDivisionError,
                         EncodingError, FrozenError, FloatDomainError, KeyError, StopIteration].freeze

      # Enumerated colour spaces (I.5.3.3 and Part 2) we can interpret.
      ENUM_COLORS = {
        16 => :rgb, 20 => :rgb, 21 => :rgb, 17 => :gray, 12 => :cmyk,
        18 => :ycc, 24 => :ycc, 1 => :ycc, 3 => :ycc, 4 => :ycc, 22 => :ycc, 23 => :ycc
      }.freeze
      ICC_COLORS = { "GRAY" => :gray, "RGB " => :rgb, "CMYK" => :cmyk, "YCbr" => :ycc }.freeze

      # Largest tile-component (samples at the decoded resolution) decoded
      # at once; larger ones need +reduce:+.
      MAX_DECODE_SAMPLES = TileDecoder::MAX_DECODE_SAMPLES

      class << self
        # Decodes a JP2 file or codestream to a luminance Image.
        def decode(bytes, reduce: 0)
          reduce = check_reduce(reduce)
          bytes = binary(bytes)
          width, height, data = guard { Decoder.new(bytes).luminance(reduce) }
          Image.new(width, height, data)
        end

        # Decodes all channels (see Components); +palette: false+ leaves JP2
        # palette indices unmapped.
        def decode_components(bytes, reduce: 0, palette: true)
          reduce = check_reduce(reduce)
          bytes = binary(bytes)
          guard { Decoder.new(bytes).components(reduce, palette: palette) }
        end

        # [width, height] of the image from the SIZ marker only.
        def dimensions(bytes)
          bytes = binary(bytes)
          guard do
            header = Container.parse(bytes)
            Codestream.image_size(header.codestream)
          end
        end

        # The smallest +reduce+ at which #decode accepts the image: 0 unless
        # a tile is larger than MAX_DECODE_SAMPLES (big single-tile pages).
        def fitting_reduce(bytes)
          bytes = binary(bytes)
          guard do
            codestream = Container.parse(bytes).codestream
            width, height = Codestream.image_size(codestream)
            tile_w, tile_h = codestream.byteslice(24, 8).unpack("N2")
            tile_w = width if tile_w.nil? || tile_w > width
            tile_h = height if tile_h.nil? || tile_h > height
            n = 0
            n += 1 while n < 32 && ((tile_w + (1 << n) - 1) >> n) * ((tile_h + (1 << n) - 1) >> n) > MAX_DECODE_SAMPLES
            n
          end
        end

        # The luminance bytes of decoded Components (internal).
        def luminance(comps)
          chans = comps.components
          colour = colour_channels(comps)
          kind = comps.color
          kind ||= case colour.size
                   when 3 then :rgb
                   when 4.. then :cmyk
                   else :gray
                   end
          kind = :gray if (kind == :rgb && colour.size < 3) || (kind == :cmyk && colour.size < 4)
          case kind
          when :rgb then rgb_luma(chans[colour[0]], chans[colour[1]], chans[colour[2]])
          when :cmyk then cmyk_luma(chans[colour[0]], chans[colour[1]], chans[colour[2]], chans[colour[3]])
          else chans[colour[0] || 0]
          end
        end

        private

        def guard
          yield
        rescue *INTERNAL_ERRORS, PacketError, SystemStackError => e
          raise ImageError, "corrupt JPEG 2000 data (internal #{e.class}: #{e.message})"
        end

        def check_reduce(reduce)
          unless reduce.is_a?(Integer) && reduce >= 0
            raise ArgumentError, "reduce must be a non-negative Integer, not #{reduce.inspect}"
          end

          reduce
        end

        def binary(bytes)
          raise ImageError, "JPEG 2000 data must be a String" unless bytes.is_a?(String)

          bytes.encoding == Encoding::BINARY ? bytes : bytes.b
        end

        # Indices of the colour channels (alpha removed, cdef order).
        def colour_channels(comps)
          n = comps.components.size
          alpha = comps.alpha
          list = (0...n).reject { |i| alpha.include?(i) }
          list.empty? ? [0] : list
        end

        def rgb_luma(r, g, b)
          out = Image.buffer(r.bytesize)
          n = r.bytesize
          pos = 0
          while pos < n
            len = n - pos
            len = 4096 if len > 4096
            rgb_luma_run(r, g, b, pos, len, out)
            pos += len
          end
          out
        end

        def rgb_luma_run(r, g, b, i, n, out)
          stop = i + n
          while i < stop
            out << ((306 * r.getbyte(i) + 601 * g.getbyte(i) + 117 * b.getbyte(i) + 0x200) >> 10)
            i += 1
          end
        end

        def cmyk_luma(c, m, y, k)
          n = c.bytesize
          out = Image.buffer(n)
          i = 0
          while i < n
            kk = 255 - k.getbyte(i)
            out << Image.luma(((255 - c.getbyte(i)) * kk + 127) / 255, ((255 - m.getbyte(i)) * kk + 127) / 255,
                              ((255 - y.getbyte(i)) * kk + 127) / 255)
            i += 1
          end
          out
        end
      end

      # Turns a JP2 file or codestream into Components (or luminance).
      class Decoder
        # Adding and subtracting 1.5 * 2**52 rounds a Float half to even
        # (like lrintf in OpenJPEG).
        ROUND_EVEN = 6_755_399_441_055_744.0
        # Most tile-components (tiles x components) decoded.
        MAX_TILE_COMPONENTS = 1 << 20

        Plane = Struct.new(:x0, :y0, :width, :height, :data, :raw)

        def initialize(bytes)
          @header = Container.parse(bytes)
          @cs = Codestream.new(@header.codestream)
        end

        # All channels as Components. +palette+ false leaves the components
        # a JP2 palette indexes as their index values (as PDFs with their
        # own /ColorSpace use them).
        def components(reduce, palette: true)
          @use_palette = palette
          setup(reduce)
          palette_index = palette_components
          @planes = @cs.components.each_with_index.map do |comp, c|
            x0, y0, w, h = plane_rect(comp)
            check_size(w, h)
            raw = palette_index.include?(c)
            Plane.new(x0, y0, w, h, raw ? Array.new(w * h, 0) : ("\x80".b * (w * h)), raw)
          end
          each_tile { |td| decode_tile(td) }
          finish
        end

        # [width, height, luminance bytes]. RGB images of 8-bit samples go
        # straight from the wavelet rows to luminance (components 3 and up,
        # e.g. alpha, are not even decoded); everything else via
        # #components.
        def luminance(reduce)
          setup(reduce)
          return fused_luminance if fused_rgb?

          comps = components(reduce)
          [comps.width, comps.height, JPEG2000.luminance(comps)]
        end

        private

        def setup(reduce)
          cs = @cs
          @reduce = [reduce, max_reduce].min
          @width = ceil_shift(cs.x1, @reduce) - ceil_shift(cs.x0, @reduce)
          @height = ceil_shift(cs.y1, @reduce) - ceil_shift(cs.y0, @reduce)
          check_size(@width, @height)
          # Bounds for headers declaring thousands of components: the
          # planes and the per-tile structures.
          samples = cs.components.sum { |comp| plane_rect(comp).then { |_, _, w, h| w * h } }
          if samples > 4 * Formats::MAX_PIXELS || cs.components.size * [cs.tiles.size, 1].max > MAX_TILE_COMPONENTS
            raise UnsupportedImageError, "JPEG 2000 image with too many components (#{cs.components.size})"
          end
        end

        def each_tile
          tier1 = Tier1.new
          @cs.tile_count.times do |t|
            info = @cs.tiles[t] or next
            td = TileDecoder.new(@cs, info, @reduce, tier1)
            td.read_packets
            yield td
          end
        end

        def ceil_shift(a, k)
          -((-a) >> k)
        end

        def ceil_div(a, b)
          -(-a / b)
        end

        def check_size(w, h)
          raise ImageError, "empty JPEG 2000 image" unless w.positive? && h.positive?
          return if w * h <= Formats::MAX_PIXELS

          raise UnsupportedImageError, "JPEG 2000 image too large (#{w}x#{h}, limit #{Formats::MAX_PIXELS} pixels)"
        end

        # The reduce factor is limited by the main header's levels.
        def max_reduce
          main = @cs.main
          (0...@cs.components.size).map { |c| (main.coc[c] || main.style)&.levels || 0 }.min
        end

        def plane_rect(comp)
          r = @reduce
          x0 = ceil_shift(ceil_div(@cs.x0, comp.dx), r)
          y0 = ceil_shift(ceil_div(@cs.y0, comp.dy), r)
          x1 = ceil_shift(ceil_div(@cs.x1, comp.dx), r)
          y1 = ceil_shift(ceil_div(@cs.y1, comp.dy), r)
          [x0, y0, x1 - x0, y1 - y0]
        end

        # Components that are palette indices (kept unscaled).
        def palette_components
          return [] unless @header.palette

          cmap = @header.cmap
          return [0] unless cmap

          cmap.select { |_, type, _| type == 1 }.map(&:first).uniq
        end

        def plain8?(comp)
          comp.precision == 8 && !comp.signed
        end

        # Whether the luminance is Image.luma of components 0..2.
        def fused_rgb?
          comps = @cs.components
          return false if @header.palette || comps.size < 3
          return false unless comps[0, 3].all? { |c| plain8?(c) && c.dx == 1 && c.dy == 1 }

          alpha = alpha_channels(comps.size)
          channels = (0...comps.size).reject { |i| alpha.include?(i) }
          kind = colour || (channels.size == 3 ? :rgb : nil)
          kind == :rgb && channels.first(3) == [0, 1, 2]
        end

        # The rows of components 0..2 of a tile, their common rectangle and
        # transform (:rct, :ict or nil). With +pack+, the rows of components
        # 0 and 1 are kept as packed Strings (4 bytes per sample instead of
        # 8 while the next component is decoded; see #row_values).
        def rgb_rows(td, pack: true)
          comps = td.components
          rects = (0..2).map { |i| comps[i].output_rect }
          raise ImageError, "JPEG 2000 MCT on components of different sizes" unless rects.uniq.size == 1

          transform = (comps[0].reversible? ? :rct : :ict) if td.mct == 1
          rows = (0..2).map do |i|
            r = td.component_rows(i)
            if r.nil? && !pack
              x0, y0, x1, y1 = rects[0]
              zero = comps[i].reversible? ? 0 : 0.0
              r = Array.new(y1 - y0) { Array.new(x1 - x0, zero) }
            elsif r && pack && i < 2
              format = comps[i].reversible? ? "l*" : "e*"
              r.map! { |row| row.pack(format).tap { row.clear } }
            end
            r
          end
          [rows, rects[0], transform, comps[0, 3].map { |tc| tc.reversible? ? "l*" : "e*" }]
        end

        # A row of #rgb_rows as an Array (+zero+ Arrays of +width+ for
        # all-zero components).
        def row_values(rows, j, format, width, zero)
          return Array.new(width, zero) unless rows

          row = rows[j]
          row.is_a?(String) ? row.unpack(format) : row
        end

        def fused_luminance
          luma = "\x80".b * (@width * @height)
          gx0 = ceil_shift(@cs.x0, @reduce)
          gy0 = ceil_shift(@cs.y0, @reduce)
          each_tile do |td|
            (r0, r1, r2), (x0, y0, x1, y1), transform, (f0, f1, f2) = rgb_rows(td)
            w = x1 - x0
            next if w <= 0

            j = 0
            while j < y1 - y0
              a = row_values(r0, j, f0, w, f0 == "l*" ? 0 : 0.0)
              b = row_values(r1, j, f1, w, f1 == "l*" ? 0 : 0.0)
              c = row_values(r2, j, f2, w, f2 == "l*" ? 0 : 0.0)
              bytes = case transform
                      when :ict then luma_ict_row(a, b, c, w)
                      when :rct then luma_rct_row(a, b, c, w)
                      else luma_plain_row(a, b, c, w)
                      end
              luma.bytesplice((y0 + j - gy0) * @width + (x0 - gx0), w, bytes)
              c.clear # frees the row now rather than at the next major GC
              r0[j] = nil if r0
              r1[j] = nil if r1
              r2[j] = nil if r2
              j += 1
            end
          end
          [@width, @height, luma]
        end

        def luma_ict_row(a, b, c, w)
          m = ROUND_EVEN
          k = 128.0 + m
          out = Array.new(w)
          x = 0
          while x < w
            y = a[x]
            u = b[x]
            v = c[x]
            r = (y + 1.402 * v + k) - m
            r = 0.0 if r < 0.0
            r = 255.0 if r > 255.0
            g = (y - 0.34413 * u - 0.71414 * v + k) - m
            g = 0.0 if g < 0.0
            g = 255.0 if g > 255.0
            bl = (y + 1.772 * u + k) - m
            bl = 0.0 if bl < 0.0
            bl = 255.0 if bl > 255.0
            out[x] = (306.0 * r + 601.0 * g + 117.0 * bl + 512.0) * 0.0009765625
            x += 1
          end
          out.pack("C*")
        end

        def luma_rct_row(a, b, c, w)
          out = Array.new(w)
          x = 0
          while x < w
            u = b[x]
            v = c[x]
            g = a[x] - ((u + v) >> 2) + 128
            r = v + g
            bl = u + g
            r = 0 if r.negative?
            r = 255 if r > 255
            g = 0 if g.negative?
            g = 255 if g > 255
            bl = 0 if bl.negative?
            bl = 255 if bl > 255
            out[x] = (306 * r + 601 * g + 117 * bl + 512) >> 10
            x += 1
          end
          out.pack("C*")
        end

        def luma_plain_row(a, b, c, w)
          r = sample_row(a, w, 128, 255)
          g = sample_row(b, w, 128, 255)
          bl = sample_row(c, w, 128, 255)
          out = Array.new(w)
          x = 0
          while x < w
            out[x] = (306 * r[x] + 601 * g[x] + 117 * bl[x] + 512) >> 10
            x += 1
          end
          out.pack("C*")
        end

        # Integer samples round(v + add) clamped to 0..maxv.
        def sample_row(row, w, add, maxv)
          out = Array.new(w)
          x = 0
          if row[0].is_a?(Float)
            m = ROUND_EVEN
            k = add + m
            fmax = maxv.to_f
            while x < w
              v = (row[x] + k) - m
              v = 0.0 if v < 0.0
              v = fmax if v > fmax
              out[x] = v.to_i
              x += 1
            end
          else
            while x < w
              v = row[x] + add
              v = 0 if v.negative?
              v = maxv if v > maxv
              out[x] = v
              x += 1
            end
          end
          out
        end

        def decode_tile(td)
          comps = td.components
          ncomp = comps.size
          c = 0
          if td.mct == 1 && ncomp >= 3
            if (0..2).all? { |i| plain8?(@cs.components[i]) && !@planes[i].raw }
              rows, rect, transform, formats = rgb_rows(td)
              store_mct(rows, rect, transform, formats)
            else
              rows, rect, transform, = rgb_rows(td, pack: false)
              transform == :rct ? inverse_rct(*rows, rect) : inverse_ict(*rows, rect)
              3.times { |i| store(comps[i], rows[i]) }
            end
            c = 3
          end
          while c < ncomp
            store(comps[c], td.component_rows(c))
            c += 1
          end
        end

        # Inverse MCT of 8-bit components straight into their planes.
        def store_mct(rows, rect, transform, formats)
          x0, y0, x1, y1 = rect
          w = x1 - x0
          return if w <= 0

          planes = @planes[0, 3]
          r0, r1, r2 = rows
          j = 0
          while j < y1 - y0
            zeros = formats.map { |f| f == "l*" ? 0 : 0.0 }
            a = row_values(r0, j, formats[0], w, zeros[0])
            b = row_values(r1, j, formats[1], w, zeros[1])
            c = row_values(r2, j, formats[2], w, zeros[2])
            outs = transform == :rct ? rct_bytes(a, b, c, w) : ict_bytes(a, b, c, w)
            3.times do |i|
              plane = planes[i]
              plane.data.bytesplice((y0 + j - plane.y0) * plane.width + (x0 - plane.x0), w, outs[i])
            end
            c.clear
            r0[j] = nil if r0
            r1[j] = nil if r1
            r2[j] = nil if r2
            j += 1
          end
        end

        def ict_bytes(a, b, c, w)
          m = ROUND_EVEN
          k = 128.0 + m
          ro = Array.new(w)
          go = Array.new(w)
          bo = Array.new(w)
          x = 0
          while x < w
            y = a[x]
            u = b[x]
            v = c[x]
            r = (y + 1.402 * v + k) - m
            r = 0.0 if r < 0.0
            r = 255.0 if r > 255.0
            ro[x] = r
            g = (y - 0.34413 * u - 0.71414 * v + k) - m
            g = 0.0 if g < 0.0
            g = 255.0 if g > 255.0
            go[x] = g
            bl = (y + 1.772 * u + k) - m
            bl = 0.0 if bl < 0.0
            bl = 255.0 if bl > 255.0
            bo[x] = bl
            x += 1
          end
          [ro.pack("C*"), go.pack("C*"), bo.pack("C*")]
        end

        def rct_bytes(a, b, c, w)
          ro = Array.new(w)
          go = Array.new(w)
          bo = Array.new(w)
          x = 0
          while x < w
            u = b[x]
            v = c[x]
            g = a[x] - ((u + v) >> 2) + 128
            r = v + g
            bl = u + g
            r = 0 if r.negative?
            r = 255 if r > 255
            g = 0 if g.negative?
            g = 255 if g > 255
            bl = 0 if bl.negative?
            bl = 255 if bl > 255
            ro[x] = r
            go[x] = g
            bo[x] = bl
            x += 1
          end
          [ro.pack("C*"), go.pack("C*"), bo.pack("C*")]
        end

        def inverse_rct(r0, r1, r2, rect)
          w = rect[2] - rect[0]
          r0.each_index { |j| rct_row(r0[j], r1[j], r2[j], w) }
        end

        def rct_row(a, b, c, w)
          x = 0
          while x < w
            y = a[x]
            u = b[x]
            v = c[x]
            g = y - ((u + v) >> 2)
            a[x] = v + g
            b[x] = g
            c[x] = u + g
            x += 1
          end
        end

        def inverse_ict(r0, r1, r2, rect)
          w = rect[2] - rect[0]
          r0.each_index { |j| ict_row(r0[j], r1[j], r2[j], w) }
        end

        def ict_row(a, b, c, w)
          x = 0
          while x < w
            y = a[x]
            u = b[x]
            v = c[x]
            a[x] = y + 1.402 * v
            b[x] = y - 0.34413 * u - 0.71414 * v
            c[x] = y + 1.772 * u
            x += 1
          end
        end

        # Writes a tile-component's rows into its plane: level shift (or
        # signed offset) to 0..2**p-1, clamp, scale to 8 bits; palette
        # indices stay unscaled.
        def store(tc, rows)
          comp = @cs.components[tc.index]
          plane = @planes[tc.index]
          x0, y0, x1, y1 = tc.output_rect
          w = x1 - x0
          return if w <= 0

          prec = comp.precision
          maxv = (1 << prec) - 1
          add = 1 << (prec - 1)
          return store_constant(plane, x0, y0, w, y1 - y0, add, maxv, prec) unless rows

          j = 0
          while j < y1 - y0
            samples = sample_row(rows[j], w, add, maxv)
            rows[j].clear
            rows[j] = nil
            pos = (y0 + j - plane.y0) * plane.width + (x0 - plane.x0)
            if plane.raw
              plane.data[pos, w] = samples
            else
              scale_row(samples, w, maxv) unless prec == 8
              plane.data.bytesplice(pos, w, samples.pack("C*"))
            end
            j += 1
          end
        end

        # Fills a tile-component whose samples are all 0 (+add+ after the
        # level shift).
        def store_constant(plane, x0, y0, w, h, add, maxv, prec)
          value = add > maxv ? maxv : add
          if plane.raw
            h.times { |j| plane.data[(y0 + j - plane.y0) * plane.width + (x0 - plane.x0), w] = Array.new(w, value) }
            return
          end

          value = (value * 255 + (maxv >> 1)) / maxv unless prec == 8
          bytes = value.chr * w
          h.times { |j| plane.data.bytesplice((y0 + j - plane.y0) * plane.width + (x0 - plane.x0), w, bytes) }
        end

        # v * 255 / maxv, rounded.
        def scale_row(samples, w, maxv)
          half = maxv >> 1
          x = 0
          while x < w
            samples[x] = (samples[x] * 255 + half) / maxv
            x += 1
          end
        end

        # Palette, up-sampling and colour information -> Components.
        def finish
          channels, sources, palette_applied = map_palette
          strings = channels.each_with_index.map { |data, i| upsample(data, @cs.components[sources[i]]) }
          Components.new(width: @width, height: @height, components: strings, color: colour,
                         palette_applied: palette_applied, alpha: alpha_channels(strings.size))
        end

        # [channel planes, source component of each, palette applied?].
        def map_palette
          palette = @header.palette
          unless palette && @use_palette != false
            data = @planes.map { |plane| plane.raw ? plane.data.map { |v| v.clamp(0, 255) }.pack("C*") : plane.data }
            return [data, (0...@planes.size).to_a, false]
          end

          cmap = @header.cmap || Array.new(palette.depths.size) { |i| [0, 1, i] }
          channels = []
          sources = []
          cmap.each do |cmp, type, col|
            plane = @planes[cmp] or raise ImageError, "JPEG 2000 cmap names a missing component"
            sources << cmp
            if type == 1
              raise ImageError, "JPEG 2000 cmap names a missing palette column" if col >= palette.depths.size

              channels << palette_channel(plane, palette, col)
            else
              raise ImageError, "JPEG 2000 cmap maps a palette index directly" if plane.raw

              channels << plane.data
            end
          end
          [channels, sources, true]
        end

        def palette_channel(plane, palette, col)
          depth = palette.depths[col]
          maxv = (1 << depth) - 1
          signed = palette.signed[col]
          lut = palette.entries.map do |entry|
            v = entry[col]
            v -= 1 << depth if signed && v >= 1 << (depth - 1)
            v += 1 << (depth - 1) if signed
            depth == 8 ? v : (v * 255 + (maxv >> 1)) / maxv
          end
          last = lut.size - 1
          table = lut.pack("C*")
          data = plane.data
          out = Image.buffer(data.size)
          i = 0
          n = data.size
          while i < n
            v = data[i]
            v = last if v > last
            out << table.getbyte(v)
            i += 1
          end
          out
        end

        # The channel scaled to the image grid (pixel replication).
        def upsample(data, comp)
          return data if comp.dx == 1 && comp.dy == 1

          x0, y0, cw, ch = plane_rect(comp)
          gx0 = ceil_shift(@cs.x0, @reduce)
          gy0 = ceil_shift(@cs.y0, @reduce)
          xs = Array.new(@width) { |x| ((gx0 + x) / comp.dx - x0).clamp(0, cw - 1) }
          out = Image.buffer(@width * @height)
          @height.times do |y|
            cy = ((gy0 + y) / comp.dy - y0).clamp(0, ch - 1)
            out << data.byteslice(cy * cw, cw).unpack("C*").values_at(*xs).pack("C*")
          end
          out
        end

        def colour
          h = @header
          return ENUM_COLORS[h.enum_cs] if h.enum_cs
          return ICC_COLORS[h.icc_space] if h.icc_space

          nil
        end

        def alpha_channels(count)
          cdef = @header.cdef
          return [] unless cdef

          cdef.select { |d| (d.type == 1 || d.type == 2) && d.channel < count }.map(&:channel)
        end
      end
      private_constant :Decoder
    end
  end
end
