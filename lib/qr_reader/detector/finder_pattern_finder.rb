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
    # from the four spreads in a way that compensates for rotation. With
    # modules of 3+ px, single noise pixels inside runs are bridged.
    class FinderPatternFinder
      DARK = BitMatrix::DARK
      LIGHT = BitMatrix::LIGHT
      # In normal mode rows are skipped so that a symbol of up to 97 modules
      # (version 20) filling 3/4 of the image height is still hit 3 times.
      MAX_MODULES_FAST = 97
      MIN_SKIP = 3
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
        @found = []
        @cells = {}
        @scanned = "\0".b * @height
        @noise = false # set per hit by #locate, read by #walk
      end

      # Finder patterns found so far after scanning every few rows (or every
      # row with try_harder). Rows already scanned by an earlier call are
      # not scanned again.
      def find(try_harder: false)
        skip = (3 * @height) / (4 * MAX_MODULES_FAST)
        skip = MIN_SKIP if skip < MIN_SKIP
        skip = 1 if try_harder
        y = skip == 1 ? 0 : skip - 1
        while y < @height
          if @scanned.getbyte(y).zero?
            @scanned.setbyte(y, 1)
            scan_row(y)
          end
          y += skip
        end
        prune(merge_duplicates(@found))
      end

      private

      # Finds 1:1:3:1:1 run sequences in row y. p0..p5 are the boundaries of
      # the current window of five runs (dark, light, dark, light, dark).
      def scan_row(y)
        w = @width
        row = @bits.byteslice(y * w, w)
        p0 = row.index(DARK) or return
        p1 = row.index(LIGHT, p0) or return
        p2 = row.index(DARK, p1) or return
        p3 = row.index(LIGHT, p2) or return
        p4 = row.index(DARK, p3) or return
        p5 = row.index(LIGHT, p4) || w
        loop do
          total = p5 - p0
          # Ratio test in units of 1/14 module: each run must be within
          # half a module (+0.5 px) of its nominal width, the centre within
          # 0.75 modules.
          tol = total + 7
          if total >= 7 &&
             (14 * (p1 - p0) - 2 * total).abs <= tol &&
             (14 * (p2 - p1) - 2 * total).abs <= tol &&
             (14 * (p3 - p2) - 6 * total).abs <= tol + (total >> 1) &&
             (14 * (p4 - p3) - 2 * total).abs <= tol &&
             (14 * (p5 - p4) - 2 * total).abs <= tol
            cx = (p2 + p3) >> 1
            known = known_pattern(cx + 0.5, y + 0.5)
            if known
              known.add_hit
            elsif probe(cx, y, total) && (pattern = locate(cx, y, total))
              add(pattern)
            end
          end
          break if p5 >= w

          p0 = p2
          p1 = p3
          p2 = p4
          p3 = p5
          p4 = row.index(DARK, p3) or break
          p5 = row.index(LIGHT, p4) || w
        end
      end

      # The found pattern covering (x, y), if any.
      def known_pattern(x, y)
        list = @cells[((y.to_i >> CELL_SHIFT) << 20) | (x.to_i >> CELL_SHIFT)] or return
        list.find { |f| f.near?(x, y, 3.5) }
      end

      def add(pattern)
        @found << pattern
        r = pattern.module_size * 3.5
        y0 = ((pattern.y - r).floor.clamp(0, @height - 1)) >> CELL_SHIFT
        y1 = ((pattern.y + r).ceil.clamp(0, @height - 1)) >> CELL_SHIFT
        x0 = ((pattern.x - r).floor.clamp(0, @width - 1)) >> CELL_SHIFT
        x1 = ((pattern.x + r).ceil.clamp(0, @width - 1)) >> CELL_SHIFT
        y0.upto(y1) { |cy| x0.upto(x1) { |cx| (@cells[(cy << 20) | cx] ||= []) << pattern } }
      end

      # Quick vertical plausibility test of a row hit before the full
      # cross-checks: the dark run through (x, y) (the stone) must be 1.5 to
      # 5 (horizontal) modules tall, and 2 and 3 (vertical) modules above
      # and below its middle the light and dark rings must show (one miss
      # tolerated). Rejects nearly all chance hits in noise and textures for
      # a few pixel reads.
      def probe(x, y, total)
        m = total / 7.0
        h = @height
        limit = (4 * m).ceil
        # With modules of 3+ px a single light pixel does not end the stone.
        gap = total >= 21 ? 2 : 1
        top = y
        top -= 1 while top > 0 && y - top < limit && dark_within?(x, top - 1, -gap)
        bottom = y
        bottom += 1 while bottom < h - 1 && bottom - y < limit && dark_within?(x, bottom + 1, gap)
        height = bottom - top + 1
        return false if height < 1.5 * m - 1 || height > 5 * m + 1

        # The stone is 3 modules tall: that gives the vertical module size,
        # which differs from the horizontal one under perspective.
        mv = height / 3.0
        centre = (top + bottom) >> 1
        misses = 0
        [[(2 * mv).round, 0], [(3 * mv).round, 1]].each do |d, colour|
          up = centre - d
          down = centre + d
          misses += 1 unless up >= 0 && colour_at?(x, up, colour, gap > 1)
          misses += 1 unless down < h && colour_at?(x, down, colour, gap > 1)
        end
        misses <= 1
      end

      # True if (x, y) is dark, or with |step| = 2 if the next two pixels in
      # that vertical direction are (so that a one pixel hole is bridged but
      # not the gap to a noise pixel beyond the run's end).
      def dark_within?(x, y, step)
        w = @width
        return true if @bits.getbyte(y * w + x) == 1
        return false if step.abs < 2

        dir = step.positive? ? 1 : -1
        y1 = y + dir
        y2 = y + 2 * dir
        y2 >= 0 && y2 < @height && @bits.getbyte(y1 * w + x) == 1 && @bits.getbyte(y2 * w + x) == 1
      end

      # True if (x, y) has +colour+; with +vote+ the majority of (x - 1..x + 1, y).
      def colour_at?(x, y, colour, vote)
        off = y * @width
        return @bits.getbyte(off + x) == colour unless vote && x.positive? && x < @width - 1

        (@bits.getbyte(off + x - 1) == colour ? 1 : 0) + (@bits.getbyte(off + x) == colour ? 1 : 0) +
          (@bits.getbyte(off + x + 1) == colour ? 1 : 0) >= 2
      end

      # Confirms a row hit at dark pixel (x, y) whose pattern spans +total+
      # pixels; returns a FinderPattern or nil.
      def locate(x, y, total)
        range = 3 * total
        # Isolated single pixels inside runs are ignored as noise when
        # modules are big enough for that not to erase real structure.
        @noise = total >= 21
        cy, spread_v = cross_check(x, y, 0, 1, range)
        return unless cy

        iy = cy.floor
        cx, spread_h = cross_check(x, iy, 1, 0, range)
        return unless cx

        ix = cx.floor
        cy, spread_v = cross_check(ix, iy, 0, 1, range)
        return unless cy

        iy = cy.floor
        spread_d1 = cross_check(ix, iy, 1, 1, 2 * range, relaxed: true)
        return unless spread_d1

        spread_d2 = cross_check(ix, iy, 1, -1, 2 * range, relaxed: true)
        return unless spread_d2

        spreads = [spread_v, spread_h, spread_d1, spread_d2]
        min, max = spreads.minmax
        return if max > 3 * min

        size = square_size((spread_v + spread_h) * 0.5, (spread_d1 + spread_d2) * 0.5)
        module_size = size / 7.0
        sx, sy = stone_centroid(ix, iy, module_size)
        if sx
          cx = sx
          cy = sy
        end
        pattern = FinderPattern.new(cx, cy, module_size)
        pattern.quality = quality(spreads)
        pattern
      end

      # Side length of a square whose chords through the centre measure +h+
      # along the axes and +g+ along the diagonals. A square of side s
      # rotated by t (0..45 degrees) has h = s / cos(t) and
      # g = s / cos(45 - t); eliminating t gives the formula below.
      def square_size(h, g)
        a = 1.0 / h
        b = SQRT2 / g - a
        1.0 / Math.sqrt(a * a + b * b)
      end

      # How square-like the spreads are (1.0 = perfect), used for pruning.
      def quality(spreads)
        min, max = spreads.minmax
        min.fdiv(max)
      end

      # Cross-check through dark pixel (x, y) along (dx, dy) and back.
      # Returns [centre, spread]: the centre of the middle run along the
      # line's main axis (x for horizontal, y otherwise) in continuous
      # coordinates and the pattern's total extent in pixels. For
      # diagonals only the spread is returned. nil if no 1:1:3:1:1 pattern.
      def cross_check(x, y, dx, dy, range, relaxed: false)
        fwd = walk(x, y, dx, dy, range) or return
        back = walk(x, y, -dx, -dy, range) or return
        centre = fwd[0] + back[0] - 1
        return unless Geometry.finder_ratio?(back[2], back[1], centre, fwd[1], fwd[2], relaxed: relaxed)

        spread = back[2] + back[1] + centre + fwd[1] + fwd[2]
        return spread * SQRT2 if dx != 0 && dy != 0

        start = dx.zero? ? y - back[0] + 1 : x - back[0] + 1
        [start + centre * 0.5, spread]
      end

      # Lengths of the first three runs (dark, light, dark) met walking from
      # dark pixel (x, y) in direction (dx, dy), the first including (x, y).
      # The last run may end at the image border; nil if the walk leaves the
      # image earlier or exceeds +range+ pixels. With @noise set, a single
      # pixel of the other colour inside a run (followed by two more of the
      # run's colour) does not end the run.
      def walk(x, y, dx, dy, range)
        bits = @bits
        w = @width
        h = @height
        step = dy * w + dx
        idx = y * w + x
        noise = @noise
        r0 = r1 = r2 = 0
        state = 0
        color = 1
        n = 0
        while n <= range
          unless x >= 0 && y >= 0 && x < w && y < h
            return state == 2 ? [r0, r1, r2] : nil
          end

          c = bits.getbyte(idx)
          if c != color
            # A single pixel of the other colour followed by two of the
            # run's colour is noise inside the run.
            nx = x + 2 * dx
            ny = y + 2 * dy
            if noise && n.positive? && nx >= 0 && ny >= 0 && nx < w && ny < h &&
               bits.getbyte(idx + step) == color && bits.getbyte(idx + 2 * step) == color
              c = color
            else
              state += 1
              return [r0, r1, r2] if state == 3

              color = c
            end
          end
          case state
          when 0 then r0 += 1
          when 1 then r1 += 1
          else r2 += 1
          end
          x += dx
          y += dy
          idx += step
          n += 1
        end
        nil
      end

      # Centroid of the dark 3x3 centre square containing (x, y), gathered
      # from its horizontal runs. nil if the stone is not cleanly separated
      # from the surrounding ring (merged by blur or noise).
      def stone_centroid(x, y, module_size)
        bits = @bits
        w = @width
        max_run = (module_size * 5).ceil
        max_rows = (module_size * 2.6).ceil + 1
        area = 0
        sum_x = 0
        sum_y = 0
        [-1, 1].each do |dir|
          yy = dir.negative? ? y : y + 1
          xx = x
          rows = 0
          while yy >= 0 && yy < @height
            off = yy * w
            break unless bits.getbyte(off + xx) == 1

            left = bits.rindex(LIGHT, off + xx)
            left = left && left >= off ? left + 1 : off
            right = bits.index(LIGHT, off + xx)
            right = off + w if right.nil? || right > off + w
            return if right - left > max_run

            len = right - left
            area += len
            sum_x += (left + right - 2 * off) * len
            sum_y += (2 * yy + 1) * len
            xx = ((left + right) >> 1) - off
            rows += 1
            return if rows > max_rows

            yy += dir
          end
        end
        nominal = 9 * module_size * module_size
        return if area < nominal * 0.3 || area > nominal * 2.5

        [sum_x * 0.5 / area, sum_y * 0.5 / area]
      end

      def merge_duplicates(patterns)
        merged = []
        patterns.each do |p|
          i = merged.index do |q|
            q.near?(p.x, p.y, 2.0) && (p.module_size / q.module_size).between?(0.67, 1.5)
          end
          if i
            merged[i] = merged[i].merge(p)
          else
            merged << p
          end
        end
        merged
      end

      def prune(patterns)
        return patterns if patterns.size <= MAX_PATTERNS

        patterns.max_by(MAX_PATTERNS) { |p| p.quality * Math.sqrt(p.count) }
      end
    end
  end
end
