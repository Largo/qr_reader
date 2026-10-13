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
      module_function

      # Samples a dimension x dimension grid. +regions+ lists
      # [x0, x1, y0, y1, transform], each covering modules x0...x1 and
      # y0...y1 (use whole(d, transform) for a single transform). With
      # +offset+ > 0 a module is the majority vote of its centre pixel and
      # the four pixels +offset+ away, which ignores isolated noise.
      def sample(matrix, dimension, regions, offset: 0)
        out = "\0".b * (dimension * dimension)
        bits = matrix.bits
        w = matrix.width
        h = matrix.height
        regions.each do |x0, x1, y0, y1, transform|
          m = transform.m
          my = y0
          while my < y1
            if offset.positive?
              vote_row(bits, w, h, out, my * dimension, m, my + 0.5, x0, x1, offset)
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
              if px >= 0.0 && py >= 0.0 && px < w && py < h && dark_vote?(bits, w, h, px.to_i, py.to_i, offset)
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
      # small modules). +inverted+ reads light-on-dark symbols.
      def sample_luminance(image, dimension, regions, module_size, radius: 4, inverted: false)
        lum = Array.new(dimension * dimension, 0)
        offset = vote_offset(module_size)
        regions.each do |x0, x1, y0, y1, transform|
          m = transform.m
          my = y0
          while my < y1
            luminance_row(image.data, image.width, image.height, lum, my * dimension, m, my + 0.5, x0, x1, offset)
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

      # Like sample_row, voting over five pixels per module.
      def vote_row(bits, w, h, out, off, m, v, x0, x1, offset)
        bx = m[1] * v + m[2]
        by = m[4] * v + m[5]
        bd = m[7] * v + m[8]
        m0 = m[0]
        m3 = m[3]
        m6 = m[6]
        max_x = w - 1
        max_y = h - 1
        mx = x0
        while mx < x1
          u = mx + 0.5
          den = m6 * u + bd
          if den > 1e-9 || den < -1e-9
            px = (m0 * u + bx) / den
            py = (m3 * u + by) / den
            if px >= 0.0 && py >= 0.0 && px < w && py < h
              ix = px.to_i
              iy = py.to_i
              row = iy * w
              l = ix - offset
              l = 0 if l.negative?
              r = ix + offset
              r = max_x if r > max_x
              t = iy - offset
              t = 0 if t.negative?
              b = iy + offset
              b = max_y if b > max_y
              votes = bits.getbyte(row + ix) + bits.getbyte(row + l) + bits.getbyte(row + r) +
                      bits.getbyte(t * w + ix) + bits.getbyte(b * w + ix)
              out.setbyte(off + mx, 1) if votes >= 3
            end
          end
          mx += 1
        end
      end

      # Mean luminance (x 4, as Integer) of modules x0...x1 of one module row.
      def luminance_row(data, w, h, lum, off, m, v, x0, x1, offset)
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
                if offset.zero?
                  bilinear4(data, w, h, px - 0.5, py - 0.5)
                else
                  l = (ix - offset).clamp(0, w - 1)
                  r = (ix + offset).clamp(0, w - 1)
                  t = (iy - offset).clamp(0, h - 1)
                  b = (iy + offset).clamp(0, h - 1)
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

      # Majority of the pixel (ix, iy) and the four pixels +offset+ away (or
      # just the pixel when +offset+ is 0).
      def dark_vote?(bits, w, h, ix, iy, offset)
        row = iy * w
        return bits.getbyte(row + ix) == 1 if offset.zero?

        l = ix - offset
        l = 0 if l.negative?
        r = ix + offset
        r = w - 1 if r >= w
        t = iy - offset
        t = 0 if t.negative?
        b = iy + offset
        b = h - 1 if b >= h
        bits.getbyte(row + ix) + bits.getbyte(row + l) + bits.getbyte(row + r) +
          bits.getbyte(t * w + ix) + bits.getbyte(b * w + ix) >= 3
      end

      # Samples modules x0...x1 of the module row at height v (a module
      # centre) into out[off + x].
      def sample_row(bits, w, h, out, off, m, v, x0, x1)
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
          if den > 1e-9 || den < -1e-9
            px = (m0 * u + bx) / den
            py = (m3 * u + by) / den
            # Compare before flooring: Floats beyond the image (or NaN)
            # never reach Float#floor.
            if px >= 0.0 && py >= 0.0 && px < w && py < h && bits.getbyte(py.to_i * w + px.to_i) == 1
              out.setbyte(off + mx, 1)
            end
          end
          mx += 1
        end
      end
    end
  end
end
