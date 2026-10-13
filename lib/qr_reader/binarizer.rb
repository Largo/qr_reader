# frozen_string_literal: true

module QrReader
  # Converts a grayscale Image into a BitMatrix (1 = dark, one cell per pixel).
  #
  # * hybrid           - local thresholds as in zxing-cpp's HybridBinarizer:
  #                      copes with shadows, gradients, glare and low
  #                      contrast; the default.
  # * local_mean       - local thresholds as in ZXing (Java)'s
  #                      HybridBinarizer (block means; flat blocks pushed
  #                      towards white).
  # * global_histogram - one threshold for the whole image from the valley
  #                      of the luminance histogram (ZXing's
  #                      GlobalHistogramBinarizer); the local methods use it
  #                      for images smaller than 40 pixels.
  # * threshold        - fixed threshold.
  #
  # All methods return a BitMatrix of the image's size and never fail: an
  # image without usable contrast simply binarizes to all light.
  #
  # Performance note: the per-pixel loops live in small methods that are
  # called once per row (so YJIT compiles them after a few rows) and are
  # unrolled by 8 (fewer interpreter dispatches without YJIT).
  module Binarizer
    # Blocks with a luminance range up to this are treated as flat.
    MIN_DYNAMIC_RANGE = 24
    # The local methods need 5x5 blocks of 8x8 pixels.
    MINIMUM_DIMENSION = 40
    # Histogram resolution of global_histogram: 32 buckets of 8 grey levels.
    LUMINANCE_SHIFT = 3
    LUMINANCE_BUCKETS = 256 >> LUMINANCE_SHIFT

    # String#tr source listing all 256 byte values (escaped for tr).
    TR_ALL_BYTES = Image::INVERT_FROM
    # tr targets for level t: bytes < t become "\x01", all others "\x00".
    TR_TARGETS = Array.new(257) { |t| ("\x01" * t + "\x00" * (256 - t)).b.freeze }.freeze
    private_constant :TR_ALL_BYTES, :TR_TARGETS

    class << self
      # Local-threshold binarization. The image is divided into blocks of
      # 8x8 pixels. A block with contrast gets the threshold
      # (min + max) / 2, a flat block none - unless an edge runs exactly
      # along its border: two neighbouring flat blocks whose luminance
      # ranges lie more than MIN_DYNAMIC_RANGE apart both get the threshold
      # halfway between them (crisp generated images whose module size is a
      # multiple of 8 have no edge inside any block). Each block's threshold
      # is then the mean over the 5x5 blocks around it that have one, and
      # blocks in large flat areas take the nearest threshold in scan
      # order. Pixels at or below their block's threshold become dark.
      # Unlike local_mean, a flat area (quiet zone, large modules) does not
      # drag its neighbours' thresholds down, which matters for low-contrast
      # symbols.
      def hybrid(image)
        local_threshold(image) do |data, width, height, sub_width, sub_height|
          size = sub_width * sub_height
          block = Array.new(size, 0)
          lows = Array.new(size, 0)
          highs = Array.new(size, 0)
          each_block_row(height, sub_height) do |by, y0|
            block_row_midranges(data, width, y0 * width, block, lows, highs, by * sub_width, sub_width)
          end
          by = 0
          while by < sub_height
            bridge_flat_edges(block, lows, highs, by * sub_width, sub_width, by + 1 < sub_height)
            by += 1
          end
          smooth_midranges(block, sub_width, sub_height)
        end
      end

      # ZXing's HybridBinarizer: each 8x8 block's black point is its mean
      # luminance, or for flat blocks half its darkest value unless its
      # neighbours suggest it lies inside a dark area; black points are
      # averaged over 5x5 blocks.
      def local_mean(image)
        local_threshold(image) do |data, width, height, sub_width, sub_height|
          black_points = Array.new(sub_width * sub_height, 0)
          each_block_row(height, sub_height) do |by, y0|
            block_row_black_points(data, width, y0 * width, black_points, by * sub_width, sub_width)
          end
          neighbourhood_averages(black_points, sub_width, sub_height)
        end
      end

      # Global threshold at the histogram valley between the dark and the
      # light peak. Low contrast images become all light.
      def global_histogram(image)
        black_point = global_black_point(image)
        black_point ? threshold(image, black_point) : BitMatrix.new(image.width, image.height)
      end

      # Pixels with luminance < +level+ become dark (C speed via String#tr).
      def threshold(image, level)
        BitMatrix.new(image.width, image.height, image.data.tr(TR_ALL_BYTES, TR_TARGETS[level.clamp(0, 256)]))
      end

      # The threshold global_histogram uses, or nil when the image has too
      # little contrast.
      def global_black_point(image)
        estimate_black_point(histogram(image))
      end

      private

      # Shared driver of the block-threshold methods: the block yields one
      # threshold per 8x8 block, which is then applied to every pixel.
      def local_threshold(image)
        width = image.width
        height = image.height
        return global_histogram(image) if width < MINIMUM_DIMENSION || height < MINIMUM_DIMENSION

        data = image.data
        sub_width = (width + 7) >> 3
        sub_height = (height + 7) >> 3
        thresholds = yield(data, width, height, sub_width, sub_height)
        out = "\0".b * (width * height)
        y = 0
        while y < height
          threshold_row(data, out, y * width, width, thresholds, (y >> 3) * sub_width, sub_width)
          y += 1
        end
        BitMatrix.new(width, height, out)
      end

      # Yields each block row index and its top pixel row (the last block
      # row is shifted up to stay inside the image).
      def each_block_row(height, sub_height)
        by = 0
        while by < sub_height
          y0 = by << 3
          y0 = height - 8 if y0 > height - 8
          yield by, y0
          by += 1
        end
      end

      # Black points of one row of 8x8 blocks whose top row starts at +off0+.
      # Edge blocks are shifted inwards to stay inside the image.
      def block_row_black_points(data, width, off0, black_points, base, sub_width)
        max_x = width - 8
        bx = 0
        while bx < sub_width
          x0 = bx << 3
          x0 = max_x if x0 > max_x
          off = off0 + x0
          sum = 0
          min = 255
          max = 0
          rows = 0
          while rows < 8
            a = data.getbyte(off)
            b = data.getbyte(off + 1)
            c = data.getbyte(off + 2)
            d = data.getbyte(off + 3)
            e = data.getbyte(off + 4)
            f = data.getbyte(off + 5)
            g = data.getbyte(off + 6)
            h = data.getbyte(off + 7)
            sum += a + b + c + d + e + f + g + h
            min = a if a < min
            max = a if a > max
            min = b if b < min
            max = b if b > max
            min = c if c < min
            max = c if c > max
            min = d if d < min
            max = d if d > max
            min = e if e < min
            max = e if e > max
            min = f if f < min
            max = f if f > max
            min = g if g < min
            max = g if g > max
            min = h if h < min
            max = h if h > max
            off += width
            rows += 1
            next if max - min <= MIN_DYNAMIC_RANGE

            # Enough contrast already: only the sum is still needed.
            while rows < 8
              sum += data.getbyte(off) + data.getbyte(off + 1) + data.getbyte(off + 2) + data.getbyte(off + 3) +
                     data.getbyte(off + 4) + data.getbyte(off + 5) + data.getbyte(off + 6) + data.getbyte(off + 7)
              off += width
              rows += 1
            end
          end

          black_point = sum >> 6
          if max - min <= MIN_DYNAMIC_RANGE
            # A flat block is assumed to be background (white it out) unless
            # its neighbours suggest it lies inside a dark area.
            black_point = min >> 1
            if base > 0 && bx > 0
              up = base - sub_width + bx
              neighbours = (black_points[up] + 2 * black_points[base + bx - 1] + black_points[up - 1]) >> 2
              black_point = neighbours if min < neighbours
            end
          end
          black_points[base + bx] = black_point
          bx += 1
        end
      end

      # (min + max) / 2 of each block of one block row, 0 for flat blocks;
      # the minima and maxima go to +lows+ and +highs+. Min and max of each
      # 8 pixel row segment come from pairwise comparisons (12 instead of 16
      # per segment).
      def block_row_midranges(data, width, off0, out, lows, highs, base, sub_width)
        max_x = width - 8
        bx = 0
        while bx < sub_width
          x0 = bx << 3
          x0 = max_x if x0 > max_x
          off = off0 + x0
          min = 255
          max = 0
          stop = off + 8 * width
          while off < stop
            a = data.getbyte(off)
            b = data.getbyte(off + 1)
            if a < b
              lo = a
              hi = b
            else
              lo = b
              hi = a
            end
            a = data.getbyte(off + 2)
            b = data.getbyte(off + 3)
            if a < b
              lo = a if a < lo
              hi = b if b > hi
            else
              lo = b if b < lo
              hi = a if a > hi
            end
            a = data.getbyte(off + 4)
            b = data.getbyte(off + 5)
            if a < b
              lo = a if a < lo
              hi = b if b > hi
            else
              lo = b if b < lo
              hi = a if a > hi
            end
            a = data.getbyte(off + 6)
            b = data.getbyte(off + 7)
            if a < b
              lo = a if a < lo
              hi = b if b > hi
            else
              lo = b if b < lo
              hi = a if a > hi
            end
            min = lo if lo < min
            max = hi if hi > max
            off += width
          end
          i = base + bx
          lows[i] = min
          highs[i] = max
          out[i] = max - min > MIN_DYNAMIC_RANGE ? (max + min) >> 1 : 0
          bx += 1
        end
      end

      # Gives flat blocks of the block row starting at +base+ a threshold
      # when an edge runs along their border: a flat right (or lower)
      # neighbour whose luminance range is more than MIN_DYNAMIC_RANGE away
      # from theirs. Both blocks get the threshold halfway across the gap
      # (blocks that already have one keep it). A smooth gradient never
      # qualifies: neighbouring ranges of flat blocks overlap or touch.
      def bridge_flat_edges(block, lows, highs, base, sub_width, below)
        i = base
        last = base + sub_width - 1
        while i <= last
          lo = lows[i]
          hi = highs[i]
          if hi - lo <= MIN_DYNAMIC_RANGE
            bridge_pair(block, lows, highs, i, i + 1, lo, hi) if i < last
            bridge_pair(block, lows, highs, i, i + sub_width, lo, hi) if below
          end
          i += 1
        end
      end

      # bridge_flat_edges for flat block i (range lo..hi) and block j.
      def bridge_pair(block, lows, highs, i, j, lo, hi)
        lo2 = lows[j]
        hi2 = highs[j]
        return if hi2 - lo2 > MIN_DYNAMIC_RANGE

        t = if lo2 - hi > MIN_DYNAMIC_RANGE
              (hi + lo2) >> 1
            elsif lo - hi2 > MIN_DYNAMIC_RANGE
              (hi2 + lo) >> 1
            else
              return
            end
        block[i] = t if block[i] == 0
        block[j] = t if block[j] == 0
      end

      # Mean over the 5x5 blocks around each block of the thresholds that
      # are set (the block itself counts twice), via separable box sums of
      # the thresholds and of an is-set indicator; then gap filling in scan
      # order for blocks without any contrast around them. One method call
      # per block row, so that YJIT compiles the loops.
      def smooth_midranges(block, sub_width, sub_height)
        size = sub_width * sub_height
        hsum = Array.new(size, 0)
        hcount = Array.new(size, 0)
        by = 0
        while by < sub_height
          window_row_sums(block, hsum, hcount, by * sub_width, sub_width)
          by += 1
        end
        out = Array.new(size, 0)
        by = 0
        while by < sub_height
          window_column_means(block, hsum, hcount, out, by * sub_width,
                              (by.clamp(2, sub_height - 3) - 2) * sub_width, sub_width)
          by += 1
        end
        fill_gaps(out, sub_width)
      end

      # Sums and counts of the set (positive) thresholds over the 5 blocks
      # around each block of one block row (window clamped to the row).
      def window_row_sums(block, hsum, hcount, base, sub_width)
        last = sub_width - 3
        bx = 0
        while bx < sub_width
          # Window start, clamped to the row (no Integer#clamp: slow in loops).
          i = base + (bx < 2 ? 0 : (bx > last ? last - 2 : bx - 2))
          a = block[i]
          b = block[i + 1]
          c = block[i + 2]
          d = block[i + 3]
          e = block[i + 4]
          sum = 0
          count = 0
          if a > 0
            sum += a
            count += 1
          end
          if b > 0
            sum += b
            count += 1
          end
          if c > 0
            sum += c
            count += 1
          end
          if d > 0
            sum += d
            count += 1
          end
          if e > 0
            sum += e
            count += 1
          end
          hsum[base + bx] = sum
          hcount[base + bx] = count
          bx += 1
        end
      end

      # 5x5 means of one block row from the row sums of the 5 block rows
      # starting at +top+ (0 where no threshold is set nearby).
      def window_column_means(block, hsum, hcount, out, base, top, sub_width)
        s1 = sub_width
        s2 = 2 * sub_width
        s3 = 3 * sub_width
        s4 = 4 * sub_width
        bx = 0
        while bx < sub_width
          i = top + bx
          sum = hsum[i] + hsum[i + s1] + hsum[i + s2] + hsum[i + s3] + hsum[i + s4]
          count = hcount[i] + hcount[i + s1] + hcount[i + s2] + hcount[i + s3] + hcount[i + s4]
          centre = block[base + bx]
          if centre > 0
            sum += 2 * centre
            count += 2
          end
          out[base + bx] = count > 0 ? sum / count : 0
          bx += 1
        end
      end

      # Sets every 0 entry to the previous non-zero one in scan order (or
      # the first one). All zero (no contrast anywhere) becomes -1:
      # everything light.
      def fill_gaps(values, row_size)
        first = values.index(&:positive?) or return values.fill(-1)
        values.fill(values[first], 0, first)
        last = values[first]
        n = values.size
        i = first + 1
        while i < n
          stop = i + row_size
          stop = n if stop > n
          last = fill_gaps_span(values, i, stop, last)
          i = stop
        end
        values
      end

      # fill_gaps for values[i...stop]; returns the last non-zero value.
      def fill_gaps_span(values, i, stop, last)
        while i < stop
          t = values[i]
          if t == 0
            values[i] = last
          else
            last = t
          end
          i += 1
        end
        last
      end

      # Mean black point over the 5x5 blocks around each block (the window
      # is clamped to stay inside the block grid).
      def neighbourhood_averages(black_points, sub_width, sub_height)
        hsum = Array.new(sub_width * sub_height, 0)
        by = 0
        while by < sub_height
          five_sums_row(black_points, hsum, by * sub_width, sub_width)
          by += 1
        end
        averages = Array.new(sub_width * sub_height, 0)
        by = 0
        while by < sub_height
          five_means_row(hsum, averages, by * sub_width, by.clamp(2, sub_height - 3) * sub_width, sub_width)
          by += 1
        end
        averages
      end

      # Sums over the 5 blocks around each block of one block row.
      def five_sums_row(values, hsum, base, sub_width)
        last = sub_width - 3
        bx = 0
        while bx < sub_width
          i = base + (bx < 2 ? 2 : (bx > last ? last : bx))
          hsum[base + bx] = values[i - 2] + values[i - 1] + values[i] + values[i + 1] + values[i + 2]
          bx += 1
        end
      end

      # Means over 5 block rows (centred on block row +centre+) of +hsum+.
      def five_means_row(hsum, averages, base, centre, sub_width)
        two_rows = 2 * sub_width
        bx = 0
        while bx < sub_width
          i = centre + bx
          averages[base + bx] = (hsum[i - two_rows] + hsum[i - sub_width] + hsum[i] +
                                 hsum[i + sub_width] + hsum[i + two_rows]) / 25
          bx += 1
        end
      end

      # Marks the pixels of one image row that are at or below their block's
      # threshold. Columns past the last full block use the last block.
      def threshold_row(data, out, off, width, thresholds, base, sub_width)
        full = width >> 3
        bx = 0
        i = off
        while bx < full
          t = thresholds[base + bx]
          out.setbyte(i, 1) if data.getbyte(i) <= t
          out.setbyte(i + 1, 1) if data.getbyte(i + 1) <= t
          out.setbyte(i + 2, 1) if data.getbyte(i + 2) <= t
          out.setbyte(i + 3, 1) if data.getbyte(i + 3) <= t
          out.setbyte(i + 4, 1) if data.getbyte(i + 4) <= t
          out.setbyte(i + 5, 1) if data.getbyte(i + 5) <= t
          out.setbyte(i + 6, 1) if data.getbyte(i + 6) <= t
          out.setbyte(i + 7, 1) if data.getbyte(i + 7) <= t
          i += 8
          bx += 1
        end
        return if full == sub_width

        t = thresholds[base + sub_width - 1]
        stop = off + width
        while i < stop
          out.setbyte(i, 1) if data.getbyte(i) <= t
          i += 1
        end
      end

      # 32-bucket luminance histogram of the central 3/5 of up to 16 rows
      # spread evenly over the image (all rows of small images).
      def histogram(image)
        width = image.width
        height = image.height
        data = image.data
        buckets = Array.new(LUMINANCE_BUCKETS, 0)
        left = width / 5
        right = width * 4 / 5
        left, right = 0, width if right - left < 8
        rows = height < 64 ? height : 16
        k = 0
        while k < rows
          y = rows == height ? k : height * (k + 1) / (rows + 1)
          i = y * width + left
          stop = y * width + right
          while i < stop
            buckets[data.getbyte(i) >> LUMINANCE_SHIFT] += 1
            i += 1
          end
          k += 1
        end
        buckets
      end

      # ZXing's valley search: the tallest peak, a second peak weighted by
      # squared distance, then the deepest valley between them, biased
      # towards the light peak. nil if the peaks are too close together.
      def estimate_black_point(buckets)
        n = buckets.size
        max_count = 0
        first_peak = 0
        n.times do |x|
          if buckets[x] > max_count
            first_peak = x
            max_count = buckets[x]
          end
        end
        second_peak = 0
        second_score = 0
        n.times do |x|
          d = x - first_peak
          score = buckets[x] * d * d
          if score > second_score
            second_peak = x
            second_score = score
          end
        end
        return nil if buckets[second_peak].zero?

        first_peak, second_peak = second_peak, first_peak if first_peak > second_peak
        return nil if second_peak - first_peak <= n / 16

        best_valley = second_peak - 1
        best_score = -1
        x = second_peak - 1
        while x > first_peak
          from_first = x - first_peak
          score = from_first * from_first * (second_peak - x) * (max_count - buckets[x])
          if score > best_score
            best_valley = x
            best_score = score
          end
          x -= 1
        end
        best_valley << LUMINANCE_SHIFT
      end
    end
  end
end
