# frozen_string_literal: true

module QrReader
  class Detector
    # Piecewise sampling support for versions 7+ (zxing-cpp's approach):
    # locates every alignment pattern, predicting each one from its already
    # located neighbours, and returns one local transform per cell of the
    # alignment pattern grid. This follows bent, curved or unevenly
    # stretched symbols far better than a single homography.
    class AlignmentGrid
      # +finder_corners+ - callable taking the last grid index n and
      # returning measured positions of the grid points next to the finder
      # patterns ({[x, y] => [px, py]}, possibly incomplete).
      def initialize(detector, transform, dimension, module_size, finder_corners = nil)
        @finder = detector.alignment_finder
        @transform = transform
        @dimension = dimension
        @module_size = module_size
        @finder_corners = finder_corners
      end

      # [[x0, x1, y0, y1, transform], ...] covering the whole symbol, or nil
      # if the version has no alignment grid or a cell is degenerate.
      def regions
        version = SymbolVersion.for_dimension(@dimension) or return
        centres = version.alignment_centers
        n = centres.size - 1
        return if n < 1

        positions = locate_all(centres, n)
        return if positions.any? { |row| row.any?(&:nil?) }

        out = []
        n.times do |y|
          n.times do |x|
            x0 = centres[x]
            x1 = centres[x + 1]
            y0 = centres[y]
            y1 = centres[y + 1]
            t = PerspectiveTransform.quad_to_quad(
              [[x0 + 0.5, y0 + 0.5], [x1 + 0.5, y0 + 0.5], [x1 + 0.5, y1 + 0.5], [x0 + 0.5, y1 + 0.5]],
              [positions[y][x], positions[y][x + 1], positions[y + 1][x + 1], positions[y + 1][x]]
            )
            # Cells on the border also cover the modules out to the edge.
            region = [x.zero? ? 0 : x0, x == n - 1 ? @dimension : x1,
                      y.zero? ? 0 : y0, y == n - 1 ? @dimension : y1]
            return unless t&.regular_over?(region[0], region[2], region[1], region[3])

            out << [*region, t]
          end
        end
        out
      end

      private

      # Pixel positions of all grid points ([y][x]); points next to the
      # finder patterns and points that cannot be found are projected.
      def locate_all(centres, n)
        found = Array.new(n + 1) { Array.new(n + 1) }
        @finder_corners&.call(n)&.each { |(x, y), p| found[y][x] = p }
        project = ->(x, y) { @transform.apply(centres[x] + 0.5, centres[y] + 0.5) }
        best = ->(x, y) { found[y][x] || project.call(x, y) }
        finder_adjacent = ->(x, y) { (x.zero? && y.zero?) || (x.zero? && y == n) || (x == n && y.zero?) }

        (0..n).each do |y|
          (0..n).each do |x|
            next if finder_adjacent.call(x, y) || found[y][x]

            guess =
              if x.zero? || y.zero?
                project.call(x, y)
              else
                a = best.call(x - 1, y)
                b = best.call(x, y - 1)
                c = best.call(x - 1, y - 1)
                a && b && c ? [a[0] + b[0] - c[0], a[1] + b[1] - c[1]] : project.call(x, y)
              end
            found[y][x] = search(guess, centres[x], centres[y]) if guess
          end
        end

        (0..n).map do |y|
          (0..n).map { |x| found[y][x] || interpolate(found, x, y, n) || project.call(x, y) }
        end
      end

      # Intersection of the lines through the nearest two found neighbours
      # in the same row and in the same column, if both exist.
      def interpolate(found, x, y, n)
        row = nearest(n) { |i| found[y][x + i] if (x + i).between?(0, n) }
        col = nearest(n) { |i| found[y + i][x] if (y + i).between?(0, n) }
        return unless row.size == 2 && col.size == 2

        intersect(row[0], row[1], col[0], col[1])
      end

      def nearest(n)
        out = []
        (1..n).each do |d|
          [-d, d].each do |i|
            p = yield(i)
            out << p if p && out.size < 2
          end
        end
        out
      end

      def intersect(p1, p2, p3, p4)
        d = (p1[0] - p2[0]) * (p3[1] - p4[1]) - (p1[1] - p2[1]) * (p3[0] - p4[0])
        return if d.abs < 1e-9

        a = p1[0] * p2[1] - p1[1] * p2[0]
        b = p3[0] * p4[1] - p3[1] * p4[0]
        [(a * (p3[0] - p4[0]) - (p1[0] - p2[0]) * b) / d, (a * (p3[1] - p4[1]) - (p1[1] - p2[1]) * b) / d]
      end

      # Alignment pattern near +guess+ (module vectors from the transform).
      def search(guess, mx, my)
        c = @transform.apply(mx + 0.5, my + 0.5) or return
        u = @transform.apply(mx + 1.5, my + 0.5) or return
        v = @transform.apply(mx + 0.5, my + 1.5) or return
        @finder.find(guess[0], guess[1], 3 * @module_size + 1, u[0] - c[0], u[1] - c[1], v[0] - c[0], v[1] - c[1])
      end
    end
  end
end
