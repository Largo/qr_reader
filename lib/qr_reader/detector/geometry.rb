# frozen_string_literal: true

module QrReader
  class Detector
    # Small geometric helpers shared by the detector parts.
    module Geometry
      module_function

      # Lengths (in 1 px steps) of the first three runs - dark, light, dark -
      # met walking from (x, y) along the unit vector (ux, uy); the first
      # run includes the start point, which must be dark. The last run may
      # end at the image border. nil if the start is light, the walk leaves
      # the image earlier, or the runs exceed +limit+ steps. With +noise+, a
      # single step of the other colour followed by two of the run's colour
      # does not end a run.
      def runs(matrix, x, y, ux, uy, limit, noise: false)
        bits = matrix.bits
        w = matrix.width
        h = matrix.height
        counts = [0, 0, 0]
        state = 0
        colour = 1
        t = 0
        while t <= limit
          px = x + ux * t
          py = y + uy * t
          return state == 2 ? counts : nil unless px >= 0 && py >= 0 && px < w && py < h

          c = bits.getbyte(py.to_i * w + px.to_i)
          if c != colour
            if noise && t.positive? && bit(bits, w, h, x + ux * (t + 1), y + uy * (t + 1)) == colour &&
               bit(bits, w, h, x + ux * (t + 2), y + uy * (t + 2)) == colour
              c = colour
            else
              return if t.zero?

              state += 1
              return counts if state == 3

              colour = c
            end
          end
          counts[state] += 1
          t += 1
        end
        nil
      end

      # Bit at continuous position (x, y); nil outside the image.
      def bit(bits, w, h, x, y)
        bits.getbyte(y.to_i * w + x.to_i) if x >= 0 && y >= 0 && x < w && y < h
      end

      # 1:1:3:1:1 test: each run within 0.5 module (0.75 if relaxed) plus
      # half a pixel of its nominal width, the centre run 0.25 module more;
      # or the dot gain tolerant test (dark and light runs measured against
      # their own module sizes, see QrReaderKernels::FinderScanner#gain_ratio?).
      def finder_ratio?(a, b, c, d, e, relaxed: false)
        total = a + b + c + d + e
        return false if total < 7

        # In units of 1/28 module.
        tol = (relaxed ? 3 * total : 2 * total) + 14
        return true if (28 * a - 4 * total).abs <= tol &&
                       (28 * b - 4 * total).abs <= tol &&
                       (28 * c - 12 * total).abs <= tol + total &&
                       (28 * d - 4 * total).abs <= tol &&
                       (28 * e - 4 * total).abs <= tol

        gain_ratio?(a, b, c, d, e)
      end

      # 1:1:3:1:1 under dot gain or loss (see finder_ratio?).
      def gain_ratio?(a, b, c, d, e)
        dark = a + c + e
        light = b + d
        return false if dark < 10 || light.zero? || dark > 10 * light || 5 * light > 8 * dark

        tol = 2 * dark + 10
        (20 * a - 4 * dark).abs <= tol && (20 * c - 12 * dark).abs <= tol && (20 * e - 4 * dark).abs <= tol &&
          (6 * b - 3 * light).abs <= light + 3 && (6 * d - 3 * light).abs <= light + 3
      end

      # Least-squares line through +points+ as [x, y, vx, vy] (centroid and
      # unit direction); nil if the RMS distance of the points from the
      # line exceeds +max_rms+.
      def fit_line(points, max_rms)
        n = points.size.to_f
        mx = points.sum { |x, _| x } / n
        my = points.sum { |_, y| y } / n
        sxx = sxy = syy = 0.0
        points.each do |x, y|
          dx = x - mx
          dy = y - my
          sxx += dx * dx
          sxy += dx * dy
          syy += dy * dy
        end
        angle = 0.5 * Math.atan2(2 * sxy, sxx - syy)
        vx = Math.cos(angle)
        vy = Math.sin(angle)
        # Residual = spread perpendicular to the direction.
        rms = Math.sqrt(((vy * vy * sxx) - (2 * vx * vy * sxy) + (vx * vx * syy)).abs / n)
        rms > max_rms ? nil : [mx, my, vx, vy]
      end

      # Intersection point [x, y] of two lines given as [x, y, vx, vy];
      # nil if they are (nearly) parallel.
      def intersect_lines(a, b)
        cross = a[2] * b[3] - a[3] * b[2]
        return if cross.abs < 0.05

        t = ((b[0] - a[0]) * b[3] - (b[1] - a[1]) * b[2]) / cross
        [a[0] + a[2] * t, a[1] + a[3] * t]
      end
    end
  end
end
