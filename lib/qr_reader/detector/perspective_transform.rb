# frozen_string_literal: true

module QrReader
  class Detector
    # A planar projective transform (homography):
    #
    #   x' = (m0 x + m1 y + m2) / (m6 x + m7 y + m8)
    #   y' = (m3 x + m4 y + m5) / (m6 x + m7 y + m8)
    #
    # Built from four point correspondences, like ZXing's PerspectiveTransform.
    class PerspectiveTransform
      attr_reader :m

      # +m+ - the 9 coefficients, row-major.
      def initialize(m)
        @m = m.freeze
        freeze
      end

      class << self
        # Maps quad (x0,y0)..(x3,y3) onto quad (u0,v0)..(u3,v3); points
        # correspond in order. Returns nil for degenerate quads.
        def quad_to_quad(src, dst)
          to_square = square_to_quad(src)&.adjoint
          from_square = square_to_quad(dst)
          return unless to_square && from_square

          t = from_square * to_square
          t.finite? ? t : nil
        end

        # Maps the unit square (0,0), (1,0), (1,1), (0,1) onto the quad
        # [[x0, y0], [x1, y1], [x2, y2], [x3, y3]]. nil if degenerate.
        def square_to_quad(quad)
          (x0, y0), (x1, y1), (x2, y2), (x3, y3) = quad
          # Three corners on a line make the quad degenerate.
          return if collinear?(x3, y3, x0, y0, x1, y1) || collinear?(x0, y0, x1, y1, x2, y2) ||
                    collinear?(x1, y1, x2, y2, x3, y3) || collinear?(x2, y2, x3, y3, x0, y0)

          dx3 = x0 - x1 + x2 - x3
          dy3 = y0 - y1 + y2 - y3
          if dx3.abs < 1e-9 && dy3.abs < 1e-9
            new([x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0.0, 0.0, 1.0])
          else
            dx1 = x1 - x2
            dx2 = x3 - x2
            dy1 = y1 - y2
            dy2 = y3 - y2
            den = (dx1 * dy2 - dx2 * dy1).to_f
            return if den.abs < 1e-12

            g = (dx3 * dy2 - dx2 * dy3) / den
            h = (dx1 * dy3 - dx3 * dy1) / den
            new([x1 - x0 + g * x1, x3 - x0 + h * x3, x0.to_f,
                 y1 - y0 + g * y1, y3 - y0 + h * y3, y0.to_f,
                 g, h, 1.0])
          end
        end
      end

      # True if (bx, by) lies on the line through (ax, ay) and (cx, cy).
      def self.collinear?(ax, ay, bx, by, cx, cy)
        ((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)).abs < 1e-9
      end
      private_class_method :collinear?

      # Transformed point as [x', y'] (nil if the point maps to infinity).
      def apply(x, y)
        m = @m
        den = m[6] * x + m[7] * y + m[8]
        return if den.abs < 1e-12

        [(m[0] * x + m[1] * y + m[2]) / den, (m[3] * x + m[4] * y + m[5]) / den]
      end

      # Matrix product (self after other).
      def *(other)
        a = @m
        b = other.m
        PerspectiveTransform.new([
          a[0] * b[0] + a[1] * b[3] + a[2] * b[6],
          a[0] * b[1] + a[1] * b[4] + a[2] * b[7],
          a[0] * b[2] + a[1] * b[5] + a[2] * b[8],
          a[3] * b[0] + a[4] * b[3] + a[5] * b[6],
          a[3] * b[1] + a[4] * b[4] + a[5] * b[7],
          a[3] * b[2] + a[4] * b[5] + a[5] * b[8],
          a[6] * b[0] + a[7] * b[3] + a[8] * b[6],
          a[6] * b[1] + a[7] * b[4] + a[8] * b[7],
          a[6] * b[2] + a[7] * b[5] + a[8] * b[8]
        ])
      end

      # Adjugate matrix: the inverse up to a scale factor, which is all a
      # homography needs.
      def adjoint
        a0, a1, a2, a3, a4, a5, a6, a7, a8 = @m
        PerspectiveTransform.new([
          a4 * a8 - a5 * a7, a2 * a7 - a1 * a8, a1 * a5 - a2 * a4,
          a5 * a6 - a3 * a8, a0 * a8 - a2 * a6, a2 * a3 - a0 * a5,
          a3 * a7 - a4 * a6, a1 * a6 - a0 * a7, a0 * a4 - a1 * a3
        ])
      end

      def finite?
        @m.all? { |v| v.finite? }
      end

      # True if the denominator keeps one sign (no point maps through
      # infinity) over the quad with corners (x0, y0) and (x1, y1).
      def regular_over?(x0, y0, x1, y1)
        m = @m
        dens = [[x0, y0], [x1, y0], [x1, y1], [x0, y1]].map { |x, y| m[6] * x + m[7] * y + m[8] }
        dens.all? { |d| d > 1e-9 } || dens.all? { |d| d < -1e-9 }
      end
    end
  end
end
