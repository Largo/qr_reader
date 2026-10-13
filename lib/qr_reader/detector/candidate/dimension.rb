# frozen_string_literal: true

module QrReader
  class Detector
    class Candidate
      # Dimension estimation for a Candidate: module sizes measured across
      # the finder patterns, timing pattern counts and version information
      # (read through the global transform and through frames local to the
      # finders). Mixed into Candidate; relies on its @tl/@tr/@bl, @axes,
      # @matrix, the per-finder module sizes and #transform_for / #stroke.
      module Dimension
        private

        # Dimension estimates, most likely first: the timing pattern count
        # if row and column agree (or only one is readable and it lies
        # within the range of the per-side distance estimates), else the
        # rounded mean distance estimate; then the per-side estimates and
        # +-1, +-2 versions.
        def dimension_candidates(estimate, top, left)
          dims = [round_dimension(estimate), round_dimension(top), round_dimension(left)]
          row, col = timing_dimensions
          low, high = [top, left].minmax
          timing = [row, col].compact.uniq
          if timing.size == 1 && (row == col || timing[0].between?(low - 4.5, high + 4.5))
            dims.unshift(timing[0])
          else
            timing.each { |t| dims.insert(1, t) if (t - estimate).abs <= 8 }
          end
          first = dims.first
          dims.push(first - 4, first + 4, first - 8, first + 8)
          dims.select { |d| d.between?(21, 177) }.uniq
        end

        # Nearest dimension of the form 4v + 17.
        def round_dimension(estimate)
          ((estimate - 17) / 4.0).round * 4 + 17
        end

        # Module size from the 1:1:3:1:1 spread of pattern +p+ along the unit
        # direction (ux, uy); nil if the runs do not fit.
        def line_module_size(p, ux, uy)
          limit = (p.module_size * 10).ceil + 2
          noise = p.module_size >= 3
          fwd = Geometry.runs(@matrix, p.x, p.y, ux, uy, limit, noise: noise) or return
          back = Geometry.runs(@matrix, p.x, p.y, -ux, -uy, limit, noise: noise) or return
          a, b, c, d, e = back[2], back[1], fwd[0] + back[0] - 1, fwd[1], fwd[2]
          return unless Geometry.finder_ratio?(a, b, c, d, e, relaxed: true)

          (a + b + c + d + e) / 7.0
        end

        # Dimensions counted along the timing patterns (row 6 from TL to TR,
        # column 6 from TL to BL); each nil when unreadable.
        def timing_dimensions
          return [nil, nil] if @module_size < 1.2

          right, down = @axes
          row = count_timing(@tl.x + 3 * @tl_down * down[0], @tl.y + 3 * @tl_down * down[1],
                             @tr.x + 3 * @tr_down * down[0], @tr.y + 3 * @tr_down * down[1], @tl_right, @tr_left)
          col = count_timing(@tl.x + 3 * @tl_right * right[0], @tl.y + 3 * @tl_right * right[1],
                             @bl.x + 3 * @bl_right * right[0], @bl.y + 3 * @bl_right * right[1], @tl_down, @bl_up)
          [row, col]
        end

        # Walks from (x0, y0) to (x1, y1) (inside the dark rings of two finder
        # patterns, along a timing pattern) and returns 2 * light runs + 13,
        # or nil if the runs are not a clean alternation. Run lengths may
        # drift along the line (perspective, curved surfaces) but neighbours
        # must be similar and the ends must match the finders' module sizes.
        def count_timing(x0, y0, x1, y1, ms0, ms1)
          len = Math.hypot(x1 - x0, y1 - y0)
          step = [ms0, ms1].min / 4.0
          step = 0.5 if step < 0.5
          n = (len / step).floor
          return if n < 8

          sx = (x1 - x0) / n
          sy = (y1 - y0) / n
          bits = @matrix.bits
          w = @matrix.width
          h = @matrix.height
          runs = []
          color = nil
          length = 0
          i = 0
          while i <= n
            x = x0 + sx * i
            y = y0 + sy * i
            return unless x >= 0 && y >= 0 && x < w && y < h

            c = bits.getbyte(y.to_i * w + x.to_i)
            if c == color
              length += 1
            else
              runs << length if color
              color = c
              length = 1
            end
            i += 1
          end
          runs << length
          runs = merge_noise_runs(runs) if [ms0, ms1].min / step >= 3.5
          # Runs alternate dark/light starting and ending with dark (the rings).
          return if runs.size < 3 || runs.size.even?

          inner = runs[1..-2]
          unit = len / n
          return unless (inner.first * unit / ms0).between?(0.4, 2.0) && (inner.last * unit / ms1).between?(0.4, 2.0)

          inner.each_cons(2) { |a, b| return nil if a > 3 * b || b > 3 * a }
          inner.each_cons(3) { |a, _, b| return nil if a > 1.7 * b + 1 || b > 1.7 * a + 1 }
          inner.size + 14
        end

        # Merges runs of a single sample (noise when modules span several
        # samples) into their neighbours: [5, 1, 4] becomes [10].
        def merge_noise_runs(runs)
          out = []
          i = 0
          while i < runs.size
            if runs[i] == 1 && !out.empty? && i + 1 < runs.size
              out[-1] += 1 + runs[i + 1]
              i += 2
            else
              out << runs[i]
              i += 1
            end
          end
          out
        end

        # The dimension confirmed by the version information blocks (versions
        # 7+): the first candidate dimension for which a block, read through
        # the global transform or through a frame local to its finder
        # pattern, decodes to a version of exactly that dimension. Else the
        # version the first readable block names, if it is close.
        def version_dimension(dims)
          dims.each do |d|
            next if d < 45

            t = transform_for(d, @mode) or next
            versions = read_version(t, d) + local_versions(d)
            next unless versions.any? { |v| v && v.dimension == d }

            @version_confirmed = true
            return d
          end
          d = dims.find { |x| x >= 45 } or return
          t = transform_for(d, @mode) or return
          v = read_version(t, d).compact.first
          v && (v.dimension - d).abs <= 8 ? v.dimension : nil
        end

        # Version blocks read through affine frames centred on the TR and BL
        # finders, whose axes follow the finders' own ring strokes; robust
        # against curvature that bends the global transform near the edges.
        def local_versions(d)
          tr = local_frame(@tr, d - 3.5, 3.5, stroke(:tr_down), stroke(:tr_left), @tr_left, @tr_down)
          bl = local_frame(@bl, 3.5, d - 3.5, stroke(:bl_up), stroke(:bl_right), @bl_right, @bl_up)
          out = []
          out << read_version_block(tr, d, :tr) if tr
          out << read_version_block(bl, d, :bl) if bl
          out
        end

        # Lambda mapping module (mx, my) to pixels through an affine frame at
        # finder +p+ (module centre (cx, cy)); +h_line+ / +v_line+ are stroke
        # lines running along the local x / y axes. nil without both strokes.
        def local_frame(p, cx, cy, h_line, v_line, ms_x, ms_y)
          return unless h_line && v_line

          right, down = @axes
          ex = [h_line[2], h_line[3]]
          ex = ex.map(&:-@) if ex[0] * right[0] + ex[1] * right[1] < 0
          ey = [v_line[2], v_line[3]]
          ey = ey.map(&:-@) if ey[0] * down[0] + ey[1] * down[1] < 0
          lambda do |mx, my|
            u = (mx - cx) * ms_x
            v = (my - cy) * ms_y
            [p.x + u * ex[0] + v * ey[0], p.y + u * ex[1] + v * ey[1]]
          end
        end

        # One version block (:tr or :bl) read through a frame lambda.
        def read_version_block(frame, d, which)
          bits = 0
          17.downto(0) do |k|
            a = d - 11 + k % 3
            b = k / 3
            x, y = which == :tr ? frame.call(a + 0.5, b + 0.5) : frame.call(b + 0.5, a + 0.5)
            bits = (bits << 1) | pixel(x, y)
          end
          SymbolVersion.decode_version_info(bits)
        end

        # Both 18-bit version information blocks decoded (SymbolVersion or nil).
        def read_version(t, d)
          bits1 = 0
          bits2 = 0
          17.downto(0) do |k|
            a = d - 11 + k % 3
            b = k / 3
            bits1 = (bits1 << 1) | module_at(t, a, b)
            bits2 = (bits2 << 1) | module_at(t, b, a)
          end
          [SymbolVersion.decode_version_info(bits1), SymbolVersion.decode_version_info(bits2)]
        end
      end
    end
  end
end
