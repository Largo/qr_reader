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

        def build(version)
          n = version.dimension
          grid = "\0".b * (n * n)
          fill = lambda do |left, top, width, height|
            row = "\x01".b * width
            height.times { |dy| grid[(top + dy) * n + left, width] = row }
          end
          fill.call(0, 0, 9, 9)          # top-left finder + separator + format info
          fill.call(n - 8, 0, 8, 9)      # top-right finder + separator + format info
          fill.call(0, n - 8, 9, 8)      # bottom-left finder + separator + format info + dark module
          centers = version.alignment_centers
          last = centers.size - 1
          centers.each_with_index do |cy, iy|
            centers.each_with_index do |cx, ix|
              next if (ix.zero? && (iy.zero? || iy == last)) || (ix == last && iy.zero?) # finder corners

              fill.call(cx - 2, cy - 2, 5, 5)
            end
          end
          fill.call(6, 9, 1, n - 17)     # vertical timing pattern
          fill.call(9, 6, n - 17, 1)     # horizontal timing pattern
          if version.number >= 7
            fill.call(n - 11, 0, 3, 6)   # version info, top right
            fill.call(0, n - 11, 6, 3)   # version info, bottom left
          end
          grid.freeze
        end
      end
    end
  end
end
