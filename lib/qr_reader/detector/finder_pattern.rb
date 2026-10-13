# frozen_string_literal: true

module QrReader
  class Detector
    # A located finder pattern (or alignment pattern).
    #
    # x, y        - centre in continuous pixel coordinates (pixel (i, j)
    #               covers [i, i + 1) x [j, j + 1), so its centre is i + 0.5)
    # module_size - estimated module size in pixels (rotation compensated)
    # count       - number of scan rows that hit this pattern
    # quality     - 0..1, how consistent the cross-check spreads were
    class FinderPattern
      attr_reader :x, :y, :module_size, :count
      attr_accessor :quality

      def initialize(x, y, module_size, count = 1, quality = 1.0)
        @x = x
        @y = y
        @module_size = module_size
        @count = count
        @quality = quality
      end

      # Records another scan row crossing this pattern.
      def add_hit
        @count += 1
      end

      def distance(other)
        Math.hypot(@x - other.x, @y - other.y)
      end

      def distance_to(x, y)
        Math.hypot(@x - x, @y - y)
      end

      # True if (x, y) lies within +modules+ module sizes of the centre.
      def near?(x, y, modules)
        r = @module_size * modules
        dx = @x - x
        dy = @y - y
        dx * dx + dy * dy < r * r
      end

      # Count-weighted average with another estimate of the same pattern.
      def merge(other)
        n = @count + other.count
        FinderPattern.new((@x * @count + other.x * other.count) / n,
                          (@y * @count + other.y * other.count) / n,
                          (@module_size * @count + other.module_size * other.count) / n, n,
                          [@quality, other.quality].max)
      end

      def to_a
        [@x, @y]
      end

      def inspect
        format("#<FinderPattern (%.1f, %.1f) ms=%.2f n=%d>", @x, @y, @module_size, @count)
      end
    end
  end
end
