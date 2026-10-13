# frozen_string_literal: true

module QrReader
  class Detector
    # Finds QR finder patterns - concentric 7x7, 5x5 and 3x3 squares that
    # read dark-light-dark-light-dark in the ratio 1:1:3:1:1 along every
    # line through their centre - in a binarized image.
    #
    # Rows are scanned as run lengths at C speed (String#index on the row's
    # bytes). A 1:1:3:1:1 hit first passes a cheap vertical probe (stone
    # height, light and dark ring), then cross-checks vertically,
    # horizontally and along both diagonals; its centre is refined to the
    # centroid of the 3x3 centre "stone" and its module size is estimated
    # from the four spreads in a way that compensates for rotation. Along
    # directions with modules of 3+ px, single noise pixels inside runs are
    # bridged. Pixels need not be square (fax pages).
    class FinderPatternFinder
      DARK = BitMatrix::DARK
      LIGHT = BitMatrix::LIGHT
      # In normal mode rows are skipped so that a symbol of up to 97 modules
      # (version 20) filling 3/4 of the image height is still hit 3 times.
      MAX_MODULES_FAST = 97
      MIN_SKIP = 3
      # ... and then, where the image is not textured, every FINE_SKIP-th
      # row, so that finder patterns down to about 2 px modules are still
      # crossed by several rows on large page scans (whose coarser pyramid
      # levels are too small for such symbols).
      FINE_SKIP = 3
      # A row neighbourhood whose sparse rows have more 1:1:3:1:1 ratio hits
      # than this per 1000 px is texture (noise, halftone screens): those
      # are expensive to scan densely and only scanned with try_harder.
      # Documents and symbols have below 4.
      TEXTURE_HITS = 8.0
      # More patterns than this (noise, textures) are pruned by quality.
      MAX_PATTERNS = 48
      SQRT2 = Math.sqrt(2)
      # Found patterns are indexed in a grid of cells of this many pixels
      # for the "already found here?" test of every row hit.
      CELL_SHIFT = 5

      def initialize(matrix)
        @bits = matrix.bits
        @width = matrix.width
        @height = matrix.height
        # Patterns found so far, flat (see QrReaderKernels.finder_scan).
        @state = []
        @scanned = "\0".b * @height
        # Ratio hits per scanned row.
        @hits = Array.new(@height, 0)
      end

      # Finder patterns found so far after scanning every few rows (or every
      # row with try_harder), at most +limit+ (the most consistent ones).
      # Rows already scanned by an earlier call are not scanned again.
      def find(try_harder: false, limit: MAX_PATTERNS)
        if try_harder
          scan(rows_every(1))
        else
          skip = (3 * @height) / (4 * MAX_MODULES_FAST)
          skip = MIN_SKIP if skip < MIN_SKIP
          scan(rows_every(skip))
          scan(quiet_rows(FINE_SKIP, 2 * skip)) if skip > FINE_SKIP
        end
        prune(merge_duplicates(patterns), limit)
      end

      private

      # Rows y = skip - 1, 2 * skip - 1, ... (all for skip 1) not scanned
      # yet, as a String with 1 at their index (nil if none); marks them
      # as scanned.
      def rows_every(skip)
        rows = nil
        y = skip == 1 ? 0 : skip - 1
        while y < @height
          if @scanned.getbyte(y).zero?
            @scanned.setbyte(y, 1)
            (rows ||= "\0".b * @height).setbyte(y, 1)
          end
          y += skip
        end
        rows
      end

      # Like rows_every(skip), but only rows whose neighbourhood (+reach+
      # rows up and down) had at most TEXTURE_HITS ratio hits per 1000 px
      # in the rows scanned so far.
      def quiet_rows(skip, reach)
        # Prefix sums of hits and scanned rows.
        hits = Array.new(@height + 1, 0)
        count = Array.new(@height + 1, 0)
        y = 0
        while y < @height
          scanned = @scanned.getbyte(y)
          hits[y + 1] = hits[y] + (scanned == 1 ? @hits[y] : 0)
          count[y + 1] = count[y] + scanned
          y += 1
        end
        limit = TEXTURE_HITS * @width / 1000.0
        rows = nil
        y = skip - 1
        while y < @height
          if @scanned.getbyte(y).zero?
            y0 = y > reach ? y - reach : 0
            y1 = y + reach + 1 < @height ? y + reach + 1 : @height
            n = count[y1] - count[y0]
            if n.zero? || hits[y1] - hits[y0] <= limit * n
              @scanned.setbyte(y, 1)
              (rows ||= "\0".b * @height).setbyte(y, 1)
            end
          end
          y += skip
        end
        rows
      end

      # Scans +rows+ (see rows_every; nil: nothing to do).
      def scan(rows)
        return unless rows

        result = QrReaderKernels.finder_scan(@bits, @width, @height, rows, @state)
        values = result.size - @height
        @state = result.first(values)
        y = 0
        while y < @height
          @hits[y] = result[values + y].to_i if rows.getbyte(y) == 1
          y += 1
        end
      end

      # FinderPatterns of the flat scan state, in the order found.
      def patterns
        state = @state
        fields = QrReaderKernels::FINDER_FIELDS
        out = []
        i = 0
        while i < state.size
          out << FinderPattern.new(state[i], state[i + 1], state[i + 2], state[i + 4].to_i, state[i + 3])
          i += fields
        end
        out
      end

      # Merges hits of the same pattern (centres within 2 modules, similar
      # module sizes) into count-weighted averages; each hit joins the
      # earliest matching pattern. Candidates come from a grid of cells, so
      # textured photos with a thousand hits do not cost a million tests.
      def merge_duplicates(patterns)
        merged = []
        grid = {}
        patterns.each do |p|
          i = mergeable(merged, grid, p)
          if i
            merged[i] = merged[i].merge(p)
          else
            i = merged.size
            merged << p
          end
          q = merged[i]
          (grid[cell_key(q.x, q.y)] ||= []) << i
        end
        merged
      end

      # Index of the earliest pattern in +merged+ that +p+ belongs to, or nil.
      # A match lies within 2 of its own module sizes, at most 1.5 times
      # p's, so cells within 3 of p's module sizes are searched.
      def mergeable(merged, grid, p)
        reach = 3 * p.module_size
        x0 = ((p.x - reach).to_i >> CELL_SHIFT).clamp(0, @width >> CELL_SHIFT)
        x1 = ((p.x + reach).to_i >> CELL_SHIFT).clamp(0, @width >> CELL_SHIFT)
        y0 = ((p.y - reach).to_i >> CELL_SHIFT).clamp(0, @height >> CELL_SHIFT)
        y1 = ((p.y + reach).to_i >> CELL_SHIFT).clamp(0, @height >> CELL_SHIFT)
        best = nil
        y0.upto(y1) do |cy|
          x0.upto(x1) do |cx|
            grid[(cy << 20) | cx]&.each do |i|
              next if best && i >= best

              q = merged[i]
              best = i if q.near?(p.x, p.y, 2.0) && (p.module_size / q.module_size).between?(0.67, 1.5)
            end
          end
        end
        best
      end

      def cell_key(x, y)
        ((y.to_i >> CELL_SHIFT) << 20) | (x.to_i >> CELL_SHIFT)
      end

      def prune(patterns, limit)
        return patterns if patterns.size <= limit

        patterns.max_by(limit) { |p| p.quality * Math.sqrt(p.count) }
      end
    end
  end
end
