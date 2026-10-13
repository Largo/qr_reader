# frozen_string_literal: true

require_relative "binarizer"
require_relative "kernels/detector"
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
    # With multi, up to this many finder patterns are considered...
    MULTI_PATTERNS = 400
    # ... and at most this many "foreign" triples (with other finder
    # patterns inside, see PatternSets.partition_clean): on pages with
    # several symbols nearly all triples joining finders of different
    # symbols are foreign, real symbols practically never.
    MULTI_FOREIGN = 12
    # Score penalty of foreign triples in single-symbol mode (a perfect
    # triple scores 0, see PatternSets.evaluate).
    FOREIGN_PENALTY = 0.5
    # Besides the best scored triples overall, each finder pattern is
    # combined with pairs of this many of its nearest neighbours.
    NEIGHBOURS = 8

    attr_reader :matrix, :image

    # Fast path for clean axis-aligned symbols (see PureDetector);
    # returns a candidate or nil.
    def self.detect_pure(matrix)
      PureDetector.detect(matrix)
    end

    # +matrix+ - binarized image (BitMatrix, 1 = dark)
    # +image+  - the grayscale Image it came from (optional; ignored unless
    #            it has the matrix's size)
    def initialize(matrix, image: nil)
      @matrix = matrix
      @image = image if image && image.width == matrix.width && image.height == matrix.height
      @finder = FinderPatternFinder.new(matrix)
      @confirmed = []
    end

    # Yields Candidates, most likely first (Enumerator without a block).
    # Candidates whose timing patterns read like noise (false finder
    # triples, mostly) are only produced with try_harder, after all others
    # (with multi, the FAST_TRIPLES best of those that span no other finder
    # pattern).
    #
    # try_harder: scan every row and try more finder pattern triples.
    # multi: look for all symbols - also triples of neighbouring finder
    # patterns (pages with many symbols), skipping triples that share a
    # finder pattern with (or lie inside) a candidate passed to #confirm.
    def each_candidate(try_harder: false, multi: false)
      return enum_for(:each_candidate, try_harder: try_harder, multi: multi) unless block_given?

      patterns, triples = multi ? multi_triples(try_harder) : single_triples(try_harder)
      deferred = []
      triples.each do |triple|
        next if multi && confirmed?(triple)

        candidate = Candidate.locate(self, triple) or next
        if candidate.likely?
          yield candidate
        elsif try_harder && !(multi && spans_others?(candidate, patterns))
          deferred << candidate
        end
      end
      deferred = deferred.first(FAST_TRIPLES) if multi
      deferred.each { |candidate| yield candidate unless multi && confirmed?(candidate) }
      nil
    end

    # Records a decoded symbol, so that multi-symbol detection skips
    # triples that reuse its finder patterns or lie inside it: a Candidate
    # (or detect_pure result), anything else with #points (e.g. a Result
    # decoded earlier from another binarization of the same image, its
    # points scaled to this matrix), or the corner quad [[x, y], ...]
    # itself. Returns self.
    def confirm(symbol)
      quad = symbol.is_a?(Array) ? symbol : symbol.points
      if quad.is_a?(Array) && quad.size == 4 && quad.flatten.all? { |v| v.is_a?(Numeric) && v.finite? }
        @confirmed << [quad, symbol.respond_to?(:uses?) ? symbol : nil]
      end
      self
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

    # [patterns, triples] for single-symbol detection: the best scored
    # triples of the most consistent finder patterns and of each pattern's
    # nearest neighbours, those with other symbols' finder patterns inside
    # (foreign, see PatternSets.partition_clean) ranked as if their score
    # were FOREIGN_PENALTY worse: on a sheet of labels the best shaped
    # triples join finders of neighbouring symbols, but a large symbol
    # with small modules can have finder look-alikes in its data area and
    # must still beat the ill-shaped triples of those look-alikes.
    def single_triples(try_harder)
      patterns = finder_patterns(try_harder: try_harder)
      limit = try_harder ? HARD_TRIPLES : FAST_TRIPLES
      clean, foreign = ranked_triples(PatternSets.generate(patterns, 4 * limit), patterns, patterns)
      ranked = clean.each_with_index.map { |t, i| [t.score, i, t] }
      foreign.each_with_index { |t, i| ranked << [t.score + FOREIGN_PENALTY, clean.size + i, t] }
      [patterns, ranked.sort!.first(limit).map(&:last)]
    end

    # [patterns, triples] for multi-symbol detection: as for a single
    # symbol, but from up to MULTI_PATTERNS patterns and MULTI_TRIPLES
    # triples (a page with that many symbols), MULTI_FOREIGN of them
    # foreign.
    def multi_triples(try_harder)
      all = @finder.find(try_harder: try_harder, limit: MULTI_PATTERNS)
      best = if all.size > FinderPatternFinder::MAX_PATTERNS
               all.max_by(FinderPatternFinder::MAX_PATTERNS) { |p| p.quality * Math.sqrt(p.count) }
             else
               all
             end
      clean, foreign = ranked_triples(PatternSets.generate(best, MULTI_TRIPLES), all, all)
      [all, (clean + foreign.first(MULTI_FOREIGN)).first(MULTI_TRIPLES)]
    end

    # +triples+ plus the neighbourhood triples of +near+, split into
    # [clean, foreign] (see PatternSets.partition_clean against +all+), the
    # clean ones best first.
    def ranked_triples(triples, near, all)
      seen = triples.to_h { |t| [t.patterns.map(&:object_id), true] }
      PatternSets.neighbourhood(near, NEIGHBOURS).each do |t|
        triples << t unless seen[t.patterns.map(&:object_id)]
      end
      clean, foreign = PatternSets.partition_clean(triples, all)
      [clean.sort_by!(&:score), foreign]
    end

    # True if a triple (or candidate) shares a finder pattern with a
    # confirmed symbol or has one inside it.
    def confirmed?(set)
      patterns = set.respond_to?(:patterns) ? set.patterns : [set.tl, set.tr, set.bl]
      @confirmed.any? do |quad, owner|
        patterns.any? { |p| owner&.uses?(p) || inside?(quad, p.x, p.y) }
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
