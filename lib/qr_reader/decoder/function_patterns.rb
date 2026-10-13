# frozen_string_literal: true

module QrReader
  module Decoder
    # Which modules of a symbol are function modules (finder patterns with
    # separators, format and version information, timing patterns, alignment
    # patterns, dark module) and therefore carry no data. Same regions as
    # ZXing's Version#buildFunctionPattern.
    module FunctionPatterns
      @cache = Array.new(41)

      class << self
        # Binary String of dimension**2 bytes, row-major, "\x01" for function
        # modules. Cached per version (1..40).
        def for_version(number)
          @cache[number] ||= build(SymbolVersion[number])
        end

        private

        # (Plain loops: this runs once per version, and YJIT would spend more
        # time compiling blocks here than running them.)
        def build(version)
          n = version.dimension
          grid = "\0".b * (n * n)
          fill(grid, n, 0, 0, 9, 9)          # top-left finder + separator + format info
          fill(grid, n, n - 8, 0, 8, 9)      # top-right finder + separator + format info
          fill(grid, n, 0, n - 8, 9, 8)      # bottom-left finder + separator + format info + dark module
          centers = version.alignment_centers
          last = centers.size - 1
          iy = 0
          while iy <= last
            ix = 0
            while ix <= last
              # the three corners occupied by finder patterns carry none
              finder = (ix.zero? && (iy.zero? || iy == last)) || (ix == last && iy.zero?)
              fill(grid, n, centers[ix] - 2, centers[iy] - 2, 5, 5) unless finder
              ix += 1
            end
            iy += 1
          end
          fill(grid, n, 6, 9, 1, n - 17)     # vertical timing pattern
          fill(grid, n, 9, 6, n - 17, 1)     # horizontal timing pattern
          if version.number >= 7
            fill(grid, n, n - 11, 0, 3, 6)   # version info, top right
            fill(grid, n, 0, n - 11, 6, 3)   # version info, bottom left
          end
          grid.freeze
        end

        def fill(grid, n, left, top, width, height)
          row = "\x01".b * width
          y = top
          while y < top + height
            grid[y * n + left, width] = row
            y += 1
          end
        end
      end
    end
  end
end
