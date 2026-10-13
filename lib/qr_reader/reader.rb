# frozen_string_literal: true

module QrReader
  # Orchestrates image loading, binarization, detection and decoding.
  #
  # Strategies run cheapest first and stop at the first decodable symbol
  # (unless reading all codes), so the common case stays fast while hard
  # images still get the expensive treatment when +try_harder+ is set.
  #
  # Large images (photos, page scans) are searched through a resolution
  # pyramid, coarsest level first: a code that fills a good part of the image
  # is found quickly at low resolution, a small code on a 600 DPI page scan is
  # still found at full resolution.
  class Reader
    # The coarsest pyramid level is the largest power-of-two reduction whose
    # longer side is still at least this many pixels.
    PYRAMID_MIN_SIDE = 800
    # ... and whose shorter side still has room for the smallest symbol (21
    # modules), so long thin images (banners, rules) are not reduced to nothing.
    PYRAMID_MIN_SHORT_SIDE = 21
    # The exhaustive (try_harder) strategies only run on pyramid levels up to
    # this size: at full resolution of a 12 MP photo they cost seconds and
    # mostly chase texture noise, while the fast strategies still run there.
    HARD_MAX_SIDE = 2600
    # Pixels at most this far from square (width / height) are used as they are.
    SQUARE_TOLERANCE = 0.15
    # Upper bound on alternative samplings tried per candidate.
    MAX_ALTERNATIVES = 6

    attr_reader :try_harder, :inverted

    # try_harder: keep trying slower strategies when the fast ones find nothing.
    # inverted:   true, false or :auto - also look for light-on-dark symbols.
    def initialize(try_harder: true, inverted: :auto)
      @try_harder = try_harder
      @inverted = inverted
    end

    # First decoded Result, or nil.
    def read(input)
      each_result(input, false) { |result| return result }
      nil
    end

    # All decoded Results (distinct symbols, all pages), possibly empty.
    def read_all(input)
      results = []
      each_result(input, true) { |result| results << result }
      results
    end

    # Yields each distinct Result as soon as it is decoded. Returns an
    # Enumerator when no block is given.
    def scan(input, &block)
      return enum_for(:scan, input) unless block

      each_result(input, true, &block)
      self
    end

    class << self
      # Converts any supported input into an Image (the first page of
      # multi-page documents).
      def load_image(input)
        return input if input.is_a?(Image)

        bytes = input_bytes(input)
        if bytes
          # Formats.decode reads the first page of TIFF and PDF too; this also
          # finds PDFs with junk before their header.
          if container_format(bytes) == :pdf
            Formats::PDF.each_image(bytes) { |image, _info| return image }
          end
          return Formats.decode(bytes)
        end

        if input.respond_to?(:width) && input.respond_to?(:height) && input.respond_to?(:pixels)
          # ChunkyPNG-style canvas: pixels are 0xRRGGBBAA integers.
          return Image.from_pixels(input.width, input.height, input.pixels.pack("N*"), :rgba)
        end

        raise ArgumentError, "unsupported input #{input.class}: expected a path, IO, image bytes or QrReader::Image"
      end

      # Encoded image bytes for paths, IOs and byte strings; nil for other objects.
      def input_bytes(input)
        if input.is_a?(String)
          # A short String naming an existing file is a path, even if it
          # starts like image data ("GIF89a.gif", "P5 scan.pgm").
          short = input.bytesize <= 4096 && !input.include?("\0")
          return File.binread(input) if short && File.file?(input)
          return input.b if Formats.format_of(input) || container_format(input)
          raise ImageError, "unrecognised image data" unless short

          File.binread(input) # raises Errno::ENOENT etc. like File.read
        elsif input.respond_to?(:to_path)
          File.binread(input.to_path)
        elsif input.respond_to?(:read)
          data = input.read
          raise ImageError, "IO returned no data" unless data

          data.b
        end
      end

      # :tiff or :pdf for multi-page containers, else nil.
      def container_format(bytes)
        head = bytes.byteslice(0, 4)
        return :tiff if ["II*\0", "MM\0*", "II+\0", "MM\0+"].include?(head)
        return :pdf if bytes.byteslice(0, 1024)&.include?("%PDF-")

        nil
      end
    end

    private

    # Yields decoded results (deduplicated) until the caller stops iterating.
    def each_result(input, multi, &block)
      @multi = multi
      @emit = block
      @seen = []
      @y_scale = 1.0

      if input.is_a?(Image)
        scan_pyramid(input, nil)
        return
      end

      bytes = self.class.input_bytes(input)
      unless bytes
        scan_pyramid(self.class.load_image(input), nil)
        return
      end

      @y_scale = 1.0
      case self.class.container_format(bytes)
      when :tiff
        # Pages that cannot be decoded are skipped.
        Formats::TIFF.each_image(bytes) do |image, info|
          return if scan_page(image, info) && !multi
        end
      when :pdf
        # Plain JPEG page images come undecoded, for the reduced-size pass;
        # groups of vector shapes that may be a code come rendered.
        Formats::PDF.each_image(bytes, raw_jpeg: true, vector: true) do |image, info|
          found = case info[:format]
                  when :jpeg then scan_jpeg_or_full(image, info[:page], info[:pixel_aspect])
                  when :jpx then scan_jpx(image, info[:page], info[:pixel_aspect])
                  else scan_page(image, info)
                  end
          return if found && !multi
        end
      else
        if Formats.format_of(bytes) == :jpeg
          scan_jpeg_or_full(bytes, nil, 1.0)
        else
          scan_pyramid(Formats.decode(bytes), nil)
        end
      end
    end

    # One page of a TIFF or PDF, resampled to square pixels if needed.
    def scan_page(image, info)
      image, @y_scale = square_pixels(image, info[:pixel_aspect])
      scan_pyramid(image, info[:page])
    ensure
      @y_scale = 1.0
    end

    def scan_jpeg_or_full(bytes, page, aspect)
      aspect ||= 1.0
      if (scale = jpeg_prescale(bytes)) && (aspect - 1.0).abs < SQUARE_TOLERANCE
        scan_jpeg(bytes, scale, page)
      else
        scan_page(Formats::JPEG.decode(bytes), page: page, pixel_aspect: aspect)
      end
    end

    # Big JPEGs: the coarsest pyramid level comes straight from a reduced-size
    # decode; the coefficients are kept, so the full resolution (only needed
    # when that finds nothing) costs IDCTs but no second entropy decoding.
    def scan_jpeg(bytes, scale, page)
      @page = page
      @tried = {}
      small, coefficients = Formats::JPEG.decode_keeping_coefficients(bytes, scale: scale)
      return true if run_strategies(small, scale.to_f, quick: true) && !@multi

      small = nil
      full = coefficients ? coefficients.image(scale: 1) : Formats::JPEG.decode(bytes)
      coefficients = nil
      scan_pyramid(full, page, skip_factor: scale)
    end

    # A JPEG 2000 image of a PDF (a PDF::RawJpx): large ones are first
    # decoded at reduced resolution, which skips most of the decoding work
    # (JPEG 2000 resolutions are coded separately), and only decoded in
    # full when the quick strategies find nothing there.
    def scan_jpx(raw, page, aspect)
      aspect ||= 1.0
      base = raw.fitting_reduce
      longest = raw.width > raw.height ? raw.width : raw.height
      preview = base
      preview += 1 while preview < base + 3 && (longest >> (preview + 1)) >= PYRAMID_MIN_SIDE
      if preview > base && (aspect - 1.0).abs < SQUARE_TOLERANCE
        @page = page
        @tried = {}
        small = raw.decode(reduce: preview)
        return true if run_strategies(small, (1 << preview).to_f, quick: true) && !@multi

        small = nil
        return scan_pyramid(raw.decode(reduce: base), page, skip_factor: 1 << (preview - base))
      end
      scan_page(raw.decode(reduce: base), page: page, pixel_aspect: aspect)
    end

    # [image with square pixels, factor mapping its rows back to the original].
    # Fax pages (204 x 98 dpi) have pixels about twice as tall as wide: their
    # rows are repeated so that finder patterns are square again.
    def square_pixels(image, aspect)
      return [image, 1.0] if aspect.nil? || aspect >= 1.0 - SQUARE_TOLERANCE

      height = (image.height / aspect).round
      [image.stretch_rows(height), image.height.to_f / height]
    end

    # Reduced decode scale (2, 4 or 8) for big JPEGs, or nil.
    def jpeg_prescale(bytes)
      w, h = Formats::JPEG.dimensions(bytes)
      factors = pyramid_factors(w > h ? w : h, w < h ? w : h)
      factors.size > 1 ? [factors.first, 8].min : nil
    rescue Error
      nil
    end

    # Power-of-two reduction factors, coarsest first, ending with 1.
    def pyramid_factors(longest, shortest)
      f = 1
      f *= 2 while longest / (f * 2) >= PYRAMID_MIN_SIDE && shortest / (f * 2) >= PYRAMID_MIN_SHORT_SIDE
      factors = []
      while f >= 1
        factors << f
        f /= 2
      end
      factors
    end

    # Quick strategies on every pyramid level (coarse to fine), then the
    # expensive ones (coarse to fine). Returns true if anything was found.
    def scan_pyramid(image, page, skip_factor: nil)
      @page = page
      @tried = {}
      longest = image.width > image.height ? image.width : image.height
      factors = pyramid_factors(longest, image.width < image.height ? image.width : image.height)
      levels = { 1 => image }
      level = lambda do |f|
        levels[f] ||= level.call(f / 2).downscale(2)
      end

      found = false
      factors.each do |f|
        next if f == skip_factor

        @tried = {}
        found = true if run_strategies(level.call(f), f.to_f, quick: true)
        return true if found && !@multi
      end
      return found unless @try_harder

      factors.each do |f|
        next if longest / f > HARD_MAX_SIDE

        @tried = {}
        found = true if run_strategies(level.call(f), f.to_f, quick: false, skip_quick: true)
        return true if found && !@multi
      end
      found
    end

    # quick: normal hybrid binarization + detection (both polarities).
    # Otherwise exhaustive row scanning and the global-histogram binarizer
    # (skip_quick: the quick passes already ran on this image).
    def run_strategies(image, factor, quick:, skip_quick: false)
      polarities = case @inverted
                   when true then [true]
                   when false then [false]
                   else [false, true]
                   end
      passes = []
      polarities.each { |inv| passes << [:hybrid, inv, false] } unless skip_quick
      unless quick
        polarities.each do |inv|
          passes << [:hybrid, inv, true]
          passes << [:global, inv, true]
        end
      end

      binarized = {}
      found = false
      passes.each do |kind, inv, harder|
        bits = binarized[[kind, inv]] ||= begin
          base = binarized[[kind, false]] ||=
            kind == :hybrid ? Binarizer.hybrid(image) : Binarizer.global_histogram(image)
          inv ? base.invert : base
        end

        if (!harder || kind == :global) && (candidate = Detector.detect_pure(bits)) && try_candidate(candidate, factor)
          found = true
          return true unless @multi
        end

        Detector.new(bits, image: image).each_candidate(try_harder: harder, multi: @multi) do |cand|
          next unless try_candidate(cand, factor)

          found = true
          return true unless @multi
        end
      end
      found
    end

    # Decodes a candidate (and its alternatives); emits and returns the
    # result, or nil. Candidates already tried at the same place are skipped.
    def try_candidate(candidate, factor)
      key = candidate_key(candidate)
      return nil if key && @tried[key]

      @tried[key] = true if key
      result = Decoder.decode(candidate.bits)
      unless result
        candidate.alternatives.each_with_index do |bits, i|
          break if i >= MAX_ALTERNATIVES

          result = Decoder.decode(bits)
          break if result
        end
      end
      return nil unless result

      y_factor = factor * @y_scale
      points = candidate.points&.map { |x, y| [x * factor, y * y_factor] }
      # A mirrored symbol was decoded from the transposed grid: its top-right
      # and bottom-left corners are the grid's bottom-left and top-right.
      points = [points[0], points[3], points[2], points[1]] if points && result.mirrored
      result = result.with(points: points, page: @page)
      return result if @seen.any? { |other| same_symbol?(other, result) }

      @seen << result
      @emit.call(result)
      result
    end

    def candidate_key(candidate)
      pts = candidate.points
      return nil unless pts

      [candidate.bits.width] + pts.flat_map { |x, y| [(x / 2.0).round, (y / 2.0).round] }
    end

    # Two results describe the same symbol if they are on the same page, their
    # payloads match and their centres are close (or positions are unknown).
    def same_symbol?(a, b)
      return false unless a.page == b.page && a.raw_bytes == b.raw_bytes
      return true unless a.points && b.points

      ax = a.points.sum { |p| p[0] } / 4.0
      ay = a.points.sum { |p| p[1] } / 4.0
      bx = b.points.sum { |p| p[0] } / 4.0
      by = b.points.sum { |p| p[1] } / 4.0
      size = Math.hypot(a.points[1][0] - a.points[0][0], a.points[1][1] - a.points[0][1])
      Math.hypot(ax - bx, ay - by) < [size / 2, 10].max
    end
  end
end
