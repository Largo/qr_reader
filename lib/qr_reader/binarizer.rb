# frozen_string_literal: true

require_relative "kernels/binarizer"

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
  # The per-pixel work of the local methods lives in kernels/binarizer.rb
  # (QrReaderKernels, optionally compiled to C by qr_reader-native).
  module Binarizer
    # Blocks with a luminance range up to this are treated as flat.
    MIN_DYNAMIC_RANGE = QrReaderKernels::BIN_MIN_RANGE
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
        local_threshold(image, :hybrid)
      end

      # ZXing's HybridBinarizer: each 8x8 block's black point is its mean
      # luminance, or for flat blocks half its darkest value unless its
      # neighbours suggest it lies inside a dark area; black points are
      # averaged over 5x5 blocks.
      def local_mean(image)
        local_threshold(image, :local_mean)
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

      # Shared driver of the block-threshold methods (the per-pixel work is
      # done by QrReaderKernels.binarize_*, see kernels/binarizer.rb).
      def local_threshold(image, method)
        width = image.width
        height = image.height
        return global_histogram(image) if width < MINIMUM_DIMENSION || height < MINIMUM_DIMENSION

        bits = if method == :hybrid
                 QrReaderKernels.binarize_hybrid(image.data, width, height)
               else
                 QrReaderKernels.binarize_local_mean(image.data, width, height)
               end
        BitMatrix.new(width, height, bits)
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
