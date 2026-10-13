# frozen_string_literal: true

require_relative "candidate/dimension"
require_relative "candidate/strokes"

module QrReader
  class Detector
    # A possible QR symbol located from three finder patterns.
    #
    # The geometry is estimated when the candidate is built
    # (Candidate.locate); sampling happens lazily in #bits and
    # #alternatives, so a reader that stops at the first decodable
    # candidate only pays for what it uses.
    #
    #   bits            - sampled N x N BitMatrix (1 = dark)
    #   points          - symbol corners [TL, TR, BR, BL] in pixel coordinates
    #   finder_patterns - finder centres [TL, TR, BL] (for debugging)
    #   alternatives    - Enumerator of further samplings to try when +bits+
    #                     does not decode, most promising first
    #   dimension       - estimated modules per side
    #
    # The module grid is mapped to the image by a homography through the
    # three finder centres and a fourth reference point at module
    # (d - 6.5, d - 6.5): the bottom-right alignment pattern if one was
    # found (mode :alignment), else the intersection of the finder ring
    # strokes that point there (:strokes); failing both, the parallelogram
    # corner at (d - 3.5, d - 3.5) is used (:parallelogram). Versions 7+ are
    # sampled piecewise along their alignment pattern grid (AlignmentGrid).
    class Candidate
      include Dimension
      include Strokes

      # Timing pattern agreement above which a grid counts as plausible.
      PLAUSIBLE_TIMING = 0.6

      attr_reader :dimension, :dimensions, :score, :tl, :tr, :bl, :module_size, :mode

      # The candidate for a PatternSets::Triple, or nil if the triple cannot
      # be a symbol.
      def self.locate(detector, triple)
        candidate = new(detector, triple)
        candidate.located? ? candidate : nil
      end

      def initialize(detector, triple)
        @detector = detector
        @matrix = detector.matrix
        @bl = triple.bl
        @tl = triple.tl
        @tr = triple.tr
        @score = triple.score
        @alignment = nil
        @stroke_point = nil
        @version_confirmed = false
        @transforms = {}
        @located = estimate_geometry
      end

      # False if the geometry is unusable (then nothing else may be called).
      def located?
        @located
      end

      # The most likely sampling of the symbol.
      def bits
        @bits ||= begin
          # Piecewise sampling costs an alignment pattern search per grid
          # point: only spend it on grids that look like a real symbol.
          piecewise = @dimension >= 45 && (@version_confirmed || promising?(@dimension, @mode))
          sample(@dimension, @mode, piecewise: piecewise)
        end
      end

      def finder_patterns
        [@tl.to_a, @tr.to_a, @bl.to_a]
      end

      # True if +pattern+ (a FinderPattern) is one of this candidate's finders.
      def uses?(pattern)
        pattern.equal?(@tl) || pattern.equal?(@tr) || pattern.equal?(@bl)
      end

      # Corners of the symbol as [[x, y], ...]: TL, TR, BR, BL.
      def points
        @points ||= begin
          t = transform_for(@dimension, @mode)
          d = @dimension
          [[0, 0], [d, 0], [d, d], [0, d]].map { |x, y| t.apply(x, y) || [Float::NAN, Float::NAN] }
        end
      end

      # Further samplings worth trying when #bits does not decode: the
      # global instead of the piecewise transform and the grayscale image
      # (if the detector has it) when #bits looks like a symbol at all, then
      # the other reference points and the other dimension estimates whose
      # timing patterns read plausibly.
      def alternatives
        return enum_for(:alternatives) unless block_given?

        seen = [bits]
        try = lambda do |matrix|
          next if matrix.nil? || seen.include?(matrix)

          seen << matrix
          yield matrix
        end
        d = @dimension
        if plausible?
          try.call(sample(d, @mode, piecewise: false)) if d >= 45
          try.call(sample(d, @mode, piecewise: true, luminance: true)) if @detector.image
          # The displacement field on an affine base suits bent surfaces,
          # on the full homography perspective plus bending.
          try.call(warped_sample(d, :parallelogram))
          try.call(warped_sample(d, @mode)) if @mode != :parallelogram
        end
        %i[alignment strokes parallelogram].each do |m|
          next if m == @mode || (m != :parallelogram && !reference(m))

          try.call(sample(d, m, piecewise: true)) if promising?(d, m)
        end
        # Other dimensions with the first reference point that suits them
        # (the alignment pattern may be a look-alike found for the first).
        @dimensions.drop(1).each do |other|
          mode = [@mode, :strokes, :parallelogram].uniq.find do |m|
            (m == :parallelogram || reference(m)) && promising?(other, m)
          end
          try.call(sample(other, mode, piecewise: true)) if mode
        end
        nil
      end

      # Fraction of the timing pattern modules of #bits (row and column 6
      # between the finders) with the expected colour: about 0.5 for false
      # finder triples and wrong dimensions, close to 1 for real symbols.
      def timing_quality
        @timing_quality ||= begin
          grid = bits
          d = grid.width
          good = 0
          i = 8
          while i <= d - 9
            expected = i.even? ? 1 : 0
            good += 1 if grid.get(i, 6) == expected
            good += 1 if grid.get(6, i) == expected
            i += 1
          end
          good.fdiv(2 * (d - 16))
        end
      end

      # True unless the primary grid's timing patterns look like noise.
      def plausible?
        timing_quality >= PLAUSIBLE_TIMING
      end

      # Cheap estimate of #plausible? that reads only the timing pattern
      # modules through the global transform (no full sampling). Symbols
      # whose version information confirmed the dimension count as likely
      # even when bending defeats the global transform (chance agreement of
      # an 18-bit version block with the measured dimension is rare).
      def likely?
        @likely = @version_confirmed || promising?(@dimension, @mode) if @likely.nil?
        @likely
      end

      # Identifies the finder pattern triple (for de-duplication by callers).
      def key
        [@tl, @tr, @bl].map { |p| [p.x.round, p.y.round] }
      end

      def inspect
        format("#<Candidate dim=%d mode=%s tl=(%.1f,%.1f) tr=(%.1f,%.1f) bl=(%.1f,%.1f) score=%.3f>",
               @dimension, @mode, @tl.x, @tl.y, @tr.x, @tr.y, @bl.x, @bl.y, @score)
      end

      private

      # Estimates module sizes, the dimension candidates, the bottom-right
      # reference point and, for versions 7+, the version. False if the
      # geometry is unusable.
      def estimate_geometry
        right = unit(@tr.x - @tl.x, @tr.y - @tl.y)
        down = unit(@bl.x - @tl.x, @bl.y - @tl.y)
        @axes = [right, down]
        # Module sizes of each finder along the symbol's axes.
        @tl_right = line_module_size(@tl, *right) || @tl.module_size
        @tl_down = line_module_size(@tl, *down) || @tl.module_size
        @tr_left = line_module_size(@tr, -right[0], -right[1]) || @tr.module_size
        @tr_down = line_module_size(@tr, *down) || @tr.module_size
        @bl_up = line_module_size(@bl, -down[0], -down[1]) || @bl.module_size
        @bl_right = line_module_size(@bl, *right) || @bl.module_size
        # Under a projective map the distance between two points is the
        # module distance times the geometric mean of the local scales at
        # both ends, hence geometric means.
        ms_top = Math.sqrt(@tl_right * @tr_left)
        ms_left = Math.sqrt(@tl_down * @bl_up)
        @module_size = (ms_top + ms_left) * 0.5
        top = @tl.distance(@tr) / ms_top + 7
        left = @tl.distance(@bl) / ms_left + 7
        estimate = (top + left) * 0.5
        return false unless estimate.finite? && estimate > 15 && estimate < 200

        @dimensions = dimension_candidates(estimate, top, left)
        return false if @dimensions.empty?

        @stroke_point = stroke_intersection
        locate_alignment(@dimensions.find { |d| d > 21 } || 25)
        @mode = if @alignment
                  :alignment
                elsif @stroke_point
                  :strokes
                else
                  :parallelogram
                end
        if (version_dim = version_dimension(@dimensions))
          @dimensions.delete(version_dim)
          @dimensions.unshift(version_dim)
        end
        @dimension = @dimensions.first
        !transform_for(@dimension, @mode).nil?
      end

      def unit(x, y)
        len = Math.hypot(x, y)
        len.zero? ? [0.0, 0.0] : [x / len, y / len]
      end

      # Looks for the bottom-right alignment pattern around its predicted
      # position (from the stroke intersection if known, else from the
      # parallelogram), verifying candidates with the local module vectors.
      def locate_alignment(dimension)
        t = (@stroke_point && transform_for(dimension, :strokes)) || parallelogram_transform(dimension)
        return unless t

        c = dimension - 6.5
        x, y = t.apply(c, c)
        x1, y1 = t.apply(c + 1, c)
        x2, y2 = t.apply(c, c + 1)
        return unless x && x1 && x2

        @alignment = @detector.alignment_finder.find(x, y, 8 * @module_size + 2, x1 - x, y1 - y, x2 - x, y2 - y)
      end

      # Pixel position of the reference point for +mode+ (nil if unknown).
      def reference(mode)
        case mode
        when :alignment then @alignment
        when :strokes then @stroke_point
        end
      end

      # Module-to-pixel transform for dimension d and reference +mode+;
      # nil if degenerate.
      def transform_for(d, mode)
        key = [d, mode]
        return @transforms[key] if @transforms.key?(key)

        ref = reference(mode)
        @transforms[key] =
          if ref
            c = d - 6.5
            checked(PerspectiveTransform.quad_to_quad(
                      [[3.5, 3.5], [d - 3.5, 3.5], [c, c], [3.5, d - 3.5]],
                      [@tl.to_a, @tr.to_a, ref, @bl.to_a]
                    ), d)
          else
            parallelogram_transform(d)
          end
      end

      def parallelogram_transform(d)
        br = [@tr.x - @tl.x + @bl.x, @tr.y - @tl.y + @bl.y]
        checked(PerspectiveTransform.quad_to_quad(
                  [[3.5, 3.5], [d - 3.5, 3.5], [d - 3.5, d - 3.5], [3.5, d - 3.5]],
                  [@tl.to_a, @tr.to_a, br, @bl.to_a]
                ), d)
      end

      # The transform if it is regular over the whole symbol (no fold or
      # point at infinity inside), else nil.
      def checked(t, d)
        t if t&.regular_over?(0, 0, d, d)
      end

      # Bit at continuous pixel position (x, y), 0 outside the image.
      def pixel(x, y)
        return 0 unless x >= 0 && y >= 0 && x < @matrix.width && y < @matrix.height

        @matrix.bits.getbyte(y.to_i * @matrix.width + x.to_i)
      end

      # Bit of module (mx, my) under transform t (0 when outside the image).
      def module_at(t, mx, my)
        x, y = t.apply(mx + 0.5, my + 0.5)
        x ? pixel(x, y) : 0
      end

      # Fraction of the timing pattern modules (row and column 6 between the
      # finder patterns) that read as expected under the transform for d.
      # Wrong dimensions and false finder triples score about 0.5.
      def timing_score(d, mode)
        t = transform_for(d, mode) or return 0.0
        good = 0
        i = 8
        while i <= d - 9
          expected = i.even? ? 1 : 0
          good += 1 if module_at(t, i, 6) == expected
          good += 1 if module_at(t, 6, i) == expected
          i += 1
        end
        good.fdiv(2 * (d - 16))
      end

      # Cheap check whether sampling dimension d with +mode+ is worthwhile.
      def promising?(d, mode)
        timing_score(d, mode) >= PLAUSIBLE_TIMING
      end

      # Samples dimension d through the transform for +mode+ plus a pixel
      # displacement field measured on the timing patterns: where row 6's
      # (column 6's) module boundaries really are, compared to where the
      # transform puts them, gives a displacement per module column (row);
      # module (x, y) is shifted by the sum of its column's and its row's
      # displacement. This follows symbols on curved surfaces (bottles,
      # cans, fabric) whose stretch a homography cannot express. nil if a
      # timing pattern cannot be traced.
      def warped_sample(d, mode)
        t = transform_for(d, mode) or return
        cols = timing_shift(t, d, :row, 6.5) or return
        # Trace column 6 where the row displacement says it is.
        rows = timing_shift(t, d, :column, 6.5 + timing_offset(t, cols[6], 6.5, 6.5)) or return
        GridSampler.sample_warped(@matrix, d, t, cols, rows, offset: GridSampler.vote_offsets(t, d))
      end

      # Per module column (+axis+ :row, tracing timing row 6 at module
      # coordinate +across+) or row (:column) the pixel displacement [dx, dy]
      # between where the timing pattern's module boundaries are and where
      # the transform puts them. The pattern is sampled through +t+ at 1/8
      # module steps from inside one finder ring to inside the other; its
      # d - 13 boundaries (7 .. d - 7) are matched in order with the
      # observed colour changes. Displacements are interpolated linearly
      # (0 at the finder centres, which anchor the transform). nil unless
      # exactly the expected number of boundaries is seen.
      def timing_shift(t, d, axis, across)
        step = 0.125
        observed = []
        previous = nil
        u = 4.0
        stop = d - 4.0
        while u <= stop
          x, y = axis == :row ? t.apply(u, across) : t.apply(across, u)
          bit = x ? pixel(x, y) : 0
          observed << u - step * 0.5 if previous && bit != previous
          previous = bit
          u += step
        end
        return unless observed.size == d - 13

        point = ->(c) { axis == :row ? t.apply(c, across) : t.apply(across, c) }
        knots = [[3.5, 0.0, 0.0]]
        observed.each_with_index do |o, i|
          nominal = point.call(7 + i) or return
          actual = point.call(o) or return
          knots << [7 + i, actual[0] - nominal[0], actual[1] - nominal[1]]
        end
        knots << [d - 3.5, 0.0, 0.0]
        Array.new(d) { |i| interpolate(knots, i + 0.5) }
      end

      # Module-space offset along +axis+ equivalent to a pixel shift at
      # module (u, v): used to find where a timing line really runs.
      def timing_offset(t, shift, u, v, axis = :row)
        p0 = t.apply(u, v) or return 0.0
        p1 = axis == :row ? t.apply(u + 1, v) : t.apply(u, v + 1)
        return 0.0 unless p1

        ax = p1[0] - p0[0]
        ay = p1[1] - p0[1]
        len2 = ax * ax + ay * ay
        len2.zero? ? 0.0 : (shift[0] * ax + shift[1] * ay) / len2
      end

      # Piecewise linear interpolation of [dx, dy] in knots sorted by x
      # ([[x, dx, dy], ...]), extrapolating the end segments.
      def interpolate(knots, x)
        i = if x <= knots.first[0]
              1
            elsif x >= knots.last[0]
              knots.size - 1
            else
              knots.bsearch_index { |k| k[0] >= x }
            end
        x0, ax, ay = knots[i - 1]
        x1, bx, by = knots[i]
        f = (x - x0) / (x1 - x0)
        [ax + (bx - ax) * f, ay + (by - ay) * f]
      end

      # Piecewise sampling regions for dimension d (versions 7+), memoized.
      def regions(d, mode)
        return if d < 45

        @regions ||= {}
        key = [d, mode]
        return @regions[key] if @regions.key?(key)

        t = transform_for(d, mode)
        @regions[key] = t && AlignmentGrid.new(@detector, t, d, @module_size, ->(n) { finder_corners(n) }).regions
      end

      # Samples the grid for dimension d: piecewise along the alignment
      # pattern grid for versions 7+ if requested; from the grayscale image
      # with module-level thresholds if +luminance+, else from the binarized
      # image (majority of five pixels per module along each axis in which
      # modules span 3+ px).
      def sample(d, mode, piecewise:, luminance: false)
        t = transform_for(d, mode) or return
        pieces = (regions(d, mode) if piecewise) || GridSampler.whole(d, t)
        offset = GridSampler.vote_offsets(t, d)
        if luminance
          image = @detector.image or return
          GridSampler.sample_luminance(image, d, pieces, @module_size, inverted: @detector.inverted_image?,
                                                                       offset: offset)
        else
          GridSampler.sample(@matrix, d, pieces, offset: offset)
        end
      end
    end
  end
end
