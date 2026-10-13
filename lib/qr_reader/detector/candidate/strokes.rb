# frozen_string_literal: true

module QrReader
  class Detector
    class Candidate
      # Geometry from the inner ring strokes of the finder patterns (the
      # dark ring sides facing the symbol's interior), traced as straight
      # lines - which they stay under perspective - in the spirit of
      # zxing-cpp's TraceLine. Their intersections give the bottom-right
      # alignment pattern position and the grid points next to the finders,
      # their directions the finders' local axes. Mixed into Candidate.
      module Strokes
        # Offsets (in modules) along a stroke at which its centre is measured.
        STROKE_OFFSETS = [-2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0].freeze

        private

        # Intersection of the centre lines of the BL finder's top ring stroke
        # and the TR finder's left ring stroke, which meet at the centre of
        # the bottom-right alignment pattern (module (d - 6.5, d - 6.5)) even
        # under perspective. nil if the strokes cannot be traced.
        def stroke_intersection
          a = stroke(:bl_up) or return
          b = stroke(:tr_left) or return
          p = Geometry.intersect_lines(a, b) or return
          guess = parallelogram_transform(@dimensions.first)&.apply(@dimensions.first - 6.5, @dimensions.first - 6.5)
          return unless guess

          reach = (@tl.distance(@tr) + @tl.distance(@bl)) * 0.25
          Math.hypot(p[0] - guess[0], p[1] - guess[1]) < reach ? p : nil
        end

        # Centre line of one of the six inner ring strokes of the finders
        # (memoized; nil if it cannot be traced or does not run along the
        # expected symbol axis).
        def stroke(name)
          @strokes ||= {}
          return @strokes[name] if @strokes.key?(name)

          (rx, ry), (dx, dy) = @axes
          p, ux, uy, ms, ax, ay =
            case name
            when :tl_right then [@tl, rx, ry, @tl_right, dx, dy]
            when :tl_down then [@tl, dx, dy, @tl_down, rx, ry]
            when :tr_left then [@tr, -rx, -ry, @tr_left, dx, dy]
            when :tr_down then [@tr, dx, dy, @tr_down, rx, ry]
            when :bl_up then [@bl, -dx, -dy, @bl_up, rx, ry]
            when :bl_right then [@bl, rx, ry, @bl_right, dx, dy]
            end
          line = stroke_line(p, ux, uy, ms)
          # The stroke must run roughly along the other symbol axis.
          line = nil if line && (line[2] * ax + line[3] * ay).abs < 0.8
          @strokes[name] = line
        end

        # Pixel positions of the grid points next to the finder patterns -
        # modules (6.5, 6.5), (d - 6.5, 6.5) and (6.5, d - 6.5) - where the
        # centre lines of each finder's two inner ring strokes cross.
        # Returns {[gx, gy] => [x, y]} keyed by alignment grid index (n = last).
        def finder_corners(n)
          out = {}
          [[@tl, %i[tl_right tl_down], [0, 0]], [@tr, %i[tr_left tr_down], [n, 0]],
           [@bl, %i[bl_up bl_right], [0, n]]].each do |finder, (s1, s2), key|
            a = stroke(s1) or next
            b = stroke(s2) or next
            p = Geometry.intersect_lines(a, b) or next
            r = finder.distance_to(*p) / @module_size
            out[key] = p if r > 3.0 && r < 5.5
          end
          out
        end

        # Centre line of the ring stroke of finder +p+ facing the unit
        # direction (dx, dy), as [x, y, vx, vy]; nil if it cannot be traced.
        # For points spread along the stroke, the walk starts inside the
        # light ring and measures the dark stroke's extent along (dx, dy).
        def stroke_line(p, dx, dy, ms)
          return if ms < 1.5

          bits = @matrix.bits
          w = @matrix.width
          h = @matrix.height
          ex = -dy
          ey = dx
          step = ms / 6.0
          step = 0.5 if step < 0.5
          points = []
          STROKE_OFFSETS.each do |s|
            x0 = p.x + (ex * s + dx * 1.9) * ms
            y0 = p.y + (ey * s + dy * 1.9) * ms
            inside = nil
            outside = nil
            t = 0.0
            while t <= 2.8 * ms
              x = x0 + dx * t
              y = y0 + dy * t
              break unless x >= 0 && y >= 0 && x < w && y < h

              dark = bits.getbyte(y.to_i * w + x.to_i) == 1
              if inside.nil?
                break if dark && t.zero?

                inside = t if dark
                break if !dark && t > 1.3 * ms
              elsif !dark
                outside = t
                break
              end
              t += step
            end
            next unless inside && outside

            width = outside - inside
            next if width < 0.4 * ms || width > 1.8 * ms

            mid = (inside + outside - step) * 0.5
            points << [x0 + dx * mid, y0 + dy * mid]
          end
          return if points.size < 5

          Geometry.fit_line(points, 0.4 * ms)
        end
      end
    end
  end
end
