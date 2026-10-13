# frozen_string_literal: true

module QrReader
  class Detector
    # Chooses which finder patterns may form a symbol (like zxing-cpp's
    # GenerateFinderPatternSets): every combination of three patterns with
    # similar module sizes is scored by how close it comes to an isosceles
    # right triangle and how well the module sizes agree; implausible ones
    # (angle off by more than 45 degrees, legs differing by more than 2.6x,
    # impossible module counts) are dropped.
    module PatternSets
      COS_45 = Math.cos(Math::PI / 4)
      # Legs may differ by up to this factor: perspective, and pixels that
      # are not square (standard resolution fax pages: 204 x 98 dpi).
      MAX_LEG_RATIO = 2.6
      # Module sizes within one symbol may differ by up to this factor.
      MAX_SIZE_RATIO = 2.5

      # A scored triple. bl, tl, tr are ordered so that tl is the corner and
      # (tr - tl) x (bl - tl) > 0 (clockwise tl -> tr -> bl on screen) -
      # a mirrored symbol appears with tr and bl swapped.
      Triple = Struct.new(:bl, :tl, :tr, :score) do
        def patterns
          [bl, tl, tr]
        end
      end

      module_function

      # Up to +limit+ triples, best first.
      def generate(patterns, limit)
        sorted = patterns.sort_by(&:module_size)
        n = sorted.size
        sets = []
        i = 0
        while i < n - 2
          a = sorted[i]
          j = i + 1
          while j < n - 1
            b = sorted[j]
            break if b.module_size > a.module_size * MAX_SIZE_RATIO

            k = j + 1
            while k < n
              c = sorted[k]
              break if c.module_size > a.module_size * MAX_SIZE_RATIO

              set = evaluate(a, b, c)
              sets << set if set
              k += 1
            end
            j += 1
          end
          i += 1
        end
        sets.sort_by!(&:score)
        sets.first(limit)
      end

      # Triples formed by each pattern and two of its +k+ nearest neighbours
      # of similar module size, best first. Unlike #generate this scales to
      # pages with many symbols (label sheets), where the best-shaped
      # triples of a global search mostly join finders of different symbols
      # laid out on a regular grid.
      def neighbourhood(patterns, k)
        sets = {}
        patterns.each do |b|
          nearest(patterns, b, k).combination(2) do |a, c|
            next unless similar_size?(a, c)

            set = evaluate(a, b, c) or next
            sets[[set.bl, set.tl, set.tr].map(&:object_id)] ||= set
          end
        end
        sets.values.sort_by!(&:score)
      end

      # The (up to) k patterns of a similar module size nearest to +b+.
      def nearest(patterns, b, k)
        near = []
        dists = []
        bx = b.x
        by = b.y
        size = b.module_size
        i = 0
        n = patterns.size
        while i < n
          p = patterns[i]
          i += 1
          next if p.equal?(b) || p.module_size >= size * MAX_SIZE_RATIO || size >= p.module_size * MAX_SIZE_RATIO

          dx = p.x - bx
          dy = p.y - by
          d = dx * dx + dy * dy
          next if near.size == k && d >= dists[-1]

          j = dists.bsearch_index { |e| e > d } || dists.size
          dists.insert(j, d)
          near.insert(j, p)
          if near.size > k
            dists.pop
            near.pop
          end
        end
        near
      end

      # Splits +triples+ into [clean, foreign]: foreign triples have at least
      # two other patterns of a similar module size inside (or within 1.5
      # modules of) their symbol area, the parallelogram of the three
      # finder centres. A triple joining finders of neighbouring symbols on
      # a sheet of labels always has (the finders of the symbol it spans lie
      # on its edges); a real symbol has at most a false pattern or so in
      # its data area - its neighbours' finders are 7 modules plus the quiet
      # zone away. Foreign triples come with the fewest such patterns first.
      def partition_clean(triples, patterns)
        by_x = patterns.sort_by(&:x)
        xs = by_x.map(&:x)
        counted = triples.map { |t| [foreign_count(t, by_x, xs), t] }
        clean, foreign = counted.partition { |count, _| count < 2 }
        [clean.map(&:last), foreign.sort_by { |count, t| [count, t.score] }.map(&:last)]
      end

      # True if +triple+ is foreign (see partition_clean). +by_x+ are the
      # patterns sorted by x, +xs+ their x coordinates.
      def foreign?(triple, by_x, xs)
        foreign_count(triple, by_x, xs) >= 2
      end

      # Number of patterns (other than the triple's own, of similar module
      # size) inside the triple's parallelogram or within 1.5 modules of it,
      # counted up to +cap+. Points are tested in the parallelogram's own
      # coordinates (tl + s * (tr - tl) + t * (bl - tl)), with the margin
      # converted to s and t units.
      def foreign_count(triple, by_x, xs, cap = 4)
        tl = triple.tl
        tr = triple.tr
        bl = triple.bl
        x0 = tl.x
        y0 = tl.y
        ux = tr.x - x0
        uy = tr.y - y0
        vx = bl.x - x0
        vy = bl.y - y0
        det = ux * vy - uy * vx
        return 0 if det.zero?

        size = (tl.module_size + tr.module_size + bl.module_size) / 3.0
        margin = 1.5 * size
        ms = margin * Math.hypot(vx, vy) / det.abs
        mt = margin * Math.hypot(ux, uy) / det.abs
        corners_x = [x0, x0 + ux, x0 + ux + vx, x0 + vx]
        corners_y = [y0, y0 + uy, y0 + uy + vy, y0 + vy]
        min_x = corners_x.min - margin
        max_x = corners_x.max + margin
        min_y = corners_y.min - margin
        max_y = corners_y.max + margin
        i = xs.bsearch_index { |x| x >= min_x } or return 0
        count = 0
        n = by_x.size
        while i < n
          p = by_x[i]
          i += 1
          px = p.x
          break if px > max_x

          py = p.y
          next if py < min_y || py > max_y || p.equal?(tl) || p.equal?(tr) || p.equal?(bl)
          next unless p.module_size < size * MAX_SIZE_RATIO && p.module_size * MAX_SIZE_RATIO > size

          dx = px - x0
          dy = py - y0
          s = (dx * vy - dy * vx) / det
          t = (ux * dy - uy * dx) / det
          next unless s > -ms && s < 1 + ms && t > -mt && t < 1 + mt

          count += 1
          return count if count >= cap
        end
        count
      end

      def similar_size?(p, q)
        p.module_size < q.module_size * MAX_SIZE_RATIO && q.module_size < p.module_size * MAX_SIZE_RATIO
      end

      # Scores one combination; nil if it cannot be a symbol.
      def evaluate(a, b, c)
        ab = dist2(a, b)
        bc = dist2(b, c)
        ac = dist2(a, c)
        # Make b the corner (opposite the longest side, which becomes ac).
        if bc >= ab && bc >= ac
          a, b = b, a
          bc, ac = ac, bc
        elsif ab >= bc && ab >= ac
          b, c = c, b
          ab, ac = ac, ab
        end
        return if ab <= 0 || bc <= 0

        dab = Math.sqrt(ab)
        dbc = Math.sqrt(bc)
        return if dab > MAX_LEG_RATIO * dbc || dbc > MAX_LEG_RATIO * dab

        mean_size = (a.module_size + b.module_size + c.module_size) / 3.0
        modules = (dab + dbc) / (2 * mean_size) + 7
        return if modules < 21 * 0.8 || modules > 177 * 1.4

        cos = (ab + bc - ac) / (2 * dab * dbc)
        return if cos.abs > COS_45

        # 0 for an isosceles right triangle, scale invariant.
        shape = ((ac - 2 * ab).abs + (ac - 2 * bc).abs) / ac
        sizes = [a.module_size, b.module_size, c.module_size]
        size_spread = sizes.max / sizes.min - 1.0
        score = shape + 2 * size_spread + 0.5 * (1.0 - [a.quality, b.quality, c.quality].min)

        a, c = c, a if cross(b, c, a).negative?
        Triple.new(a, b, c, score)
      end

      def dist2(p, q)
        dx = p.x - q.x
        dy = p.y - q.y
        dx * dx + dy * dy
      end

      # z component of (c - b) x (a - b).
      def cross(b, c, a)
        (c.x - b.x) * (a.y - b.y) - (c.y - b.y) * (a.x - b.x)
      end
    end
  end
end
