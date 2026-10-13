# frozen_string_literal: true

module QrReader
  class Detector
    # Reads the module grid of a symbol through a PerspectiveTransform
    # that maps module coordinates (module (i, j) covers [i, i + 1) x
    # [j, j + 1)) to continuous pixel coordinates:
    #
    # * sample           - from the binarized image, one or more transforms
    #                      (piecewise), optionally voting over five pixels
    # * sample_warped    - the same plus a separable displacement field
    # * sample_luminance - from the grayscale image, thresholding module
    #                      luminances against their neighbourhood
    #
    # Modules whose centre falls outside the image read as light.
    module GridSampler
      # Scale of the fixed-point arithmetic of sample_row / vote_row.
      FIXED_ONE = (1 << 24).to_f
      # Scaled coordinates beyond this (pixels about 2**30 away) are not
      # sampled, so that the stepping stays within Fixnum range.
      FIXED_LIMIT = 2.0**54

      module_function

      # Samples a dimension x dimension grid. +regions+ lists
      # [x0, x1, y0, y1, transform], each covering modules x0...x1 and
      # y0...y1 (use whole(d, transform) for a single transform). With an
      # +offset+ (pixels; an Integer or [horizontal, vertical], see
      # vote_offsets) a module is the majority vote of its centre pixel and
      # the four pixels that far left, right, above and below it, which
      # ignores isolated noise.
      def sample(matrix, dimension, regions, offset: 0)
        out = "\0".b * (dimension * dimension)
        bits = matrix.bits
        w = matrix.width
        h = matrix.height
        ox, oy = offset_pair(offset)
        regions.each do |x0, x1, y0, y1, transform|
          m = transform.m
          my = y0
          while my < y1
            if ox > 0 || oy > 0
              vote_row(bits, w, h, out, my * dimension, m, my + 0.5, x0, x1, ox, oy)
            else
              sample_row(bits, w, h, out, my * dimension, m, my + 0.5, x0, x1)
            end
            my += 1
          end
        end
        BitMatrix.new(dimension, dimension, out)
      end

      # Samples a grid through +transform+ plus a separable pixel
      # displacement: module (mx, my) is read at
      # transform(mx + 0.5, my + 0.5) + col_shift[mx] + row_shift[my], where
      # the shifts are [dx, dy] pairs (see Candidate#warped_sample).
      def sample_warped(matrix, dimension, transform, col_shift, row_shift, offset: 0)
        out = "\0".b * (dimension * dimension)
        bits = matrix.bits
        w = matrix.width
        h = matrix.height
        ox, oy = offset_pair(offset)
        m = transform.m
        my = 0
        while my < dimension
          v = my + 0.5
          rdx, rdy = row_shift[my]
          base = my * dimension
          mx = 0
          while mx < dimension
            u = mx + 0.5
            den = m[6] * u + m[7] * v + m[8]
            if den > 1e-9 || den < -1e-9
              cdx, cdy = col_shift[mx]
              px = (m[0] * u + m[1] * v + m[2]) / den + cdx + rdx
              py = (m[3] * u + m[4] * v + m[5]) / den + cdy + rdy
              if px >= 0.0 && py >= 0.0 && px < w && py < h && dark_vote?(bits, w, h, px.to_i, py.to_i, ox, oy)
                out.setbyte(base + mx, 1)
              end
            end
            mx += 1
          end
          my += 1
        end
        BitMatrix.new(dimension, dimension, out)
      end

      # Samples the grid from the grayscale +image+ instead of the binarized
      # one: each module's luminance is the mean of its centre pixel and the
      # pixels a quarter module away (bilinear at the centre for modules
      # under 3 px), and a module is dark if it is darker than the mean of
      # the (2r+1) x (2r+1) modules around it. +regions+ as in
      # sample. Keeps information the binarization lost (blur, uneven light,
      # small modules). +inverted+ reads light-on-dark symbols. +offset+
      # overrides the quarter module offsets derived from +module_size+
      # (see vote_offsets).
      def sample_luminance(image, dimension, regions, module_size, radius: 4, inverted: false, offset: nil)
        lum = Array.new(dimension * dimension, 0)
        ox, oy = offset_pair(offset || vote_offset(module_size))
        regions.each do |x0, x1, y0, y1, transform|
          m = transform.m
          my = y0
          while my < y1
            luminance_row(image.data, image.width, image.height, lum, my * dimension, m, my + 0.5, x0, x1, ox, oy)
            my += 1
          end
        end
        grid = threshold_grid(lum, dimension, radius)
        inverted ? grid.invert : grid
      end

      # The region list covering a whole grid with one transform.
      def whole(dimension, transform)
        [[0, dimension, 0, dimension, transform]]
      end

      # Majority sampling offset for a module size: a quarter module, none
      # below 3 px.
      def vote_offset(module_size)
        module_size >= 3 ? (module_size / 4.0).round : 0
      end

      # [horizontal, vertical] majority sampling offsets for the modules
      # of +transform+ at the centre of a dimension x dimension grid: a
      # quarter of the module's horizontal (vertical) chord through its
      # centre, none below 3 px. Unlike vote_offset this keeps the samples
      # inside modules that are not square in the image - fax pages
      # (204 x 98 dpi), strong perspective.
      def vote_offsets(transform, dimension)
        c = dimension * 0.5
        o = transform.apply(c, c) or return [0, 0]
        u = transform.apply(c + 1, c) or return [0, 0]
        v = transform.apply(c, c + 1) or return [0, 0]
        ux = u[0] - o[0]
        uy = u[1] - o[1]
        vx = v[0] - o[0]
        vy = v[1] - o[1]
        area = (ux * vy - uy * vx).abs
        horizontal = area / [uy.abs, vy.abs].max
        vertical = area / [ux.abs, vx.abs].max
        [chord_offset(horizontal), chord_offset(vertical)]
      end

      def chord_offset(chord)
        chord.finite? && chord >= 3 ? (chord / 4.0).round : 0
      end

      # [ox, oy] from an Integer or a pair.
      def offset_pair(offset)
        offset.is_a?(Array) ? offset : [offset, offset]
      end

      # Like sample_row, voting over five pixels per module: the centre and
      # those +ox+ left and right, +oy+ above and below.
      def vote_row(bits, w, h, out, off, m, v, x0, x1, ox, oy)
        nx, ny, nd, sx, sy, sd = fixed_row(m, v, x0, x1)
        return unless nx

        max_x = w - 1
        max_y = h - 1
        mx = x0
        while mx < x1
          if nd != 0
            ix = nx / nd
            iy = ny / nd
            if ix >= 0 && iy >= 0 && ix < w && iy < h
              row = iy * w
              l = ix - ox
              l = 0 if l < 0
              r = ix + ox
              r = max_x if r > max_x
              t = iy - oy
              t = 0 if t < 0
              b = iy + oy
              b = max_y if b > max_y
              votes = bits.getbyte(row + ix) + bits.getbyte(row + l) + bits.getbyte(row + r) +
                      bits.getbyte(t * w + ix) + bits.getbyte(b * w + ix)
              out.setbyte(off + mx, 1) if votes >= 3
            end
          end
          nx += sx
          ny += sy
          nd += sd
          mx += 1
        end
      end

      # Fixed-point stepping along a module row: the transform's numerators
      # and denominator at module (x0 + 0.5, v) and their increments per
      # module, as Integers scaled so that the denominator's magnitude is
      # about FIXED_ONE. Pixel (nx / nd, ny / nd) is then found with integer
      # floor division, which is exact up to rounding of the scaled values
      # and 3x faster than Float arithmetic. nil if the row is degenerate.
      def fixed_row(m, v, x0, x1)
        u = x0 + 0.5
        d0 = m[6] * u + m[7] * v + m[8]
        d1 = d0 + m[6] * (x1 - x0 - 1)
        d0a = d0.abs
        d1a = d1.abs
        mag = d0a > d1a ? d0a : d1a
        return unless mag > 1e-12 && mag < Float::INFINITY

        s = FIXED_ONE / mag
        nx = (m[0] * u + m[1] * v + m[2]) * s
        ny = (m[3] * u + m[4] * v + m[5]) * s
        # Rows far outside the image would need Bignums; they read as light.
        return unless nx.abs < FIXED_LIMIT && ny.abs < FIXED_LIMIT && (m[0] * s).abs < FIXED_LIMIT &&
                      (m[3] * s).abs < FIXED_LIMIT

        [nx.round, ny.round, (d0 * s).round, (m[0] * s).round, (m[3] * s).round, (m[6] * s).round]
      end

      # Mean luminance (x 4, as Integer) of modules x0...x1 of one module
      # row: half the centre pixel, an eighth each of the pixels +ox+ left
      # and right, +oy+ above and below (bilinear at the centre if both are 0).
      def luminance_row(data, w, h, lum, off, m, v, x0, x1, ox, oy)
        bx = m[1] * v + m[2]
        by = m[4] * v + m[5]
        bd = m[7] * v + m[8]
        m0 = m[0]
        m3 = m[3]
        m6 = m[6]
        mx = x0
        while mx < x1
          u = mx + 0.5
          den = m6 * u + bd
          value = 1020
          if den > 1e-9 || den < -1e-9
            px = (m0 * u + bx) / den
            py = (m3 * u + by) / den
            if px >= 0.0 && py >= 0.0 && px < w && py < h
              ix = px.to_i
              iy = py.to_i
              value =
                if ox == 0 && oy == 0
                  bilinear4(data, w, h, px - 0.5, py - 0.5)
                else
                  l = ix - ox
                  l = 0 if l < 0
                  r = ix + ox
                  r = w - 1 if r >= w
                  t = iy - oy
                  t = 0 if t < 0
                  b = iy + oy
                  b = h - 1 if b >= h
                  c = iy * w
                  (4 * data.getbyte(c + ix) + data.getbyte(c + l) + data.getbyte(c + r) +
                   data.getbyte(t * w + ix) + data.getbyte(b * w + ix)) >> 1
                end
            end
          end
          lum[off + mx] = value
          mx += 1
        end
      end

      # Bilinearly interpolated luminance x 4 at continuous pixel position
      # (x, y) measured from pixel centres.
      def bilinear4(data, w, h, x, y)
        x = 0.0 if x.negative?
        y = 0.0 if y.negative?
        ix = x.to_i
        iy = y.to_i
        ix1 = ix + 1 < w ? ix + 1 : ix
        iy1 = iy + 1 < h ? iy + 1 : iy
        fx = x - ix
        fy = y - iy
        top = data.getbyte(iy * w + ix) * (1 - fx) + data.getbyte(iy * w + ix1) * fx
        bottom = data.getbyte(iy1 * w + ix) * (1 - fx) + data.getbyte(iy1 * w + ix1) * fx
        ((top + (bottom - top) * fy) * 4).round
      end

      # BitMatrix of modules darker than their neighbourhood mean (summed
      # area table over the module luminances).
      def threshold_grid(lum, n, radius)
        stride = n + 1
        sat = Array.new(stride * stride, 0)
        y = 0
        while y < n
          row_sum = 0
          x = 0
          while x < n
            row_sum += lum[y * n + x]
            sat[(y + 1) * stride + x + 1] = sat[y * stride + x + 1] + row_sum
            x += 1
          end
          y += 1
        end
        out = "\0".b * (n * n)
        y = 0
        while y < n
          y0 = y - radius
          y0 = 0 if y0.negative?
          y1 = y + radius + 1
          y1 = n if y1 > n
          x = 0
          while x < n
            x0 = x - radius
            x0 = 0 if x0.negative?
            x1 = x + radius + 1
            x1 = n if x1 > n
            sum = sat[y1 * stride + x1] - sat[y0 * stride + x1] - sat[y1 * stride + x0] + sat[y0 * stride + x0]
            out.setbyte(y * n + x, 1) if lum[y * n + x] * (y1 - y0) * (x1 - x0) < sum
            x += 1
          end
          y += 1
        end
        BitMatrix.new(n, n, out)
      end

      # Majority of the pixel (ix, iy) and the pixels +ox+ left and right,
      # +oy+ above and below (just the pixel when both are 0).
      def dark_vote?(bits, w, h, ix, iy, ox, oy)
        row = iy * w
        return bits.getbyte(row + ix) == 1 if ox == 0 && oy == 0

        l = ix - ox
        l = 0 if l < 0
        r = ix + ox
        r = w - 1 if r >= w
        t = iy - oy
        t = 0 if t < 0
        b = iy + oy
        b = h - 1 if b >= h
        bits.getbyte(row + ix) + bits.getbyte(row + l) + bits.getbyte(row + r) +
          bits.getbyte(t * w + ix) + bits.getbyte(b * w + ix) >= 3
      end

      # Samples modules x0...x1 of the module row at height v (a module
      # centre) into out[off + x].
      def sample_row(bits, w, h, out, off, m, v, x0, x1)
        nx, ny, nd, sx, sy, sd = fixed_row(m, v, x0, x1)
        return unless nx

        mx = x0
        while mx < x1
          if nd != 0
            ix = nx / nd
            iy = ny / nd
            out.setbyte(off + mx, 1) if ix >= 0 && iy >= 0 && ix < w && iy < h && bits.getbyte(iy * w + ix) == 1
          end
          nx += sx
          ny += sy
          nd += sd
          mx += 1
        end
      end
    end
  end
end
