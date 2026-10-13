# frozen_string_literal: true

module QrReader
  class Detector
    # Fast path for clean, axis-aligned, unrotated-or-quarter-turned symbols
    # such as generated images: the symbol is the bounding box of all dark
    # pixels, three of its corners must hold finder patterns (checked
    # along the corner diagonals, which also yields the module size), and
    # modules are sampled at their centres. Costs a few String#index calls
    # when the image is not such a symbol.
    module PureDetector
      DARK = BitMatrix::DARK

      # A detected pure symbol; same interface as Candidate.
      class Result
        attr_reader :bits, :points, :finder_patterns, :dimension, :module_size

        def initialize(bits, points, finder_patterns, module_size)
          @bits = bits
          @points = points
          @finder_patterns = finder_patterns
          @dimension = bits.width
          @module_size = module_size
        end

        def alternatives
          return enum_for(:alternatives) unless block_given?

          nil
        end

        def uses?(_pattern)
          false
        end

        def key
          @finder_patterns.map { |x, y| [x.round, y.round] }
        end

        def inspect
          "#<PureDetector::Result dim=#{@dimension} module_size=#{@module_size.round(2)}>"
        end
      end

      module_function

      # Result or nil.
      def detect(matrix)
        box = bounding_box(matrix) or return
        left, top, right, bottom = box
        width = right - left
        height = bottom - top
        return if width < 21 || height < 21 || (width - height).abs > 2 + width / 50

        # Diagonal walks into each corner: TL, TR, BR, BL.
        corners = [[left, top, 1, 1], [right - 1, top, -1, 1],
                   [right - 1, bottom - 1, -1, -1], [left, bottom - 1, 1, -1]]
        sizes = corners.map { |x, y, dx, dy| corner_finder(matrix, x, y, dx, dy, width) }
        missing = sizes.each_index.select { |i| sizes[i].nil? }
        return unless missing.size == 1

        module_size = sizes.compact.sum / 3.0
        dimension = ((width + height) * 0.5 / module_size).round
        return unless SymbolVersion.for_dimension(dimension)

        mx = width.to_f / dimension
        my = height.to_f / dimension
        return if (mx / module_size - 1).abs > 0.2 || (my / module_size - 1).abs > 0.2

        bits = sample(matrix, left, top, mx, my, dimension)
        # Turn the symbol so that the corner without finder is bottom-right.
        quarter_turns = (2 - missing.first) % 4
        bits = rotate(bits, quarter_turns)
        points = [[left, top], [right, top], [right, bottom], [left, bottom]].rotate(-quarter_turns % 4)
        mid_x = (left + right) * 0.5
        mid_y = (top + bottom) * 0.5
        centre = ->(px, py) { [px + (mid_x <=> px) * 3.5 * mx, py + (mid_y <=> py) * 3.5 * my] }
        finders = [centre.call(*points[0]), centre.call(*points[1]), centre.call(*points[3])]
        Result.new(bits, points.map { |x, y| [x.to_f, y.to_f] }, finders, module_size)
      end

      # [left, top, right, bottom] (right/bottom exclusive) of the dark pixels.
      def bounding_box(matrix)
        bits = matrix.bits
        w = matrix.width
        first = bits.index(DARK) or return
        last = bits.rindex(DARK)
        top = first / w
        bottom = last / w + 1
        left = w
        right = 0
        y = top
        off = top * w
        while y < bottom
          # No substring per row: the first dark pixel at or after the row
          # start is in this row, or rows without any are skipped at once.
          l = bits.index(DARK, off)
          if l >= off + w
            y = l / w
            off = y * w
            next
          end
          left = l - off if l - off < left
          r = bits.rindex(DARK, off + w - 1)
          right = r - off + 1 if r - off >= right
          off += w
          y += 1
        end
        [left, top, right, bottom]
      end

      # Module size of a finder pattern whose outer corner is at (x, y),
      # from the 1:1:3:1:1 runs along the diagonal (dx, dy); the edges
      # leaving the corner must be dark for 7 modules, then light. nil if
      # there is no finder pattern.
      def corner_finder(matrix, x, y, dx, dy, limit)
        runs = diagonal_runs(matrix, x, y, dx, dy, limit)
        return unless runs.size == 5 && Geometry.finder_ratio?(*runs, relaxed: true)

        module_size = runs.sum / 7.0
        return unless edge_run?(matrix, x, y, dx, 0, module_size) && edge_run?(matrix, x, y, 0, dy, module_size)

        module_size
      end

      # Up to five alternating run lengths along a diagonal, starting dark.
      def diagonal_runs(matrix, x, y, dx, dy, limit)
        bits = matrix.bits
        w = matrix.width
        h = matrix.height
        runs = [0]
        dark = true
        steps = 0
        while steps < limit && x >= 0 && y >= 0 && x < w && y < h
          if (bits.getbyte(y * w + x) == 1) == dark
            runs[-1] += 1
          else
            break if runs.size == 5

            runs << 1
            dark = !dark
          end
          x += dx
          y += dy
          steps += 1
        end
        runs
      end

      # True if the dark run from (x, y) along (dx, dy) is 7 modules long.
      def edge_run?(matrix, x, y, dx, dy, module_size)
        bits = matrix.bits
        w = matrix.width
        h = matrix.height
        n = 0
        while x >= 0 && y >= 0 && x < w && y < h && bits.getbyte(y * w + x) == 1
          n += 1
          x += dx
          y += dy
        end
        (n / module_size - 7).abs < 1.0
      end

      def sample(matrix, left, top, mx, my, dimension)
        bits = matrix.bits
        w = matrix.width
        out = "\0".b * (dimension * dimension)
        j = 0
        while j < dimension
          y = (top + (j + 0.5) * my).to_i
          off = y * w
          i = 0
          while i < dimension
            out.setbyte(j * dimension + i, 1) if bits.getbyte(off + (left + (i + 0.5) * mx).to_i) == 1
            i += 1
          end
          j += 1
        end
        BitMatrix.new(dimension, dimension, out)
      end

      # Rotates a square matrix by +turns+ quarter turns clockwise.
      def rotate(matrix, turns)
        turns.times do
          n = matrix.width
          src = matrix.bits
          out = "\0".b * (n * n)
          n.times do |y|
            n.times { |x| out.setbyte(x * n + (n - 1 - y), src.getbyte(y * n + x)) }
          end
          matrix = BitMatrix.new(n, n, out)
        end
        matrix
      end
    end
  end
end
