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
      end

      # Finder patterns found so far after scanning every few rows (or every
      # row with try_harder), at most +limit+ (the most consistent ones).
      # Rows already scanned by an earlier call are not scanned again.
      def find(try_harder: false, limit: MAX_PATTERNS)
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
        prune(merge_duplicates(@found), limit)
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
        while true # not Kernel#loop: that costs a block call per run
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
            elsif (vertical = probe(cx, y, total)) && (pattern = locate(cx, total, *vertical))
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

      # Vertical check of a row hit at dark pixel (x, y) whose pattern spans
      # +total+ pixels; returns [centre y, vertical extent, bridge] or nil.
      #
      # 1. The dark run through (x, y) (the stone) must be 1.2 to 7
      #    (horizontal) modules tall: 3 for square pixels, about 1.45 on
      #    standard resolution fax pages (204 x 98 dpi), 6.2 on those turned
      #    by 90 degrees.
      # 2. The rings must show above and below it: light and dark 2 and 3
      #    (vertical) modules from its middle (one miss tolerated) - a few
      #    pixel reads that reject nearly all chance hits in textures. Ink
      #    bleed (thresholded scans and faxes with 2 px modules) can shrink
      #    the light ring to a pixel and push the dark ring inwards, so for
      #    modules of 2+ px a light run followed by a dark run, each at most
      #    3/4 of the stone, is accepted too.
      # 3. The 1:1:3:1:1 cross-check along the column, whose extent must be
      #    0.38 to 2.6 times the row's.
      #
      # Single-pixel holes are bridged (+bridge+) only if the stone is 9+ px
      # tall: with thin vertical modules a one pixel light ring is
      # structure, not noise.
      def probe(x, y, total)
        m = total / 7.0
        limit = 7 * m + 1
        top = stone_end(x, y, -1, limit, false)
        bottom = stone_end(x, y, 1, limit, false)
        if bottom - top + 2 < 1.2 * m && total >= 21
          # A noise hole may cut a stone short.
          top = stone_end(x, y, -1, limit, true)
          bottom = stone_end(x, y, 1, limit, true)
        end
        stone = bottom - top + 1
        return if stone < 1.2 * m - 1 || stone > limit
        return unless rings_sampled?(x, top, bottom, total >= 21) ||
                      (total >= 14 && ring?(x, top - 1, -1, stone) && ring?(x, bottom + 1, 1, stone))

        bridge = stone >= 9
        cy, spread = cross_check(x, y, 0, 1, 3 * (total > stone * 3 ? total : stone * 3), bridge)
        return unless cy && spread >= 0.38 * total - 1 && spread <= 2.6 * total + 1

        [cy, spread, bridge]
      end

      # Last row of the dark run through dark pixel (x, y) in vertical
      # direction +dir+, at most +limit+ + 1 rows away; with +bridge+,
      # single light pixels followed by two dark ones do not end it.
      def stone_end(x, y, dir, limit, bridge)
        bits = @bits
        w = @width
        h = @height
        k = 0
        while k <= limit
          n = y + dir
          break if n < 0 || n >= h

          unless bits.getbyte(n * w + x) == 1
            n3 = n + 2 * dir
            break unless bridge && n3 >= 0 && n3 < h && bits.getbyte((n + dir) * w + x) == 1 &&
                         bits.getbyte(n3 * w + x) == 1
          end
          y = n
          k += 1
        end
        y
      end

      # Ring samples for the stone spanning rows top..bottom at column x:
      # light 2, dark 3 vertical modules (a third of the stone) above and
      # below its middle, at most one miss; with +vote+ each sample is the
      # majority of three horizontal neighbours.
      def rings_sampled?(x, top, bottom, vote)
        h = @height
        mv = (bottom - top + 1) / 3.0
        centre = (top + bottom) >> 1
        light = (2 * mv).round
        dark = (3 * mv).round
        misses = 0
        misses += 1 unless centre - light >= 0 && colour_at?(x, centre - light, 0, vote)
        misses += 1 unless centre + light < h && colour_at?(x, centre + light, 0, vote)
        return false if misses > 1

        misses += 1 unless centre - dark >= 0 && colour_at?(x, centre - dark, 1, vote)
        return false if misses > 1

        misses += 1 unless centre + dark < h && colour_at?(x, centre + dark, 1, vote)
        misses <= 1
      end

      # True if (x, y) has +colour+; with +vote+ the majority of (x - 1..x + 1, y).
      def colour_at?(x, y, colour, vote)
        off = y * @width
        return @bits.getbyte(off + x) == colour unless vote && x > 0 && x < @width - 1

        (@bits.getbyte(off + x - 1) == colour ? 1 : 0) + (@bits.getbyte(off + x) == colour ? 1 : 0) +
          (@bits.getbyte(off + x + 1) == colour ? 1 : 0) >= 2
      end

      # True if walking vertically from (x, y) in direction +dir+ meets a
      # light run and then a dark run of 1..(3/4 * stone + 1) pixels each
      # (the dark run may end at the image border).
      def ring?(x, y, dir, stone)
        bits = @bits
        w = @width
        h = @height
        max = (stone * 3 >> 2) + 1
        light = 0
        while y >= 0 && y < h && bits.getbyte(y * w + x) == 0
          light += 1
          return false if light > max

          y += dir
        end
        return false if light.zero? || y.negative? || y >= h

        dark = 0
        while y >= 0 && y < h && bits.getbyte(y * w + x) == 1
          dark += 1
          return false if dark > max

          y += dir
        end
        true
      end

      # Confirms a row hit at dark pixel (x, y) whose pattern spans +total+
      # pixels horizontally, centre row +cy+ and +spread_v+ pixels
      # vertically (see #probe); returns a FinderPattern or nil. Isolated
      # single pixels inside runs are ignored as noise along directions in
      # which modules are 3+ px (+noise_v+ vertically).
      def locate(x, total, cy, spread_v, noise_v)
        range = 3 * (total > spread_v ? total : spread_v)
        noise_h = total >= 21
        iy = cy.floor
        cx, spread_h = cross_check(x, iy, 1, 0, range, noise_h)
        return unless cx

        ix = cx.floor
        cy, spread_v = cross_check(ix, iy, 0, 1, range, noise_v)
        return unless cy

        iy = cy.floor
        noise_d = noise_h && noise_v
        spread_d1 = cross_check(ix, iy, 1, 1, 2 * range, noise_d, relaxed: true)
        return unless spread_d1

        spread_d2 = cross_check(ix, iy, 1, -1, 2 * range, noise_d, relaxed: true)
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
      def cross_check(x, y, dx, dy, range, noise, relaxed: false)
        fwd = walk(x, y, dx, dy, range, noise) or return
        back = walk(x, y, -dx, -dy, range, noise) or return
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
      # image earlier or exceeds +range+ pixels. With +noise+, a single
      # pixel of the other colour inside a run (followed by two more of the
      # run's colour) does not end the run.
      def walk(x, y, dx, dy, range, noise)
        bits = @bits
        w = @width
        # Steps before the walk leaves the image or exceeds the range (the
        # bounds are checked once here, not per pixel).
        room = range + 1
        if dx.positive?
          room = w - x if w - x < room
        elsif dx.negative?
          room = x + 1 if x + 1 < room
        end
        if dy.positive?
          room = @height - y if @height - y < room
        elsif dy.negative?
          room = y + 1 if y + 1 < room
        end
        border = room <= range
        step = dy * w + dx
        idx = y * w + x
        r0 = r1 = run = k = n = 0
        colour = 1
        while n < room
          c = bits.getbyte(idx)
          # A single pixel of the other colour followed by two of the run's
          # colour is noise inside the run.
          if c != colour &&
             !(noise && run > 0 && n + 2 < room && bits.getbyte(idx + step) == colour &&
               bits.getbyte(idx + 2 * step) == colour)
            if k == 0
              r0 = run
            elsif k == 1
              r1 = run
            else
              return [r0, r1, run]
            end
            k += 1
            colour = c
            run = 0
          end
          run += 1
          idx += step
          n += 1
        end
        border && k == 2 ? [r0, r1, run] : nil
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
