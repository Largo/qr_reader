# frozen_string_literal: true

# Detector kernels: finder pattern search in a binarized image. Kernel files
# are plain Ruby in the subset that Spinel compiles (see DESIGN.md,
# "Kernels"): the optional qr_reader-native gem builds them into a C
# extension, otherwise they run as they are.
module QrReaderKernels
  # Values per pattern in the flat arrays of finder_scan: x, y, module size,
  # quality, hit count.
  FINDER_FIELDS = 5

  # Scans the rows y with rows.getbyte(y) == 1 of a width x height bit
  # matrix (one byte per pixel, 1 = dark) for QR finder patterns.
  # +known+ holds the patterns of earlier scans of the same matrix as flat
  # [x, y, module_size, quality, count, ...] (FINDER_FIELDS per pattern);
  # returns them (counts updated with the new row hits) followed by the
  # patterns found in these rows, in the order found. See
  # QrReader::Detector::FinderPatternFinder for the method.
  # spinel-sample: QrReaderKernels.finder_scan("\x00".b * 64, 8, 8, "\x01".b * 8, [1.5, 1.5, 1.0, 1.0, 1.0])
  def self.finder_scan(bits, width, height, rows, known)
    scanner = FinderScanner.new(bits, width, height, known)
    y = 0
    while y < height
      scanner.scan_row(y) if rows.getbyte(y) == 1
      y += 1
    end
    scanner.result
  end

  # State of one finder_scan call: the patterns found so far, indexed in a
  # grid of 32 x 32 pixel cells (one linked list of pattern numbers per
  # cell, in insertion order) for the "already found here?" test of every
  # row hit. Multiple results of the cross-checks are passed in instance
  # variables (no allocation per hit).
  class FinderScanner
    SQRT2 = Math.sqrt(2)
    CELL_SHIFT = 5
    DARK = "\x01".b.freeze
    LIGHT = "\x00".b.freeze

    def initialize(bits, width, height, known)
      @bits = bits
      @width = width
      @height = height
      @xs = []
      @ys = []
      @sizes = []
      @qualities = []
      @counts = []
      @cell_cols = (width >> CELL_SHIFT) + 1
      cells = @cell_cols * ((height >> CELL_SHIFT) + 1)
      @heads = Array.new(cells, -1)
      @tails = Array.new(cells, -1)
      @link_next = []
      @link_pattern = []
      # Results of walk / cross_check / probe.
      @run0 = 0
      @run1 = 0
      @run2 = 0
      @centre = 0.0
      @spread = 0
      @diagonal = 0.0
      @probe_centre = 0.0
      @probe_spread = 0
      @probe_bridge = false
      i = 0
      n = known.size
      while i + 4 < n
        add(known[i], known[i + 1], known[i + 2], known[i + 3], known[i + 4].to_i)
        i += FINDER_FIELDS
      end
    end

    # All patterns as flat [x, y, module_size, quality, count, ...].
    def result
      out = []
      i = 0
      n = @xs.size
      while i < n
        out << @xs[i] << @ys[i] << @sizes[i] << @qualities[i] << @counts[i].to_f
        i += 1
      end
      out
    end

    # Finds 1:1:3:1:1 run sequences in row y. p0..p5 are the boundaries of
    # the current window of five runs (dark, light, dark, light, dark).
    # Runs of one or two pixels (textures) are read directly, longer ones
    # are searched for at C speed.
    def scan_row(y)
      bits = @bits
      w = @width
      off = y * w
      row = bits.byteslice(off, w)
      p0 = row.index(DARK)
      return if p0.nil?

      p1 = row.index(LIGHT, p0)
      return if p1.nil?

      p2 = row.index(DARK, p1)
      return if p2.nil?

      p3 = row.index(LIGHT, p2)
      return if p3.nil?

      p4 = row.index(DARK, p3)
      return if p4.nil?

      p5 = row.index(LIGHT, p4)
      p5 = w if p5.nil?
      while true
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
          hit((p2 + p3) >> 1, y, total)
        end
        break if p5 >= w

        p0 = p2
        p1 = p3
        p2 = p4
        p3 = p5
        p4 = p3 + 1
        if p4 < w && bits.getbyte(off + p4) == 0
          p4 += 1
          if p4 < w && bits.getbyte(off + p4) == 0
            p4 = row.index(DARK, p4)
            break if p4.nil?
          end
        end
        break if p4 >= w

        p5 = p4 + 1
        if p5 < w && bits.getbyte(off + p5) == 1
          p5 += 1
          if p5 < w && bits.getbyte(off + p5) == 1
            p5 = row.index(LIGHT, p5)
            p5 = w if p5.nil?
          end
        end
      end
    end

    # A row hit at dark pixel (x, y) spanning +total+ pixels: counts it for
    # a pattern found before, or verifies it and adds a new pattern.
    def hit(x, y, total)
      known = known_pattern(x + 0.5, y + 0.5)
      if known >= 0
        @counts[known] += 1
      elsif probe(x, y, total)
        locate(x, total, @probe_centre, @probe_spread, @probe_bridge)
      end
    end

    # Number of the first pattern found whose centre lies within 3.5 module
    # sizes of (x, y), or -1.
    def known_pattern(x, y)
      link = @heads[((y.to_i >> CELL_SHIFT) * @cell_cols) + (x.to_i >> CELL_SHIFT)]
      while link >= 0
        i = @link_pattern[link]
        r = @sizes[i] * 3.5
        dx = @xs[i] - x
        dy = @ys[i] - y
        return i if dx * dx + dy * dy < r * r

        link = @link_next[link]
      end
      -1
    end

    def add(x, y, module_size, quality, count)
      i = @xs.size
      @xs << x
      @ys << y
      @sizes << module_size
      @qualities << quality
      @counts << count
      r = module_size * 3.5
      y0 = clamp((y - r).floor, 0, @height - 1) >> CELL_SHIFT
      y1 = clamp((y + r).ceil, 0, @height - 1) >> CELL_SHIFT
      x0 = clamp((x - r).floor, 0, @width - 1) >> CELL_SHIFT
      x1 = clamp((x + r).ceil, 0, @width - 1) >> CELL_SHIFT
      cy = y0
      while cy <= y1
        cx = x0
        while cx <= x1
          link_cell(cy * @cell_cols + cx, i)
          cx += 1
        end
        cy += 1
      end
    end

    def link_cell(cell, pattern)
      link = @link_pattern.size
      @link_pattern << pattern
      @link_next << -1
      tail = @tails[cell]
      if tail < 0
        @heads[cell] = link
      else
        @link_next[tail] = link
      end
      @tails[cell] = link
    end

    def clamp(v, lo, hi)
      return lo if v < lo
      return hi if v > hi

      v
    end

    # Vertical check of a row hit at dark pixel (x, y) whose pattern spans
    # +total+ pixels (see FinderPatternFinder#probe). On success sets
    # @probe_centre, @probe_spread, @probe_bridge.
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
      return false if stone < 1.2 * m - 1 || stone > limit
      return false unless rings_sampled?(x, top, bottom, total >= 21) ||
                          (total >= 14 && ring?(x, top - 1, -1, stone) && ring?(x, bottom + 1, 1, stone))

      bridge = stone >= 9
      return false unless cross_check(x, y, 0, 1, 3 * (total > stone * 3 ? total : stone * 3), bridge, false)

      spread = @spread
      return false unless spread >= 0.38 * total - 1 && spread <= 2.6 * total + 1

      @probe_centre = @centre
      @probe_spread = spread
      @probe_bridge = bridge
      true
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

        if bits.getbyte(n * w + x) != 1
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
    # light 2, dark 3 vertical modules above and below its middle, at most
    # one miss; with +vote+ each sample is the majority of three
    # horizontal neighbours.
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
      return false if light == 0 || y < 0 || y >= h

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
    # vertically, and adds the pattern (see FinderPatternFinder#locate).
    def locate(x, total, cy, spread_v, noise_v)
      range = 3 * (total > spread_v ? total : spread_v)
      noise_h = total >= 21
      iy = cy.floor
      return unless cross_check(x, iy, 1, 0, range, noise_h, false)

      cx = @centre
      spread_h = @spread
      ix = cx.floor
      return unless cross_check(ix, iy, 0, 1, range, noise_v, false)

      cy = @centre
      spread_v = @spread
      iy = cy.floor
      noise_d = noise_h && noise_v
      return unless cross_check(ix, iy, 1, 1, 2 * range, noise_d, true)

      spread_d1 = @diagonal
      return unless cross_check(ix, iy, 1, -1, 2 * range, noise_d, true)

      spread_d2 = @diagonal
      v = spread_v.to_f
      hz = spread_h.to_f
      min = v
      min = hz if hz < min
      min = spread_d1 if spread_d1 < min
      min = spread_d2 if spread_d2 < min
      max = v
      max = hz if hz > max
      max = spread_d1 if spread_d1 > max
      max = spread_d2 if spread_d2 > max
      return if max > 3 * min

      size = square_size((spread_v + spread_h) * 0.5, (spread_d1 + spread_d2) * 0.5)
      module_size = size / 7.0
      if stone_centroid(ix, iy, module_size)
        cx = @centre
        cy = @diagonal
      end
      add(cx, cy, module_size, min / max, 1)
    end

    # Side length of a square whose chords through the centre measure +h+
    # along the axes and +g+ along the diagonals.
    def square_size(h, g)
      a = 1.0 / h
      b = SQRT2 / g - a
      1.0 / Math.sqrt(a * a + b * b)
    end

    # Cross-check through dark pixel (x, y) along (dx, dy) and back. For
    # axis directions sets @centre (centre of the middle run along the
    # line's main axis, continuous coordinates) and @spread (the pattern's
    # extent in pixels); for diagonals @diagonal (the extent, scaled to
    # pixels along the axes). False if no 1:1:3:1:1 pattern.
    def cross_check(x, y, dx, dy, range, noise, relaxed)
      return false unless walk(x, y, dx, dy, range, noise)

      f0 = @run0
      f1 = @run1
      f2 = @run2
      return false unless walk(x, y, -dx, -dy, range, noise)

      centre = f0 + @run0 - 1
      return false unless finder_ratio?(@run2, @run1, centre, f1, f2, relaxed)

      spread = @run2 + @run1 + centre + f1 + f2
      if dx != 0 && dy != 0
        @diagonal = spread * SQRT2
      else
        start = dx == 0 ? y - @run0 + 1 : x - @run0 + 1
        @centre = start + centre * 0.5
        @spread = spread
      end
      true
    end

    # 1:1:3:1:1 test: each run within 0.5 module (0.75 if relaxed) plus
    # half a pixel of its nominal width, the centre run 0.25 module more.
    def finder_ratio?(a, b, c, d, e, relaxed)
      total = a + b + c + d + e
      return false if total < 7

      # In units of 1/28 module.
      tol = (relaxed ? 3 * total : 2 * total) + 14
      (28 * a - 4 * total).abs <= tol &&
        (28 * b - 4 * total).abs <= tol &&
        (28 * c - 12 * total).abs <= tol + total &&
        (28 * d - 4 * total).abs <= tol &&
        (28 * e - 4 * total).abs <= tol
    end

    # Lengths of the first three runs (dark, light, dark) met walking from
    # dark pixel (x, y) in direction (dx, dy) into @run0..@run2. The last
    # run may end at the image border; false if the walk leaves the image
    # earlier or exceeds +range+ pixels. With +noise+, a single pixel of
    # the other colour inside a run (followed by two more of the run's
    # colour) does not end the run.
    def walk(x, y, dx, dy, range, noise)
      bits = @bits
      w = @width
      # Steps before the walk leaves the image or exceeds the range.
      room = range + 1
      if dx > 0
        room = w - x if w - x < room
      elsif dx < 0
        room = x + 1 if x + 1 < room
      end
      if dy > 0
        room = @height - y if @height - y < room
      elsif dy < 0
        room = y + 1 if y + 1 < room
      end
      border = room <= range
      step = dy * w + dx
      idx = y * w + x
      r0 = 0
      r1 = 0
      run = 0
      k = 0
      n = 0
      colour = 1
      while n < room
        c = bits.getbyte(idx)
        if c != colour &&
           !(noise && run > 0 && n + 2 < room && bits.getbyte(idx + step) == colour &&
             bits.getbyte(idx + 2 * step) == colour)
          if k == 0
            r0 = run
          elsif k == 1
            r1 = run
          else
            @run0 = r0
            @run1 = r1
            @run2 = run
            return true
          end
          k += 1
          colour = c
          run = 0
        end
        run += 1
        idx += step
        n += 1
      end
      return false unless border && k == 2

      @run0 = r0
      @run1 = r1
      @run2 = run
      true
    end

    # Centroid of the dark 3x3 centre square containing (x, y), gathered
    # from its horizontal runs, into @centre (x) and @diagonal (y). False
    # if the stone is not cleanly separated from the surrounding ring.
    def stone_centroid(x, y, module_size)
      max_run = (module_size * 5).ceil
      max_rows = (module_size * 2.6).ceil + 1
      @area = 0
      @sum_x = 0
      @sum_y = 0
      return false unless stone_half(x, y, -1, max_run, max_rows)
      return false unless stone_half(x, y + 1, 1, max_run, max_rows)

      area = @area
      nominal = 9 * module_size * module_size
      return false if area < nominal * 0.3 || area > nominal * 2.5

      @centre = @sum_x * 0.5 / area
      @diagonal = @sum_y * 0.5 / area
      true
    end

    # Adds the dark runs of rows yy, yy + dir, ... that continue the stone
    # (each starting below/above the middle of the previous one) to @area,
    # @sum_x, @sum_y. False if a run is too long or there are too many rows.
    def stone_half(xx, yy, dir, max_run, max_rows)
      bits = @bits
      w = @width
      rows = 0
      while yy >= 0 && yy < @height
        off = yy * w
        break unless bits.getbyte(off + xx) == 1

        left = off + xx
        left -= 1 while left > off && bits.getbyte(left - 1) == 1
        right = off + xx
        stop = off + w
        right += 1 while right < stop && bits.getbyte(right) == 1
        len = right - left
        return false if len > max_run

        @area += len
        @sum_x += (left + right - 2 * off) * len
        @sum_y += (2 * yy + 1) * len
        xx = ((left + right) >> 1) - off
        rows += 1
        return false if rows > max_rows

        yy += dir
      end
      true
    end
  end
end
