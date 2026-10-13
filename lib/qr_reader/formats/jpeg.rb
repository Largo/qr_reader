# frozen_string_literal: true

require_relative "../kernels/jpeg"

module QrReader
  module Formats
    # Pure-Ruby JPEG decoder that produces luminance only.
    #
    #   JPEG.decode(bytes)            # => QrReader::Image
    #   JPEG.decode(bytes, scale: 4)  # => ceil(w/4) x ceil(h/4), like libjpeg's scaled decoding
    #   JPEG.dimensions(bytes)        # => [width, height]
    #
    #   # Two resolutions for about the price of one decode:
    #   small, coefficients = JPEG.decode_keeping_coefficients(bytes, scale: 4)
    #   full = coefficients.image             # same pixels as JPEG.decode(bytes)
    #
    # Supported: baseline (SOF0), extended sequential Huffman (SOF1) and
    # progressive (SOF2) 8-bit JPEGs with any sampling factors, restart
    # intervals, 8/16-bit quantisation tables, 1 component (gray), 3 components
    # (YCbCr, or RGB via Adobe APP14 / component ids "RGB") and 4 components
    # (Adobe CMYK and YCCK). Arithmetic coding, lossless, hierarchical and
    # 12-bit and JPEG-LS files raise UnsupportedImageError. The output
    # matches libjpeg-turbo's default "islow" IDCT exactly (as built with
    # SIMD, which saturates out-of-range samples), including the reduced
    # IDCTs, per-component DCT scaling and upsampling used for scale 2, 4
    # and 8. Truncated scan data decodes what is present (missing blocks
    # stay mid-gray); damaged restart intervals are resynchronised by their
    # marker numbers; other corruption raises ImageError. EXIF orientation
    # is ignored.
    #
    # The decoder itself is the jpeg kernel (lib/qr_reader/kernels/jpeg.rb,
    # see DESIGN.md "Kernels"), which the optional qr_reader-native gem
    # compiles to C; this module validates arguments and wraps its results.
    module JPEG
      # Largest supported output (64 Mi pixels, e.g. 8192 x 8192); bigger
      # images need a larger +scale+.
      MAX_PIXELS = QrReaderKernels::JPEG_MAX_PIXELS
      # Decoded scans after which the rest of a file is ignored.
      MAX_SCANS = QrReaderKernels::JPEG_MAX_SCANS

      # Exceptions that only a bug triggered by corrupt input could raise;
      # they are reported as ImageError.
      INTERNAL_ERRORS = [NoMethodError, TypeError, ArgumentError, RangeError, IndexError, ZeroDivisionError,
                         EncodingError, FrozenError, FloatDomainError].freeze

      class << self
        # Decodes JPEG +bytes+ to a luminance Image. +scale+ (1, 2, 4 or 8)
        # decodes at reduced size: ceil(width / scale) x ceil(height / scale).
        def decode(bytes, scale: 1)
          scale = check_scale(scale)
          bytes = binary(bytes)
          data = guard("data") { QrReaderKernels.jpeg_luma(bytes, scale) }
          image(bytes, scale, data)
        end

        # Like #decode, and also returns the entropy-decoded coefficients of
        # the luminance components, from which Coefficients#image renders
        # any other scale with IDCTs only (no second entropy decoding):
        # [Image, Coefficients]. The coefficients take about 1 to 2 bytes
        # per pixel for photos and much less for scanned pages.
        def decode_keeping_coefficients(bytes, scale: 1)
          scale = check_scale(scale)
          bytes = binary(bytes)
          data, store = guard("data") { QrReaderKernels.jpeg_luma_keep(bytes, scale) }
          image = image(bytes, scale, data)
          width, height = dimensions(bytes)
          # Images too large to render at full size keep no store.
          [image, Coefficients.new(width, height, store.empty? ? bytes : nil, store)]
        end

        # [width, height] from the frame header, without decoding.
        def dimensions(bytes)
          bytes = binary(bytes)
          guard("header") { QrReaderKernels.jpeg_info(bytes) }
        end

        # The validated +scale+ as an Integer (internal).
        def check_scale(scale)
          unless scale.is_a?(Numeric) && [1, 2, 4, 8].include?(scale)
            raise ArgumentError, "scale must be 1, 2, 4 or 8, not #{scale.inspect}"
          end

          scale.to_i # also accepts 2.0
        end

        # Runs a kernel call, reporting internal errors as ImageError
        # (internal).
        def guard(what)
          yield
        rescue *INTERNAL_ERRORS => e
          # Safety net: garbage input must only ever raise ImageError.
          raise ImageError, "corrupt JPEG #{what} (internal #{e.class}: #{e.message})"
        end

        # An Image of the luma bytes the block returns (internal).
        def luma(width, height, scale)
          w = (width + scale - 1) / scale
          h = (height + scale - 1) / scale
          data = guard("data") { yield }
          raise ImageError, "corrupt JPEG data (decoded #{data.bytesize} bytes)" unless data.bytesize == w * h

          Image.new(w, h, data)
        end

        private

        # The Image of luma +data+ decoded from +bytes+ at +scale+.
        def image(bytes, scale, data)
          width, height = dimensions(bytes)
          luma(width, height, scale) { data }
        end

        def binary(bytes)
          raise ImageError, "JPEG data must be a String" unless bytes.is_a?(String)

          bytes.encoding == Encoding::BINARY ? bytes : bytes.b
        end
      end

      # Entropy-decoded coefficients of a JPEG's luminance components (see
      # JPEG.decode_keeping_coefficients), rendered at any scale by #image.
      class Coefficients
        attr_reader :width, :height

        def initialize(width, height, bytes, store) # :nodoc:
          @width = width
          @height = height
          @bytes = bytes
          @store = store
        end

        # The image at 1/+scale+ (1, 2, 4 or 8) of the size: the same pixels
        # as JPEG.decode(bytes, scale: scale).
        def image(scale: 1)
          scale = JPEG.check_scale(scale)
          JPEG.luma(@width, @height, scale) do
            if @bytes
              QrReaderKernels.jpeg_luma(@bytes, scale)
            else
              QrReaderKernels.jpeg_render(@store, scale)
            end
          end
        end

        # Memory held by the coefficients, in bytes.
        def bytesize
          @store.bytesize
        end
      end
    end
  end
end
