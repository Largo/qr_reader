# frozen_string_literal: true

module QrReader
  module Formats
    module PDF
      # Filled and stroked paths of a page, collected while its content
      # stream is scanned, so that QR codes drawn as vector graphics (one
      # rectangle per module or run of modules, as most PDF generators do)
      # can be rasterized; also the glyphs of text set in a barcode font
      # (see ContentScanner#text_operator). Shadings and clipping are
      # ignored; colours are reduced to luminance.
      class PathCollector
        # Most subpaths (and points) kept per page; the rest is ignored.
        MAX_SUBPATHS = 50_000
        MAX_POINTS = 400_000
        # Line segments a Bézier curve is flattened into.
        CURVE_STEPS = 4
        OPERATORS = %w[m l c v y h re f F f* B B* b b* S s n w J g G rg RG k K cs CS sc scn SC SCN]
                    .to_h { |op| [op, true] }.freeze

        # A painted path in page space (points, y up): +polys+ are flat
        # [x0, y0, x1, y1, ...] Arrays, +luma+ the paint's luminance.
        # +union+: each polygon is painted on its own (stroke outlines).
        Shape = Struct.new(:polys, :luma, :even_odd, :union, :bbox)
        # Paint and text state saved by q / Q.
        State = Struct.new(:fill_space, :fill_luma, :stroke_space, :stroke_luma, :line_width, :line_cap,
                           :font, :font_size, :char_spacing, :word_spacing, :scaling, :leading, :rise, :render)

        attr_reader :shapes, :state

        def initialize(doc, resources)
          @doc = doc
          @resources = resources
          @shapes = []
          @state = State.new(ColorSpace::GRAY, 0, ColorSpace::GRAY, 0, 1.0, 0,
                             nil, 0.0, 0.0, 0.0, 100.0, 0.0, 0.0, 0)
          @stack = []
          @polys = []
          @current = nil
          @closed = []
          @subpaths = 0
          @points = 0
        end

        def self.operator?(token)
          OPERATORS[token]
        end

        def save
          @stack << @state.dup if @stack.size < ContentScanner::MAX_STACK
        end

        def restore
          @state = @stack.pop || @state
        end

        # Runs a path or colour operator with its +operands+ (Strings)
        # under the transformation +ctm+.
        def operator(token, operands, ctm, resources)
          return if @broken

          case token
          when "m" then move(operands, ctm)
          when "l" then line(operands, ctm)
          when "c" then curve(operands, ctm, 6)
          when "v", "y" then curve(operands, ctm, 4, token)
          when "h" then @closed[@polys.size - 1] = true if @current
          when "re" then rectangle(operands, ctm)
          when "f", "F" then paint(ctm, fill: true)
          when "f*" then paint(ctm, fill: true, even_odd: true)
          when "B", "b" then paint(ctm, fill: true, stroke: true, close: token == "b")
          when "B*", "b*" then paint(ctm, fill: true, even_odd: true, stroke: true, close: token == "b*")
          when "S", "s" then paint(ctm, stroke: true, close: token == "s")
          when "n" then clear
          when "w" then @state.line_width = number(operands.last) || @state.line_width
          when "J" then @state.line_cap = number(operands.last)&.to_i || @state.line_cap
          when "g", "rg", "k" then set_device(operands, token, fill: true)
          when "G", "RG", "K" then set_device(operands, token.downcase, fill: false)
          when "cs" then set_space(operands, resources, fill: true)
          when "CS" then set_space(operands, resources, fill: false)
          when "sc", "scn" then set_color(operands, fill: true)
          when "SC", "SCN" then set_color(operands, fill: false)
          end
        rescue *INTERNAL_ERRORS
          # Garbage operands: give up on this page's paths, keep its images.
          @broken = true
          clear
        end

        # Paints glyph outline +polys+ (text space) placed by +matrix+ with
        # the colour of the text rendering mode.
        def add_glyph(polys, matrix)
          return if @broken

          luma = [1, 5].include?(@state.render) ? @state.stroke_luma : @state.fill_luma
          points = polys.sum(&:size) / 2
          return unless luma && @subpaths + polys.size <= MAX_SUBPATHS && @points + points <= MAX_POINTS

          @subpaths += polys.size
          @points += points
          a, b, c, d, e, f = matrix
          placed = polys.map do |p|
            q = Array.new(p.size)
            i = 0
            while i < p.size
              x = p[i]
              y = p[i + 1]
              q[i] = a * x + c * y + e
              q[i + 1] = b * x + d * y + f
              i += 2
            end
            q
          end
          add_shape(placed, luma, false, false)
        end

        private

        def number(token)
          return nil unless token.is_a?(String) && !token.start_with?("/")

          value = token.to_f
          value.finite? ? value : nil
        end

        def numbers(operands, n)
          return nil if operands.size < n

          values = operands.last(n).map { |t| number(t) }
          values.include?(nil) ? nil : values
        end

        def room?(points)
          @subpaths < MAX_SUBPATHS && @points + points <= MAX_POINTS
        end

        def move(operands, ctm)
          values = numbers(operands, 2) or return
          x, y = values
          @user = [x, y]
          return @current = nil unless room?(1)

          @current = transform(ctm, x, y)
          @polys << @current
          @subpaths += 1
          @points += 1
        end

        def line(operands, ctm)
          values = numbers(operands, 2) or return
          x, y = values
          add_point(ctm, x, y)
        end

        def add_point(ctm, x, y)
          @user = [x, y]
          return unless @current && room?(1)

          @current << ctm[0] * x + ctm[2] * y + ctm[4] << ctm[1] * x + ctm[3] * y + ctm[5]
          @points += 1
        end

        # c (6 operands), v (current point is the first control point) and
        # y (the end point is the second one). Curves are only painted (a
        # module is never curved), so a coarse flattening does.
        def curve(operands, ctm, n, kind = nil)
          values = numbers(operands, n) or return
          return unless @user

          x0, y0 = @user
          x1, y1, x2, y2, x3, y3 = case kind
                                   when "v" then [x0, y0, *values]
                                   when "y" then [values[0], values[1], values[2], values[3], values[2], values[3]]
                                   else values
                                   end
          @user = [x3, y3]
          return unless @current && room?(CURVE_STEPS)

          current = @current
          a, b, c, d, e, f = ctm
          i = 1
          while i <= CURVE_STEPS
            t = i.to_f / CURVE_STEPS
            u = 1 - t
            k0 = u * u * u
            k1 = 3 * u * u * t
            k2 = 3 * u * t * t
            k3 = t * t * t
            x = k0 * x0 + k1 * x1 + k2 * x2 + k3 * x3
            y = k0 * y0 + k1 * y1 + k2 * y2 + k3 * y3
            current << a * x + c * y + e << b * x + d * y + f
            i += 1
          end
          @points += CURVE_STEPS
        end

        def rectangle(operands, ctm)
          values = numbers(operands, 4) or return
          x, y, w, h = values
          @user = [x, y]
          return @current = nil unless room?(4)

          poly = transform(ctm, x, y)
          poly.concat(transform(ctm, x + w, y), transform(ctm, x + w, y + h), transform(ctm, x, y + h))
          @polys << poly
          @closed[@polys.size - 1] = true
          @current = nil
          @subpaths += 1
          @points += 4
        end

        def transform(ctm, x, y)
          a, b, c, d, e, f = ctm
          [a * x + c * y + e, b * x + d * y + f]
        end

        def clear
          @polys = []
          @closed = []
          @current = nil
        end

        def paint(ctm, fill: false, even_odd: false, stroke: false, close: false)
          polys = @polys
          closed = @closed
          clear
          if fill && @state.fill_luma
            areas = polys.select { |p| p.size >= 6 }
            add_shape(areas, @state.fill_luma, even_odd, false) unless areas.empty?
          end
          return unless stroke && @state.stroke_luma

          a, b, c, d = ctm
          width = @state.line_width * Math.sqrt((a * d - b * c).abs)
          width = 0.25 if width < 0.25 # zero width: the thinnest line the device can draw
          capped = @state.line_cap != 0
          outlines = []
          polys.each_with_index do |poly, i|
            stroke_outline(poly, close || closed[i], width / 2, capped, outlines)
          end
          add_shape(outlines, @state.stroke_luma, false, true) unless outlines.empty?
        end

        # One quadrilateral per segment of +poly+. Segments are extended by
        # half the line width where they meet (which fills the corners of
        # right-angled joins) and at the ends of open paths unless they have
        # butt caps.
        def stroke_outline(poly, closed, half, capped, out)
          n = poly.size / 2
          if capped && poly.each_slice(2).uniq.size == 1
            # A zero-length path is a dot (a square, for round caps too).
            x, y = poly
            out << [x - half, y - half, x + half, y - half, x + half, y + half, x - half, y + half]
            return
          end

          segments = closed && n > 2 ? n : n - 1
          s = 0
          while s < segments
            x0 = poly[2 * s]
            y0 = poly[2 * s + 1]
            j = (s + 1) % n
            x1 = poly[2 * j]
            y1 = poly[2 * j + 1]
            length = Math.hypot(x1 - x0, y1 - y0)
            if length.positive?
              ux = (x1 - x0) / length * half
              uy = (y1 - y0) / length * half
              start = closed || capped || s.positive? ? 1 : 0
              stop = closed || capped || s < segments - 1 ? 1 : 0
              ax = x0 - ux * start
              ay = y0 - uy * start
              bx = x1 + ux * stop
              by = y1 + uy * stop
              out << [ax - uy, ay + ux, bx - uy, by + ux, bx + uy, by - ux, ax + uy, ay - ux]
            end
            s += 1
          end
        end

        def add_shape(polys, luma, even_odd, union)
          x0 = y0 = Float::INFINITY
          x1 = y1 = -Float::INFINITY
          polys.each do |p|
            i = 0
            while i < p.size
              x = p[i]
              y = p[i + 1]
              x0 = x if x < x0
              x1 = x if x > x1
              y0 = y if y < y0
              y1 = y if y > y1
              i += 2
            end
          end
          return unless x0.finite? && x1.finite? && y0.finite? && y1.finite?

          @shapes << Shape.new(polys, luma, even_odd, union, [x0, y0, x1, y1])
        end

        def set_device(operands, kind, fill:)
          values = numbers(operands, { "g" => 1, "rg" => 3, "k" => 4 }.fetch(kind)) or return
          space = { "g" => ColorSpace::GRAY, "rg" => ColorSpace::RGB, "k" => ColorSpace::CMYK }.fetch(kind)
          store(fill, space, luma(space, values))
        end

        def set_space(operands, resources, fill:)
          name = operands.last
          return unless name.is_a?(String) && name.start_with?("/")

          symbol = Parser.name_symbol(name)
          space = begin
            symbol == :Pattern ? nil : ColorSpace.build(@doc, symbol, resources || @resources)
          rescue Error, *INTERNAL_ERRORS
            nil
          end
          # The initial colour: black (gray, RGB, CMYK, Lab), full ink
          # (Separation, DeviceN) or the first palette entry.
          initial = space && (%i[separation device_n].include?(space.kind) ? [1.0] * space.components : nil)
          store(fill, space, space && luma(space, initial || default_color(space)))
        end

        def default_color(space)
          space.kind == :cmyk ? [0.0, 0.0, 0.0, 1.0] : [0.0] * space.components
        end

        def set_color(operands, fill:)
          space = fill ? @state.fill_space : @state.stroke_space
          if space.nil? || operands.last.to_s.start_with?("/") # pattern
            store(fill, space, nil)
            return
          end

          values = numbers(operands, space.components) or return
          store(fill, space, luma(space, values))
        end

        def store(fill, space, luma)
          if fill
            @state.fill_space = space
            @state.fill_luma = luma
          else
            @state.stroke_space = space
            @state.stroke_luma = luma
          end
        end

        # Luminance (0..255) of colour component +values+ (0..1; palette
        # index for Indexed; L* 0..100 for Lab).
        def luma(space, values)
          case space.kind
          when :indexed then space.luma_lut(8, nil)[values[0].round.clamp(0, 255)]
          when :lab then (values[0] * 2.55).round.clamp(0, 255)
          else space.luma_at(values.map { |v| (v * 255).round.clamp(0, 255) }.pack("C*"), 0)
          end
        rescue Error, *INTERNAL_ERRORS
          nil
        end
      end

      # Finds groups of small shapes that could be a QR code and renders
      # each group to an Image (white background, painter's order).
      module VectorRenderer
        # A subpath is a possible module (or run of modules) when its
        # shorter side is at most this many points ...
        MAX_MODULE = 12.0
        # ... and its longer side at most this (a QR-bill code is 130 pt).
        MAX_RUN = 300.0
        # Fewest possible modules in a group worth rendering, and the least
        # part of its area they cover (dark modules cover about half of a
        # code; table rules and text much less).
        MIN_SHAPES = 20
        MIN_COVERAGE = 0.2
        # Groups rendered per page, and their size limits in pixels.
        MAX_GROUPS = 16
        MAX_SIDE = 3000
        # Pixels per module aimed at, and the quiet zone added (in modules).
        PIXELS_PER_MODULE = 4.0
        MARGIN_MODULES = 4.0
        # Cells of the grid that groups are found on (per longer side).
        GRID_CELLS = 1500

        # A group of shapes: bounding box (page space) and module estimate.
        Group = Struct.new(:x0, :y0, :x1, :y1, :count, :sides, :area)

        module_function

        # [[Image, dpi], ...] for the groups of +shapes+.
        def images(shapes)
          groups(shapes).first(MAX_GROUPS).filter_map { |group| render_group(shapes, group) }
        end

        # Groups of nearby small subpaths (each grown by its shorter side,
        # so that modules one light module apart still touch).
        def groups(shapes)
          boxes = candidate_boxes(shapes)
          return [] if boxes.size < MIN_SHAPES

          gx0 = boxes.map { |b| b[0] }.min
          gy0 = boxes.map { |b| b[1] }.min
          gx1 = boxes.map { |b| b[2] }.max
          gy1 = boxes.map { |b| b[3] }.max
          cell = [[gx1 - gx0, gy1 - gy0].max / GRID_CELLS, 0.5].max
          cols = ((gx1 - gx0) / cell).ceil + 1
          rows = ((gy1 - gy0) / cell).ceil + 1
          grid = Array.new(rows) { "\0".b * cols }
          boxes.each do |b|
            c0 = ((b[0] - gx0) / cell).floor
            c1 = ((b[2] - gx0) / cell).floor
            fill = "\1".b * (c1 - c0 + 1)
            r = ((b[1] - gy0) / cell).floor
            r1 = ((b[3] - gy0) / cell).floor
            while r <= r1
              grid[r].bytesplice(c0, fill.bytesize, fill)
              r += 1
            end
          end
          components(grid, boxes, gx0, gy0, cell)
        end

        # Grown bounding boxes [x0, y0, x1, y1, side, area] of possible
        # modules: small polygons with right angles only (rectangles, runs,
        # outlines of module groups) and dots (round or rounded modules).
        # Glyph outlines are rarely either.
        def candidate_boxes(shapes)
          boxes = []
          shapes.each do |shape|
            shape.polys.each do |p|
              x0 = x1 = p[0]
              y0 = y1 = p[1]
              i = 2
              while i < p.size
                x = p[i]
                y = p[i + 1]
                x0 = x if x < x0
                x1 = x if x > x1
                y0 = y if y < y0
                y1 = y if y > y1
                i += 2
              end
              w = x1 - x0
              h = y1 - y0
              side = w < h ? w : h
              long = w < h ? h : w
              next unless side.positive? && side <= MAX_MODULE && long <= MAX_RUN && (rectilinear?(p) || dot?(p, w, h))

              boxes << [x0 - side, y0 - side, x1 + side, y1 + side, side, area(p)]
            end
          end
          boxes
        end

        # True if polygon +p+ could be (part of) a module: right-angled or a
        # dot (see #candidate_boxes; size is not checked).
        def module_shape?(p)
          return false if p.size < 6

          xs = p.each_slice(2).map(&:first)
          ys = p.each_slice(2).map(&:last)
          rectilinear?(p) || dot?(p, xs.max - xs.min, ys.max - ys.min)
        end

        # True if every edge of polygon +p+ is parallel or perpendicular to
        # its first one.
        def rectilinear?(p)
          n = p.size / 2
          ux = uy = nil
          k = 0
          while k < n
            j = k + 1 == n ? 0 : k + 1
            dx = p[2 * j] - p[2 * k]
            dy = p[2 * j + 1] - p[2 * k + 1]
            length = Math.hypot(dx, dy)
            if length > 1e-9
              if ux
                tolerance = 0.02 * length
                return false unless (dx * uy - dy * ux).abs <= tolerance || (dx * ux + dy * uy).abs <= tolerance
              else
                ux = dx / length
                uy = dy / length
              end
            end
            k += 1
          end
          !ux.nil?
        end

        # True if polygon +p+ (+w+ x +h+) is a dot: about as wide as high,
        # convex, and filling 60 to 100 % of its bounding box (a circle
        # fills 79 %, a square with rounded corners more).
        def dot?(p, w, h)
          return false if p.size < 12 || w > 1.25 * h || h > 1.25 * w
          return false unless area(p).between?(0.6 * w * h, 1.0 * w * h)

          convex?(p)
        end

        # True if polygon +p+ turns the same way at every corner.
        def convex?(p)
          n = p.size / 2
          sign = 0
          k = 0
          while k < n
            j = (k + 1) % n
            l = (k + 2) % n
            cross = (p[2 * j] - p[2 * k]) * (p[2 * l + 1] - p[2 * j + 1]) -
                    (p[2 * j + 1] - p[2 * k + 1]) * (p[2 * l] - p[2 * j])
            if cross.abs > 1e-9
              s = cross.positive? ? 1 : -1
              return false if sign != 0 && s != sign

              sign = s
            end
            k += 1
          end
          sign != 0
        end

        # Area of polygon +p+ (shoelace formula).
        def area(p)
          n = p.size / 2
          sum = 0.0
          k = 0
          while k < n
            j = k + 1 == n ? 0 : k + 1
            sum += p[2 * k] * p[2 * j + 1] - p[2 * j] * p[2 * k + 1]
            k += 1
          end
          sum.abs / 2
        end

        # Connected regions of the grid (runs of marked cells joined row by
        # row with a union-find), with the boxes whose centre lies in them;
        # largest first.
        def components(grid, boxes, gx0, gy0, cell)
          parent = []
          find = lambda do |i|
            i = parent[i] = parent[parent[i]] while parent[i] != i
            i
          end
          runs_by_row = []
          extent = [] # per run: [c0, c1, row]
          previous = []
          grid.each_with_index do |row, r|
            runs = []
            c = 0
            p = 0 # first run of the previous row that may still touch
            while (start = row.index("\1", c))
              stop = row.index("\0", start) || row.bytesize
              id = parent.size
              parent << id
              extent << [start, stop - 1, r]
              p += 1 while p < previous.size && extent[previous[p]][1] < start
              q = p
              while q < previous.size && extent[previous[q]][0] < stop
                a = find.call(previous[q])
                b = find.call(id)
                parent[a] = b if a != b
                q += 1
              end
              runs << id
              c = stop
            end
            runs_by_row << runs
            previous = runs
          end

          groups = {}
          extent.each_with_index do |(c0, c1, r), id|
            g = groups[find.call(id)] ||= Group.new(c0, r, c1, r, 0, [], 0.0)
            g.x0 = c0 if c0 < g.x0
            g.x1 = c1 if c1 > g.x1
            g.y0 = r if r < g.y0
            g.y1 = r if r > g.y1
          end
          boxes.each do |b|
            side = b[4]
            cx = (((b[0] + b[2]) / 2 - gx0) / cell).floor
            r = (((b[1] + b[3]) / 2 - gy0) / cell).floor
            id = runs_by_row[r]&.bsearch { |rid| extent[rid][1] >= cx } or next
            next if extent[id][0] > cx

            g = groups[find.call(id)]
            g.count += 1
            g.sides << side
            g.area += b[5]
          end
          found = groups.values.select { |g| g.count >= MIN_SHAPES }.filter_map do |g|
            # Back to page space, without the growth by one module.
            m = module_size(g.sides)
            group = Group.new(gx0 + g.x0 * cell + m, gy0 + g.y0 * cell + m, gx0 + (g.x1 + 1) * cell - m,
                              gy0 + (g.y1 + 1) * cell - m, g.count, g.sides, g.area)
            box = (group.x1 - group.x0) * (group.y1 - group.y0)
            group if box.positive? && group.area >= MIN_COVERAGE * box
          end
          found.sort_by { |g| -g.count }
        end

        # A low percentile of the shorter sides: single modules (runs and
        # finder pattern rings are longer, hairlines are rare).
        def module_size(sides)
          sorted = sides.sort
          sorted[sorted.size / 4]
        end

        def render_group(shapes, group)
          m = module_size(group.sides)
          w = group.x1 - group.x0
          h = group.y1 - group.y0
          return nil unless w.positive? && h.positive?
          # A code is about square; long thin groups are text lines or rules.
          return nil if w > 4 * h || h > 4 * w

          margin = MARGIN_MODULES * m
          x0 = group.x0 - margin
          y0 = group.y0 - margin
          x1 = group.x1 + margin
          y1 = group.y1 + margin
          scale = PIXELS_PER_MODULE / m
          longest = [x1 - x0, y1 - y0].max
          scale = MAX_SIDE / longest if longest * scale > MAX_SIDE
          width = ((x1 - x0) * scale).ceil
          height = ((y1 - y0) * scale).ceil
          return nil if width < 21 || height < 21

          [rasterize(shapes, x0, y1, x1, y0, scale, width, height, m), (scale * 72).round(2)]
        end

        # Paints +shapes+ inside the page rectangle (left, top, right,
        # bottom) at +scale+ pixels per point onto a white Image. Dots of
        # about the module size +m+ are painted as whole modules, so that
        # codes drawn with round modules (finder patterns too) read like
        # ordinary ones.
        def rasterize(shapes, left, top, right, bottom, scale, width, height, m)
          data = "\xFF".b * (width * height)
          inside = shapes.select do |shape|
            bx0, by0, bx1, by1 = shape.bbox
            bx1 >= left && bx0 <= right && by1 >= bottom && by0 <= top
          end
          dots = dot_centers(inside, m)
          r = dot_pitch(dots.values, m) / 2
          inside.each do |shape|
            polys = shape.polys.map do |p|
              next p unless (cx, cy = dots[p])

              [cx - r, cy - r, cx + r, cy - r, cx + r, cy + r, cx - r, cy + r]
            end
            to_pixels = polys.map do |p|
              q = Array.new(p.size)
              i = 0
              while i < p.size
                q[i] = (p[i] - left) * scale
                q[i + 1] = (top - p[i + 1]) * scale
                i += 2
              end
              q
            end
            chr = shape.luma.chr
            if shape.union || to_pixels.size == 1
              to_pixels.each { |q| fill_polygons([q], false, chr, data, width, height) }
            else
              fill_polygons(to_pixels, shape.even_odd, chr, data, width, height)
            end
          end
          Image.new(width, height, data)
        end

        # Centres of the dots (0.5 to 1.2 modules +m+ wide) of filled
        # +shapes+, by polygon (compared by identity).
        def dot_centers(shapes, m)
          centers = {}.compare_by_identity
          shapes.each do |shape|
            next if shape.union

            shape.polys.each do |p|
              xs = p.each_slice(2).map(&:first)
              ys = p.each_slice(2).map(&:last)
              w = xs.max - xs.min
              h = ys.max - ys.min
              next unless w.between?(0.5 * m, 1.2 * m) && h.between?(0.5 * m, 1.2 * m) && dot?(p, w, h)

              centers[p] = [(xs.max + xs.min) / 2, (ys.max + ys.min) / 2]
            end
          end
          centers
        end

        # Distance between neighbouring dot columns and rows (dots are a
        # bit smaller than the modules they stand for): the median step
        # between distinct centre coordinates, within 0.9 to 2 modules +m+.
        def dot_pitch(centers, m)
          steps = []
          [0, 1].each do |axis|
            previous = nil
            centers.map { |c| c[axis] }.sort.each do |v|
              next if previous && v - previous < 0.25 * m

              steps << v - previous if previous
              previous = v
            end
          end
          return m if steps.empty?

          steps.sort[steps.size / 2].clamp(0.9 * m, 2.0 * m)
        end

        # Scanline fill (pixel centres) of +polys+ with the nonzero or
        # even-odd rule; axis-aligned rectangles take a shortcut.
        def fill_polygons(polys, even_odd, chr, data, width, height)
          return fill_rect(polys[0], chr, data, width, height) if polys.size == 1 && rect?(polys[0])

          edges = []
          polys.each do |q|
            n = q.size / 2
            next if n < 3

            k = 0
            while k < n
              xa = q[2 * k]
              ya = q[2 * k + 1]
              j = k + 1 == n ? 0 : k + 1
              xb = q[2 * j]
              yb = q[2 * j + 1]
              if ya != yb
                edges << (ya < yb ? [ya, yb, xa, (xb - xa) / (yb - ya), 1] : [yb, ya, xb, (xa - xb) / (ya - yb), -1])
              end
              k += 1
            end
          end
          return if edges.empty?

          edges.sort_by!(&:first)
          r = (edges.first[0] - 0.5).ceil
          r = 0 if r.negative?
          last = (edges.map { |e| e[1] }.max - 0.5).ceil - 1
          last = height - 1 if last >= height
          active = []
          next_edge = 0
          crossings = []
          while r <= last
            yc = r + 0.5
            while next_edge < edges.size && edges[next_edge][0] <= yc
              active << edges[next_edge]
              next_edge += 1
            end
            active.reject! { |e| e[1] <= yc }
            crossings.clear
            active.each { |e| crossings << [e[2] + (yc - e[0]) * e[3], e[4]] if e[0] <= yc }
            crossings.sort_by!(&:first)
            winding = 0
            i = 0
            while i < crossings.size - 1
              winding += even_odd ? 1 : crossings[i][1]
              inside = even_odd ? winding.odd? : winding != 0
              span(crossings[i][0], crossings[i + 1][0], r, chr, data, width) if inside
              i += 1
            end
            r += 1
          end
        end

        def rect?(q)
          return false unless q.size == 8

          (q[0] == q[2] && q[3] == q[5] && q[4] == q[6] && q[7] == q[1]) ||
            (q[1] == q[3] && q[2] == q[4] && q[5] == q[7] && q[6] == q[0])
        end

        def fill_rect(q, chr, data, width, height)
          xs = [q[0], q[2], q[4], q[6]]
          ys = [q[1], q[3], q[5], q[7]]
          r = (ys.min - 0.5).ceil
          r = 0 if r.negative?
          stop = (ys.max - 0.5).ceil - 1
          stop = height - 1 if stop >= height
          xa = xs.min
          xb = xs.max
          while r <= stop
            span(xa, xb, r, chr, data, width)
            r += 1
          end
        end

        # Pixels of row +r+ whose centres lie in [xa, xb).
        def span(xa, xb, r, chr, data, width)
          c0 = (xa - 0.5).ceil
          c1 = (xb - 0.5).ceil - 1
          c0 = 0 if c0.negative?
          c1 = width - 1 if c1 >= width
          return if c1 < c0

          data.bytesplice(r * width + c0, c1 - c0 + 1, chr * (c1 - c0 + 1))
        end
      end

      private_constant :PathCollector, :VectorRenderer
    end
  end
end
