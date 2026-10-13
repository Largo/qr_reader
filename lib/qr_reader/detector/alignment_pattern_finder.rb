# frozen_string_literal: true

module QrReader
  class Detector
    # Finds alignment patterns (a dark module inside a light 3x3 ring inside
    # a dark 5x5 ring) near a predicted position.
    #
    # Rows of a window around the prediction are scanned for light-dark-light
    # runs of about one module each (from the middle row outwards), hits are
    # cross-checked vertically and then verified by sampling the 5x5
    # structure along the symbol's own axes, which rejects the many
    # look-alikes in the data area. The verified hit closest to the
    # prediction wins.
    class AlignmentPatternFinder
      DARK = BitMatrix::DARK
      LIGHT = BitMatrix::LIGHT
      # Of the 25 cells of the 5x5 pattern this many may read wrong.
      MAX_MISMATCHES = 5

      # Module offsets of the 8 light ring cells and the 16 dark ring cells.
      LIGHT_RING = [[-1, -1], [0, -1], [1, -1], [-1, 0], [1, 0], [-1, 1], [0, 1], [1, 1]].freeze
      DARK_RING = ((-2..2).flat_map { |i| [[i, -2], [i, 2]] } + (-1..1).flat_map { |i| [[-2, i], [2, i]] }).freeze

      def initialize(matrix)
        @matrix = matrix
        @bits = matrix.bits
        @width = matrix.width
        @height = matrix.height
      end

      # Searches the square window of +radius+ pixels around (x, y).
      # +ux+, +uy+ / +vx+, +vy+ are the pixel vectors of one module step
      # along the symbol's x and y axes at that location (for verification).
      # Returns [cx, cy] or nil.
      def find(x, y, radius, ux, uy, vx, vy)
        module_size = Math.sqrt((ux * ux + uy * uy + vx * vx + vy * vy) * 0.5)
        return if module_size < 0.8 || !x.finite? || !y.finite?

        x0 = (x - radius).floor.clamp(0, @width - 1)
        x1 = (x + radius).ceil.clamp(0, @width - 1)
        y0 = (y - radius).floor.clamp(0, @height - 1)
        y1 = (y + radius).ceil.clamp(0, @height - 1)
        return if x1 - x0 < 3 || y1 - y0 < 3

        best = nil
        best_score = Float::INFINITY
        # Rows through the same pattern confirm the same centre: verify once.
        verified = {}
        mid = y.floor.clamp(y0, y1)
        max_offset = [mid - y0, y1 - mid].max
        offset = 0
        while offset <= max_offset
          [mid - offset, mid + offset].uniq.each do |row|
            next if row < y0 || row > y1

            scan_row(row, x0, x1, module_size) do |cx|
              centre = confirm(cx, row, module_size)
              next unless centre

              key = ((centre[1] * 2).round << 24) | (centre[0] * 2).round
              next if verified.key?(key)

              verified[key] = true
              mismatches = verify(centre[0], centre[1], ux, uy, vx, vy)
              next if mismatches > MAX_MISMATCHES

              score = Math.hypot(centre[0] - x, centre[1] - y) / module_size + mismatches
              if score < best_score
                best_score = score
                best = centre
              end
            end
          end
          # Stop early once a clean pattern close to the prediction is known.
          break if best && best_score < offset / module_size - 1.0

          offset += 1
        end
        best
      end

      private

      # Yields the centre column of every light-dark-light run triple with
      # runs of about one module in row y between columns x0 and x1, where
      # the dark ring continues on both sides.
      def scan_row(y, x0, x1, module_size)
        w = @width
        off = y * w
        row = @bits.byteslice(off, w)
        max = module_size * 1.6 + 1
        min = module_size * 0.4 - 1
        pos = row.index(LIGHT, x0) or return
        while pos < x1
          d0 = row.index(DARK, pos) or return
          d1 = row.index(LIGHT, d0) or return
          l1 = row.index(DARK, d1) or return
          a = d0 - pos
          b = d1 - d0
          c = l1 - d1
          # The light run before must be preceded by dark (ring), which holds
          # unless it starts the row segment.
          if b <= max && b >= min && a <= max && a >= min && c <= max && c >= min &&
             pos.positive? && row.getbyte(pos - 1) == 1
            yield (d0 + d1) >> 1
          end
          pos = d1
        end
      end

      # Vertical then horizontal cross-check through dark pixel (x, y).
      # Returns the refined centre [cx, cy] or nil.
      def confirm(x, y, module_size)
        bits = @bits
        w = @width
        h = @height
        max = module_size * 1.6 + 1
        min = module_size * 0.4 - 1
        # Vertical: dark centre, light above/below, dark ring beyond. The
        # walks stop just past the longest acceptable run, so a long dark
        # column (page border, large dark area) costs nothing extra.
        top = y
        top -= 1 while top > 0 && y - top <= max && bits.getbyte((top - 1) * w + x) == 1
        bottom = y
        bottom += 1 while bottom < h - 1 && bottom - y <= max && bits.getbyte((bottom + 1) * w + x) == 1
        centre_v = bottom - top + 1
        return if centre_v > max || centre_v < min

        lt = top - 1
        lt -= 1 while lt >= 0 && top - lt <= max + 1 && bits.getbyte(lt * w + x).zero?
        lb = bottom + 1
        lb += 1 while lb < h && lb - bottom <= max + 1 && bits.getbyte(lb * w + x).zero?
        return if lt.negative? || lb >= h

        light_top = top - lt - 1
        light_bottom = lb - bottom - 1
        return if light_top < min || light_top > max || light_bottom < min || light_bottom > max

        cy = (top + bottom + 1) * 0.5
        span_y = (lt + 1 + lb) * 0.5
        iy = cy.floor
        # Horizontal at the vertical centre.
        row = bits.byteslice(iy * w, w)
        return unless row.getbyte(x) == 1

        r0 = row.index(LIGHT, x) or return
        r1 = row.index(DARK, r0) or return
        l0 = row.rindex(LIGHT, x) or return
        l1 = row.rindex(DARK, l0) or return
        centre_h = r0 - l0 - 1
        return if centre_h > max || centre_h < min || r1 - r0 > max || l0 - l1 > max

        cx = (l0 + 1 + r0) * 0.5
        span_x = (l1 + 1 + r1) * 0.5
        [(cx + span_x) * 0.5, (cy + span_y) * 0.5]
      end

      # Number of cells of the 5x5 pattern centred at (x, y) that have the
      # wrong colour (out of 25), sampling along the module vectors.
      # Stops counting past MAX_MISMATCHES.
      def verify(x, y, ux, uy, vx, vy)
        bits = @bits
        w = @width
        h = @height
        wrong = dark_at?(bits, w, h, x, y) ? 0 : 1
        k = 0
        while k < 8
          i, j = LIGHT_RING[k]
          wrong += 1 if dark_at?(bits, w, h, x + i * ux + j * vx, y + i * uy + j * vy)
          k += 1
        end
        return wrong if wrong > MAX_MISMATCHES

        k = 0
        while k < 16
          i, j = DARK_RING[k]
          wrong += 1 unless dark_at?(bits, w, h, x + i * ux + j * vx, y + i * uy + j * vy)
          return wrong if wrong > MAX_MISMATCHES

          k += 1
        end
        wrong
      end

      def dark_at?(bits, w, h, x, y)
        x >= 0 && y >= 0 && x < w && y < h && bits.getbyte(y.to_i * w + x.to_i) == 1
      end
    end
  end
end
