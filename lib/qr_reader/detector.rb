# frozen_string_literal: true

require_relative "binarizer"
require_relative "detector/geometry"
require_relative "detector/finder_pattern"
require_relative "detector/finder_pattern_finder"
require_relative "detector/pattern_sets"
require_relative "detector/perspective_transform"
require_relative "detector/grid_sampler"
require_relative "detector/alignment_pattern_finder"
require_relative "detector/alignment_grid"
require_relative "detector/candidate"
require_relative "detector/pure_detector"

module QrReader
  # Locates QR symbols in a binarized image and samples their module grids.
  #
  #   detector = QrReader::Detector.new(QrReader::Binarizer.hybrid(image), image: image)
  #   detector.each_candidate do |candidate|
  #     result = QrReader::Decoder.decode(candidate.bits) ||
  #              candidate.alternatives.lazy.filter_map { |bits| QrReader::Decoder.decode(bits) }.first
  #     break result if result
  #   end
  #
  # Candidates are produced lazily, most likely first: finder patterns are
  # searched once per mode and cached; every plausible triple of them is
  # scored (PatternSets) and turned into a Candidate whose module grid is
  # only sampled when asked for.
  class Detector
    # Finder pattern triples tried per mode.
    FAST_TRIPLES = 12
    HARD_TRIPLES = 40
    MULTI_TRIPLES = 120

    attr_reader :matrix, :image

    # Fast path for clean axis-aligned symbols (see PureDetector);
    # returns a candidate or nil.
    def self.detect_pure(matrix)
      PureDetector.detect(matrix)
    end

    # +matrix+ - binarized image (BitMatrix, 1 = dark)
    # +image+  - the grayscale Image it came from (optional)
    def initialize(matrix, image: nil)
      @matrix = matrix
      @image = image
      @finder = FinderPatternFinder.new(matrix)
      @confirmed = []
    end

    # Yields Candidates, most likely first (Enumerator without a block).
    # try_harder: scan every row and try more finder pattern triples.
    # multi: try all triples, skipping those that share a finder pattern
    # with (or lie inside) a candidate passed to #confirm.
    def each_candidate(try_harder: false, multi: false)
      return enum_for(:each_candidate, try_harder: try_harder, multi: multi) unless block_given?

      limit = if multi
                MULTI_TRIPLES
              else
                try_harder ? HARD_TRIPLES : FAST_TRIPLES
              end
      # Candidates whose timing patterns read like noise (false finder
      # triples, mostly) are deferred until all others were tried. With
      # multi, those spanning other finder patterns (triples mixing several
      # symbols) are dropped.
      patterns = finder_patterns(try_harder: try_harder)
      deferred = []
      PatternSets.generate(patterns, limit).each do |triple|
        next if multi && confirmed?(triple)

        candidate = Candidate.locate(self, triple) or next
        if candidate.likely?
          yield candidate
        elsif !multi || !spans_others?(candidate, patterns)
          deferred << candidate
        end
      end
      deferred.each { |candidate| yield candidate unless multi && confirmed?(candidate) }
      nil
    end

    # Records that +candidate+ decoded, so that multi-symbol detection skips
    # triples that reuse its finder patterns or lie inside it.
    def confirm(candidate)
      @confirmed << candidate
    end

    # Finder patterns found in the image (cached per mode).
    def finder_patterns(try_harder: false)
      @finder.find(try_harder: try_harder)
    end

    def alignment_finder
      @alignment_finder ||= AlignmentPatternFinder.new(@matrix)
    end

    # True if the bit matrix is the negative of the image (dark cells are
    # brighter on average), e.g. when a caller inverted it to read
    # light-on-dark symbols; luminance sampling then flips its comparison.
    def inverted_image?
      return @inverted_image unless @inverted_image.nil?

      @inverted_image = false
      return false unless @image && @image.width == @matrix.width && @image.height == @matrix.height

      data = @image.data
      bits = @matrix.bits
      step = [data.bytesize / 4096, 1].max
      sums = [0, 0]
      counts = [0, 0]
      i = 0
      while i < data.bytesize
        b = bits.getbyte(i)
        sums[b] += data.getbyte(i)
        counts[b] += 1
        i += step
      end
      @inverted_image = counts.all?(&:positive?) && sums[1] * counts[0] > sums[0] * counts[1]
    end

    private

    # True if a triple (or candidate) shares a finder pattern with a
    # confirmed candidate or has one inside it.
    def confirmed?(set)
      patterns = set.respond_to?(:patterns) ? set.patterns : [set.tl, set.tr, set.bl]
      @confirmed.any? do |c|
        quad = c.points
        patterns.any? { |p| c.uses?(p) || inside?(quad, p.x, p.y) }
      end
    end

    # True if a finder pattern other than the candidate's own lies inside
    # its symbol area.
    def spans_others?(candidate, patterns)
      quad = candidate.points
      patterns.any? { |p| !candidate.uses?(p) && inside?(quad, p.x, p.y) }
    end

    # Point-in-convex-quad test (either winding).
    def inside?(quad, x, y)
      signs = quad.each_with_index.map do |(x0, y0), i|
        x1, y1 = quad[(i + 1) % 4]
        (x1 - x0) * (y - y0) - (y1 - y0) * (x - x0)
      end
      signs.all?(&:positive?) || signs.all?(&:negative?)
    end
  end
end
