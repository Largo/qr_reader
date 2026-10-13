# frozen_string_literal: true

module QrReader
  class Detector
    # Chooses which finder patterns may form a symbol (like zxing-cpp's
    # GenerateFinderPatternSets): every combination of three patterns with
    # similar module sizes is scored by how close it comes to an isosceles
    # right triangle and how well the module sizes agree; implausible ones
    # (angle off by more than 45 degrees, legs differing by more than 2x,
    # impossible module counts) are dropped.
    module PatternSets
      COS_45 = Math.cos(Math::PI / 4)
      # Legs may differ by up to this factor (perspective).
      MAX_LEG_RATIO = 2.0
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
