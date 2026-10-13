# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "qr_reader/bit_matrix"

begin
  require "rqrcode_core"
rescue LoadError
  # development dependency (bundle exec); only ScanSim::Code.encode needs it
end

# Simulates printed documents and the scanners that digitise them (flatbed,
# sheet-fed, multifunction printers, fax machines) to build a realistic QR
# test corpus. Development only: rendering runs ImageMagick 7 (`magick`).
#
#   code = ScanSim::Code.encode("https://example.com", level: :m)
#   doc  = ScanSim::Document.new(210, 297)
#   doc.ink.text(20, 30, "Rechnung", size: 14, font: ScanSim::SANS_BOLD)
#   doc.ink.qr(code, 160, 20, 25)
#   page = ScanSim::Page.new(doc, scan: ScanSim::Scan.new(dpi: 300, blur: 0.5, skew: 0.8))
#   ScanSim.render([page], "invoice.pdf", format: "pdf-dct", quality: 80, seed: 1)
#   page.truth   # => [{text:, version:, module_px: [x, y], center: [x, y], ...}]
#
# The pipeline follows the physical process:
# 1. print: the document's ink layer is rasterised at a printer-like work
#    resolution (QR modules on exact pixel edges, ink spread/toner starvation
#    as geometry), optionally halftone-screened, faded, speckled, with dead
#    thermal print-head dots; multiplied onto tinted, mottled paper; pen marks
#    and stamps on top; optionally photocopied a few generations;
# 2. scan: the page is turned (90/180/270), area-sampled at the scan
#    resolution (non-square for fax), skewed/placed on the glass, warped
#    (curl, wave, crease), unevenly lit, blurred by the optics, sensor noise
#    added, converted to the scanner's colour/gray/black-and-white mode;
# 3. the output is encoded as PNG, JPEG, TIFF or PDF, one or several pages.
#
# Units: document geometry in millimetres (origin top-left), font sizes in
# points, angles in degrees (clockwise on the page). Every random choice comes
# from the given seed; ImageMagick runs single-threaded so that its noise is
# deterministic too.
module ScanSim
  MM_PER_INCH = 25.4
  # Millimetres per typographic point.
  PT = 25.4 / 72

  SANS = "DejaVu-Sans"
  SANS_BOLD = "DejaVu-Sans-Bold"
  SANS_CONDENSED = "DejaVu-Sans-Condensed"
  SERIF = "Liberation-Serif"
  SERIF_BOLD = "Liberation-Serif-Bold"
  MONO = "DejaVu-Sans-Mono"
  MONO_BOLD = "DejaVu-Sans-Mono-Bold"

  # Environment for every ImageMagick call: one thread (noise is only
  # reproducible for a fixed thread count) and fixed timestamps.
  MAGICK_ENV = { "MAGICK_THREAD_LIMIT" => "1", "OMP_NUM_THREADS" => "1", "SOURCE_DATE_EPOCH" => "1767225600" }.freeze

  # Output formats: [file extension, ImageMagick arguments, bilevel?].
  # "Q" is replaced by the JPEG quality.
  FORMATS = {
    "png-gray" => ["png", %w[-colorspace Gray -depth 8 -define png:color-type=0], false],
    "png-color" => ["png", %w[-depth 8 -define png:color-type=2], false],
    "png-1bit" => ["png", %w[-colorspace Gray -type Bilevel -define png:bit-depth=1 -define png:color-type=0], true],
    "jpeg-color" => ["jpg", %w[-sampling-factor 2x2,1x1,1x1 -quality Q], false],
    "jpeg-gray" => ["jpg", %w[-colorspace Gray -quality Q], false],
    "tiff-g4" => ["tif", %w[-colorspace Gray -type Bilevel -compress Group4], true],
    "tiff-g3" => ["tif", %w[-colorspace Gray -type Bilevel -compress Fax], true],
    "tiff-lzw" => ["tif", %w[-colorspace Gray -depth 8 -compress LZW -define tiff:predictor=2], false],
    "tiff-lzw-color" => ["tif", %w[-depth 8 -compress LZW], false],
    "tiff-jpeg" => ["tif", %w[-compress JPEG -quality Q], false],
    "pdf-dct" => ["pdf", %w[-compress JPEG -quality Q], false],
    "pdf-g4" => ["pdf", %w[-colorspace Gray -type Bilevel -compress Group4], true],
    "pdf-flate" => ["pdf", %w[-compress Zip], false]
  }.freeze

  # ImageMagick's Gaussian noise: rms gray levels (of 255) per unit of -attenuate.
  NOISE_LEVELS = 19.5

  # Scanner colour modes; the last four produce black-and-white images.
  MODES = %i[color gray threshold adaptive ordered diffusion].freeze
  BILEVEL_MODES = %i[threshold adaptive ordered diffusion].freeze

  class Error < StandardError; end

  # A QR symbol to print. +kind+ is a free-form payload label for reports.
  Code = Data.define(:text, :matrix, :level, :kind) do
    # Encodes +text+ with rqrcode_core (smallest version unless given; byte
    # mode stores the UTF-8 bytes without ECI, as most generators do).
    def self.encode(text, level: :m, version: nil, kind: nil)
      raise Error, "rqrcode_core is not available (run with bundle exec)" unless defined?(RQRCodeCore)

      level = level.to_s.downcase.to_sym
      options = { level: level }
      options[:size] = version if version
      rows = RQRCodeCore::QRCode.new(text, **options).modules
      new(text: text, matrix: QrReader::BitMatrix.from_rows(rows), level: level, kind: kind)
    end

    def modules
      matrix.width
    end

    def version
      (matrix.width - 17) / 4
    end
  end

  # A symbol on a document: +x+, +y+ is the top-left corner of the symbol
  # without quiet zone, +size+ its side (mm); +angle+ rotates it about its
  # centre (a sticker applied crookedly).
  Placement = Data.define(:code, :x, :y, :size, :angle) do
    def center
      [x + size / 2.0, y + size / 2.0]
    end

    def module_mm
      size / code.modules
    end
  end

  # Affine map x' = a*x + b*y + c, y' = d*x + e*y + f.
  Affine = Data.define(:a, :b, :c, :d, :e, :f) do
    def self.identity
      new(a: 1.0, b: 0.0, c: 0.0, d: 0.0, e: 1.0, f: 0.0)
    end

    def self.scale(sx, sy = sx)
      new(a: sx.to_f, b: 0.0, c: 0.0, d: 0.0, e: sy.to_f, f: 0.0)
    end

    def self.translate(tx, ty)
      new(a: 1.0, b: 0.0, c: tx.to_f, d: 0.0, e: 1.0, f: ty.to_f)
    end

    # Rotation by +degrees+, clockwise on screen (y axis pointing down).
    def self.rotate(degrees)
      r = degrees * Math::PI / 180
      cos = Math.cos(r)
      sin = Math.sin(r)
      new(a: cos, b: -sin, c: 0.0, d: sin, e: cos, f: 0.0)
    end

    # Composition: (self * other).apply(p) == self.apply(*other.apply(p)).
    def *(other)
      o = other
      Affine.new(a: a * o.a + b * o.d, b: a * o.b + b * o.e, c: a * o.c + b * o.f + c,
                 d: d * o.a + e * o.d, e: d * o.b + e * o.e, f: d * o.c + e * o.f + f)
    end

    def apply(x, y)
      [a * x + b * y + c, d * x + e * y + f]
    end

    # Applies only the linear part (for direction vectors).
    def apply_vector(x, y)
      [a * x + b * y, d * x + e * y]
    end

    def inverse
      det = a * e - b * d
      ia = e / det
      ib = -b / det
      id = -d / det
      ie = a / det
      Affine.new(a: ia, b: ib, c: -(ia * c + ib * f), d: id, e: ie, f: -(id * c + ie * f))
    end

    # ImageMagick AffineProjection arguments (sx, rx, ry, sy, tx, ty).
    def to_magick
      [a, d, b, e, c, f].map { |v| format("%.8f", v) }.join(",")
    end
  end

  # A list of drawing items in millimetres, rendered to ImageMagick MVG.
  class Layer
    attr_reader :items

    def initialize(document)
      @document = document
      @items = []
    end

    def empty?
      @items.empty?
    end

    # Text with its baseline starting (anchor :start), centred (:middle) or
    # ending (:end) at +x+, +y+.
    def text(x, y, string, size: 9, font: SANS, color: "black", anchor: :start, angle: 0, opacity: 1.0)
      clean = string.to_s.delete("'\"\\\n\r")
      @items << [:text, x, y, clean, size, font, color, anchor, angle, opacity] unless clean.strip.empty?
      self
    end

    def rect(x, y, w, h, fill: "black", stroke: nil, width: 0.25, radius: 0, opacity: 1.0, dash: nil)
      @items << [:rect, x, y, w, h, fill, stroke, width, radius, opacity, dash]
      self
    end

    def line(x1, y1, x2, y2, color: "black", width: 0.25, opacity: 1.0, dash: nil)
      @items << [:line, x1, y1, x2, y2, color, width, opacity, dash]
      self
    end

    # Polyline through +points+ ([[x, y], ...]); +smooth+ draws a
    # Catmull-Rom curve through them (pen strokes, signatures).
    def polyline(points, color: "black", width: 0.25, opacity: 1.0, smooth: false, fill: nil, closed: false)
      @items << [:polyline, points, color, width, opacity, smooth, fill, closed] if points.size >= 2
      self
    end

    def ellipse(cx, cy, rx, ry, fill: nil, stroke: "black", width: 0.25, opacity: 1.0)
      @items << [:ellipse, cx, cy, rx, ry, fill, stroke, width, opacity]
      self
    end

    # Groups items drawn inside the block, rotated by +angle+ about (+cx+, +cy+).
    def rotated(angle, cx, cy)
      @items << [:push, angle, cx, cy]
      yield self
      @items << [:pop]
      self
    end

    # Prints +code+ with its symbol's top-left corner at +x+, +y+ and side
    # +size+ (mm). +color+ is the ink of dark modules, +background+ (if any)
    # fills symbol plus +quiet+ modules around it. +gain+ makes dark modules
    # fatter (> 0, ink spread / dot gain) or thinner (< 0, toner starvation)
    # by that fraction of a module in total. +cross+ overlays the Swiss
    # QR-bill cross (7 x 7 mm). Returns the Placement (ground truth).
    def qr(code, x, y, size, color: "black", background: nil, quiet: 4, gain: 0.0, cross: false, angle: 0)
      placement = @document.place(code, x, y, size, angle)
      @items << [:qr, placement, color, background, quiet, gain, cross]
      placement
    end

    # MVG for a +width+ x +height+ pixel canvas at +scale+ px/mm, or with
    # an +affine+ (Affine, mm to pixels) for rotated/non-square output.
    # Symbols with a non-zero angle are left out (rendered as patches).
    # The canvas colour is ImageMagick's -background when reading the MVG
    # (much faster than painting a +background+ rectangle).
    def to_mvg(scale, width, height, background: nil, affine: nil)
      out = +"viewbox 0 0 #{width} #{height}\n"
      out << "fill '#{background}' stroke none rectangle 0,0 #{width - 1},#{height - 1}\n" if background
      if affine
        raise Error, "symbols cannot be drawn with an affine transform" if @items.any? { |i| i[0] == :qr }

        out << "push graphic-context\naffine #{affine.to_magick}\n"
        @items.each { |item| ScanSim::Mvg.item(out, item, 1.0, crisp: false) }
        out << "pop graphic-context\n"
      else
        @items.each { |item| ScanSim::Mvg.item(out, item, scale) }
      end
      out
    end
  end

  # MVG serialisation of Layer items.
  module Mvg
    module_function

    def num(value)
      format("%.3f", value)
    end

    # Appends one Layer item at +s+ px/mm. +crisp+ snaps filled boxes to
    # whole pixels (only meaningful without a transform).
    def item(out, item, s, crisp: true)
      case item[0]
      when :text then text(out, item, s)
      when :rect then rect(out, item, s, crisp)
      when :line
        _, x1, y1, x2, y2, color, width, opacity, dash = item
        out << "push graphic-context\nfill none stroke '#{color}' stroke-opacity #{opacity} " \
               "stroke-width #{num(width * s)}\n"
        out << "stroke-dasharray #{dash.map { |d| num(d * s) }.join(' ')}\n" if dash
        out << "line #{num(x1 * s)},#{num(y1 * s)} #{num(x2 * s)},#{num(y2 * s)}\npop graphic-context\n"
      when :polyline then polyline(out, item, s)
      when :ellipse
        _, cx, cy, rx, ry, fill, stroke, width, opacity = item
        out << "push graphic-context\n#{paint(fill, stroke, width, opacity, s)}" \
               "ellipse #{num(cx * s)},#{num(cy * s)} #{num(rx * s)},#{num(ry * s)} 0,360\npop graphic-context\n"
      when :push
        _, angle, cx, cy = item
        out << "push graphic-context\ntranslate #{num(cx * s)},#{num(cy * s)}\nrotate #{num(angle)}\n" \
               "translate #{num(-cx * s)},#{num(-cy * s)}\n"
      when :pop then out << "pop graphic-context\n"
      when :qr
        placement = item[1]
        qr(out, placement, s, *item[2..]) if placement.angle.zero?
      end
    end

    # Fill and stroke settings. ("fill-opacity" after "fill none" would
    # turn the fill into translucent black, so it is only set for fills.)
    def paint(fill, stroke, width, opacity, s)
      out = fill ? +"fill '#{fill}' fill-opacity #{opacity} " : +"fill none "
      out << (stroke ? "stroke '#{stroke}' stroke-opacity #{opacity} stroke-width #{num(width * s)}\n" : "stroke none\n")
    end

    def text(out, item, s)
      _, x, y, string, size, font, color, anchor, angle, opacity = item
      out << "push graphic-context\nfont '#{font}'\nfont-size #{num(size * PT * s)}\n" \
             "fill '#{color}' fill-opacity #{opacity} stroke none\ntext-anchor #{anchor}\n" \
             "translate #{num(x * s)},#{num(y * s)}\n"
      out << "rotate #{num(angle)}\n" unless angle.zero?
      out << "text 0,0 '#{string}'\npop graphic-context\n"
    end

    def rect(out, item, s, crisp)
      _, x, y, w, h, fill, stroke, width, radius, opacity, dash = item
      out << "push graphic-context\n#{paint(fill, stroke, width, opacity, s)}"
      out << "stroke-dasharray #{dash.map { |d| num(d * s) }.join(' ')}\n" if dash
      if radius.positive?
        out << "roundrectangle #{num(x * s)},#{num(y * s)} #{num((x + w) * s)},#{num((y + h) * s)} " \
               "#{num(radius * s)},#{num(radius * s)}\n"
      elsif stroke.nil? && crisp
        # Filled boxes on whole pixels: crisp edges, no anti-aliasing seams.
        x0 = (x * s).round
        y0 = (y * s).round
        x1 = ((x + w) * s).round
        y1 = ((y + h) * s).round
        out << "rectangle #{x0},#{y0} #{x1 - 1},#{y1 - 1}\n" if x1 > x0 && y1 > y0
      else
        out << "rectangle #{num(x * s)},#{num(y * s)} #{num((x + w) * s)},#{num((y + h) * s)}\n"
      end
      out << "pop graphic-context\n"
    end

    def polyline(out, item, s)
      _, points, color, width, opacity, smooth, fill, closed = item
      pts = points.map { |px, py| [px * s, py * s] }
      out << "push graphic-context\n#{paint(fill, color, width, opacity, s)}"
      out << "stroke-linecap round stroke-linejoin round\n"
      d = +"M #{num(pts[0][0])} #{num(pts[0][1])}"
      if smooth && pts.size > 2
        pts.each_cons(2).with_index do |(p1, p2), i|
          p0 = pts[[i - 1, 0].max]
          p3 = pts[[i + 2, pts.size - 1].min]
          c1 = [p1[0] + (p2[0] - p0[0]) / 6.0, p1[1] + (p2[1] - p0[1]) / 6.0]
          c2 = [p2[0] - (p3[0] - p1[0]) / 6.0, p2[1] - (p3[1] - p1[1]) / 6.0]
          d << " C #{num(c1[0])} #{num(c1[1])} #{num(c2[0])} #{num(c2[1])} #{num(p2[0])} #{num(p2[1])}"
        end
      else
        pts.drop(1).each { |px, py| d << " L #{num(px)} #{num(py)}" }
      end
      d << " Z" if closed
      out << "path '#{d}'\npop graphic-context\n"
    end

    # Dark modules as pixel-aligned rectangles (merged horizontal runs), so
    # module edges are exact and adjacent modules have no seams. Module
    # edges are rounded to whole pixels like a printer's dot grid.
    def qr(out, placement, s, color, background, quiet, gain, cross, origin: nil)
      code = placement.code
      n = code.modules
      m = placement.module_mm * s
      ox, oy = origin || [placement.x * s, placement.y * s]
      if background
        q = quiet * m
        out << "push graphic-context\nfill '#{background}' stroke none\n" \
               "rectangle #{(ox - q).round},#{(oy - q).round} #{(ox + n * m + q).round - 1},#{(oy + n * m + q).round - 1}\n" \
               "pop graphic-context\n"
      end
      ex = Array.new(n + 1) { |i| (ox + i * m).round }
      ey = Array.new(n + 1) { |i| (oy + i * m).round }
      half = (gain * m / 2).round
      out << "push graphic-context\nfill '#{color}' stroke none\n"
      bits = code.matrix
      n.times do |r|
        c = 0
        while c < n
          unless bits.dark?(c, r)
            c += 1
            next
          end
          start = c
          c += 1 while c < n && bits.dark?(c, r)
          if half >= 0
            box(out, ex[start] - half, ey[r] - half, ex[c] + half, ey[r + 1] + half)
          else
            thin_run(out, bits, n, r, start, c, ex, ey, -half)
          end
        end
      end
      out << "pop graphic-context\n"
      swiss_cross(out, ox + n * m / 2.0, oy + n * m / 2.0, 7.0 * s) if cross
    end

    # A run of dark modules made thinner by +d+ pixels on every side that
    # faces a light module (erosion), split where the neighbours change.
    def thin_run(out, bits, n, r, start, stop, ex, ey, d)
      seg = start
      while seg < stop
        top = r.zero? || !bits.dark?(seg, r - 1)
        bottom = r == n - 1 || !bits.dark?(seg, r + 1)
        e = seg + 1
        while e < stop && (r.zero? || !bits.dark?(e, r - 1)) == top && (r == n - 1 || !bits.dark?(e, r + 1)) == bottom
          e += 1
        end
        box(out, ex[seg] + (seg == start ? d : 0), ey[r] + (top ? d : 0),
            ex[e] - (e == stop ? d : 0), ey[r + 1] - (bottom ? d : 0))
        seg = e
      end
    end

    def box(out, x0, y0, x1, y1)
      out << "rectangle #{x0},#{y0} #{x1 - 1},#{y1 - 1}\n" if x1 > x0 && y1 > y0
    end

    # Swiss cross of the QR-bill (SIX implementation guidelines): a white
    # 7 x 7 mm square with a black square and a white cross, proportions of
    # the official graphic (20 units = 7 mm).
    def swiss_cross(out, cx, cy, side)
      u = side / 20.0
      x0 = cx - side / 2
      y0 = cy - side / 2
      rect = lambda do |color, rx, ry, rw, rh|
        out << "fill '#{color}' rectangle #{(x0 + rx * u).round},#{(y0 + ry * u).round} " \
               "#{(x0 + (rx + rw) * u).round - 1},#{(y0 + (ry + rh) * u).round - 1}\n"
      end
      out << "push graphic-context\nstroke none\n"
      rect.call("white", 0, 0, 20, 20)
      rect.call("black", 0.7, 0.7, 18.6, 18.6)
      rect.call("white", 8.3, 4.0, 3.3, 11.0)
      rect.call("white", 4.4, 7.9, 11.0, 3.3)
      out << "pop graphic-context\n"
    end
  end

  # A printed document: physical size in mm, paper colour and mottling
  # (+texture+: rms variation in percent, 0 = smooth), the printed +ink+
  # layer and +marks+ added after printing (pen, stamps; multiplied on top
  # like real ink).
  class Document
    attr_reader :width, :height, :paper, :texture, :ink, :marks, :placements

    def initialize(width, height, paper: "white", texture: 0.0)
      @width = width.to_f
      @height = height.to_f
      @paper = paper
      @texture = texture
      @ink = Layer.new(self)
      @marks = Layer.new(self)
      @placements = []
    end

    # Registers a printed symbol (called by Layer#qr).
    def place(code, x, y, size, angle = 0)
      placement = Placement.new(code: code, x: x.to_f, y: y.to_f, size: size.to_f, angle: angle.to_f)
      @placements << placement
      placement
    end
  end

  # Print process defects.
  #
  # halftone   - ImageMagick threshold map for screened (non-solid) inks,
  #              e.g. "h6x6a" (clustered dots, 45 degrees); nil = solid inks
  # fade       - 0..1, lightens all ink (faded thermal paper, low toner)
  # starvation - 0..1, ink density varies across the page in bands
  # speckles   - toner specks per 100 cm^2
  # dead_lines - x positions (mm) of dead thermal print-head dots: white
  #              lines along the paper feed
  # copies     - photocopy generations before the scan
  Printing = Data.define(:halftone, :fade, :starvation, :speckles, :dead_lines, :copies) do
    def initialize(halftone: nil, fade: 0.0, starvation: 0.0, speckles: 0.0, dead_lines: [], copies: 0)
      super
    end
  end

  # Scanner settings and the physical situation on the glass.
  #
  # dpi          - Integer or [x, y] (fax: [204, 98] or [204, 196])
  # mode         - one of MODES; +threshold+ (percent) for :threshold
  # blur         - optical blur sigma in scan pixels
  # noise        - sensor noise, rms in gray levels (of 255)
  # rotation     - 0/90/180/270: the page was put on the glass turned clockwise
  # skew         - degrees, clockwise
  # area         - [w, h] mm of the scanned area (nil: just the document;
  #                small documents on a flatbed: e.g. [216, 297])
  # position     - [x, y] mm of the document's top-left corner (after
  #                rotation, before skew) in the area; nil: centred
  # background   - lid / feeder background colour outside the document
  # illumination - [[:gradient, angle, strength], [:shadow, side, width_mm, depth],
  #                 [:vignette, strength]] (multiplicative, final image coordinates;
  #                 side is :left/:right/:top/:bottom)
  # warp         - [[:wave, amplitude_mm, wavelength_mm, phase, axis],
  #                 [:curl, side, width_mm, amount_mm]] (final image coordinates)
  # crease       - {at: [x, y], angle:, shift: [dx, dy], shade:} in document mm:
  #                a fold through +at+; one side shifted, shaded fold line
  # streaks      - [[x_fraction, darkness, width_px], ...] vertical lines from
  #                dust on a sheet-feeder's glass
  Scan = Data.define(:dpi, :mode, :threshold, :blur, :noise, :rotation, :skew, :area, :position,
                     :background, :illumination, :warp, :crease, :streaks) do
    def initialize(dpi: 300, mode: :gray, threshold: 50, blur: 0.5, noise: 0.5, rotation: 0, skew: 0.0, area: nil,
                   position: nil, background: "#f0f0f0", illumination: [], warp: [], crease: nil, streaks: [])
      dpi = [dpi, dpi] if dpi.is_a?(Numeric)
      raise ArgumentError, "unknown scan mode #{mode.inspect}" unless MODES.include?(mode)
      raise ArgumentError, "rotation must be 0, 90, 180 or 270" unless [0, 90, 180, 270].include?(rotation)

      super
    end

    def dpi_x
      dpi[0]
    end

    def dpi_y
      dpi[1]
    end

    def bilevel?
      BILEVEL_MODES.include?(mode)
    end
  end

  # One document page as printed and scanned. Knows the geometry of the
  # result (image size, where each symbol ends up) without rendering.
  class Page
    attr_reader :document, :printing, :scan

    def initialize(document, printing: Printing.new, scan: Scan.new)
      @document = document
      @printing = printing
      @scan = scan
    end

    # Isotropic print/work resolution: twice the scan resolution (so print
    # edges fall between scan pixels), 600 dpi for halftone screens.
    def work_dpi
      return 600 if printing.halftone

      [[2 * [scan.dpi_x, scan.dpi_y].max, 600].min, 300].max
    end

    # Document size in mm after turning it on the glass.
    def turned_size
      [90, 270].include?(scan.rotation) ? [document.height, document.width] : [document.width, document.height]
    end

    # Scanned document size in pixels (before placement on the glass).
    def doc_pixels
      w, h = turned_size
      [(w * scan.dpi_x / MM_PER_INCH).round, (h * scan.dpi_y / MM_PER_INCH).round]
    end

    # Final image size in pixels.
    def size
      w, h = scan.area || turned_size
      [(w * scan.dpi_x / MM_PER_INCH).round, (h * scan.dpi_y / MM_PER_INCH).round]
    end

    # Maps document mm to final image pixels.
    def transform
      glass * Affine.scale(scan.dpi_x / MM_PER_INCH, scan.dpi_y / MM_PER_INCH) * turn
    end

    # Rotation of the document by scan.rotation, in mm.
    def turn
      w = document.width
      h = document.height
      case scan.rotation
      when 90 then Affine.new(a: 0.0, b: -1.0, c: h, d: 1.0, e: 0.0, f: 0.0)
      when 180 then Affine.new(a: -1.0, b: 0.0, c: w, d: 0.0, e: -1.0, f: h)
      when 270 then Affine.new(a: 0.0, b: 1.0, c: 0.0, d: -1.0, e: 0.0, f: w)
      else Affine.identity
      end
    end

    # Placement on the glass: scanned document pixels to final pixels. The
    # physical rotation is conjugated with the (possibly non-square) pixel
    # scaling, so fax pages skew like paper does.
    def glass
      return Affine.identity unless placed?

      sx = scan.dpi_x / MM_PER_INCH
      sy = scan.dpi_y / MM_PER_INCH
      dw, dh = turned_size
      aw, ah = scan.area || [dw, dh]
      px, py = scan.position || [(aw - dw) / 2.0, (ah - dh) / 2.0]
      linear = Affine.scale(sx, sy) * Affine.rotate(scan.skew) * Affine.scale(1 / sx, 1 / sy)
      Affine.translate((px + dw / 2.0) * sx, (py + dh / 2.0) * sy) * linear *
        Affine.translate(-dw / 2.0 * sx, -dh / 2.0 * sy)
    end

    def placed?
      !scan.skew.zero? || !scan.area.nil? || !scan.position.nil?
    end

    # Ground truth for every printed symbol, in final image coordinates.
    def truth
      t = transform
      document.placements.map do |p|
        cx, cy = t.apply(*p.center)
        {
          text: p.code.text, kind: p.code.kind, version: p.code.version, ec: p.code.level,
          modules: p.code.modules, size_mm: p.size.round(2), module_mm: p.module_mm.round(4),
          module_px: [p.module_mm * scan.dpi_x / MM_PER_INCH, p.module_mm * scan.dpi_y / MM_PER_INCH].map { |v| v.round(2) },
          center: [cx.round(1), cy.round(1)],
          angle: ((scan.rotation + scan.skew + p.angle) % 360).round(2)
        }
      end
    end
  end

  # Document content that is not a QR code: text lines, tables, logos,
  # signatures, stamps, 1-D barcodes, DataMatrix-like decoys, photos. Gives
  # a detector realistic things to trip over. All sizes in mm, fonts in pt.
  module Clutter
    WORDS = %w[
      Rechnung Lieferschein Betrag Total Datum Kunde Konto Zahlbar innert Tagen netto Menge Preis
      Artikel Beschreibung Mehrwertsteuer MwSt Zwischensumme Versand Porto Rabatt Skonto Auftrag
      Bestellung Referenz Zahlung Bank Filiale Strasse Postfach Telefon Grüsse freundlichen Bitte
      überweisen Sie den Betrag bis zum auf unser Konto Vielen Dank für Ihren Einkauf Fälligkeit
      facture montant date client compte payable dans jours quantité prix article description TVA
      sous-total livraison remise commande référence paiement banque rue téléphone salutations merci
      invoice amount customer account payable within days quantity price item description subtotal
      shipping discount order reference payment branch street phone regards thank you for your
      the and of to in for with on at by from service support delivery warranty contract period
      monthly annual fee license maintenance hours consulting travel expenses material labour
      Müller Schäfer Zürich Genève Köln Düsseldorf Bühl Österreich Straße Größe Qualität Lösung
    ].freeze
    FONT_WIDTH = { SANS => 0.56, SANS_BOLD => 0.62, SANS_CONDENSED => 0.5, SERIF => 0.46, SERIF_BOLD => 0.5,
                   MONO => 0.6, MONO_BOLD => 0.6 }.freeze

    module_function

    def words(rng, count)
      Array.new(count) { WORDS[rng.rand(WORDS.size)] }.join(" ")
    end

    def amount(rng, max = 5000)
      value = rng.rand * max
      whole = value.floor.to_s.reverse.scan(/\d{1,3}/).join("'").reverse
      format("%s.%02d", whole, (value * 100).round % 100)
    end

    def date(rng)
      format("%02d.%02d.20%02d", rng.rand(1..28), rng.rand(1..12), rng.rand(20..26))
    end

    # Approximate width of +text+ in mm.
    def text_width(text, size, font = SANS)
      text.size * size * PT * FONT_WIDTH.fetch(font, 0.56)
    end

    # Explicit lines of text; returns the y below them.
    def lines(layer, x, y, texts, size: 9, leading: 1.3, font: SANS, color: "black", anchor: :start)
      step = size * PT * leading
      texts.each_with_index { |t, i| layer.text(x, y + i * step, t, size: size, font: font, color: color, anchor: anchor) }
      y + texts.size * step
    end

    # Justified-looking paragraph of random words; returns the y below it.
    def paragraph(layer, rng, x, y, width, lines: 4, size: 9, leading: 1.35, font: SANS, color: "black")
      step = size * PT * leading
      lines.times do |i|
        text = +""
        limit = i == lines - 1 ? width * (0.3 + rng.rand * 0.6) : width
        loop do
          word = WORDS[rng.rand(WORDS.size)]
          break if text_width("#{text} #{word}", size, font) > limit

          text << " " unless text.empty?
          text << word
        end
        layer.text(x, y + i * step, text, size: size, font: font, color: color)
      end
      y + lines * step
    end

    # Table with a shaded header row; returns the y below it.
    def table(layer, rng, x, y, widths, rows: 5, size: 8, grid: true, color: "black", shade: "#e6e6e6")
      height = size * PT * 1.9
      total = widths.sum
      layer.rect(x, y, total, height, fill: shade) if shade
      headers = ["Pos", "Beschreibung", "Menge", "Preis", "Betrag", "MwSt"]
      widths.each_with_index.reduce(x) do |cx, (w, i)|
        layer.text(cx + 1, y + height * 0.68, headers[i % headers.size], size: size, font: SANS_BOLD, color: color)
        cx + w
      end
      rows.times do |r|
        ry = y + (r + 1) * height
        widths.each_with_index.reduce(x) do |cx, (w, i)|
          cell = case i
                 when 0 then (r + 1).to_s
                 when 1 then words(rng, 1 + rng.rand(3))
                 else amount(rng, i == 2 ? 50 : 900)
                 end
          cell = cell[0, (w / (size * PT * 0.56)).floor] if text_width(cell, size) > w - 2
          if i.zero? || i == 1
            layer.text(cx + 1, ry + height * 0.68, cell, size: size, color: color)
          else
            layer.text(cx + w - 1, ry + height * 0.68, cell, size: size, color: color, anchor: :end)
          end
          cx + w
        end
        layer.line(x, ry, x + total, ry, color: color, width: 0.15) if grid
      end
      bottom = y + (rows + 1) * height
      layer.line(x, bottom, x + total, bottom, color: color, width: 0.3)
      if grid
        widths.each_with_index.reduce(x) do |cx, (w, _)|
          layer.line(cx, y, cx, bottom, color: color, width: 0.15)
          cx + w
        end
        layer.line(x + total, y, x + total, bottom, color: color, width: 0.15)
      end
      bottom
    end

    # Company logo of +height+ mm with the company +name+ next to it.
    def logo(layer, rng, x, y, height, name, color: "#1a3c8c")
      case rng.rand(4)
      when 0
        layer.ellipse(x + height / 2, y + height / 2, height / 2, height / 2, fill: color, stroke: nil)
        layer.text(x + height / 2, y + height * 0.66, name[0, 2].upcase, size: height * 1.2, font: SANS_BOLD,
                                                                         color: "white", anchor: :middle)
      when 1
        3.times do |i|
          layer.rect(x + i * height * 0.36, y + height * (0.6 - i * 0.3), height * 0.26, height * (0.4 + i * 0.3),
                     fill: color)
        end
      when 2
        triangle = [[x, y + height], [x + height / 2, y], [x + height, y + height]]
        layer.polyline(triangle, color: color, width: 0.1, fill: color, closed: true)
      else
        layer.rect(x, y, height, height, fill: nil, stroke: color, width: height * 0.12, radius: height * 0.2)
        layer.text(x + height / 2, y + height * 0.72, name[0], size: height * 1.8, font: SERIF_BOLD,
                                                               color: color, anchor: :middle)
      end
      layer.text(x + height * 1.25, y + height * 0.75, name, size: height * 2.0, font: SANS_BOLD, color: color)
    end

    # Handwritten signature: a smooth scribble in ballpoint ink.
    def signature(layer, rng, x, y, width, height, color: "#1b2f9e")
      points = []
      n = 10 + rng.rand(10)
      n.times do |i|
        px = x + width * i / (n - 1.0) + (rng.rand - 0.5) * width * 0.08
        py = y + height * (0.5 + 0.5 * Math.sin(i * 1.7 + rng.rand)) * (0.6 + rng.rand * 0.4)
        points << [px, py]
      end
      layer.polyline(points, color: color, width: 0.35 + rng.rand * 0.15, smooth: true, opacity: 0.9)
      underline = [[x + width * 0.1, y + height * 1.05], [x + width * 0.9, y + height * 0.95]]
      layer.polyline(underline, color: color, width: 0.3, smooth: true, opacity: 0.8)
    end

    # Rubber stamp: double frame, big word, smaller lines; translucent ink.
    def stamp(layer, cx, cy, word, lines: [], color: "#c0152f", angle: -8, width: 46, opacity: 0.8)
      height = 13 + lines.size * 4.5
      layer.rotated(angle, cx, cy) do |l|
        top = cy - height / 2
        ink = { color: color, opacity: opacity }
        l.rect(cx - width / 2, top, width, height, fill: nil, stroke: color, width: 0.9, radius: 2, opacity: opacity)
        l.rect(cx - width / 2 + 1.4, top + 1.4, width - 2.8, height - 2.8, fill: nil, stroke: color, width: 0.35,
                                                                           radius: 1.5, opacity: opacity)
        l.text(cx, top + 10, word, size: 20, font: SANS_BOLD, anchor: :middle, **ink)
        lines.each_with_index do |t, i|
          l.text(cx, top + 15.5 + i * 4.5, t, size: 10, font: SANS_BOLD, anchor: :middle, **ink)
        end
      end
    end

    # Code 128-like 1-D barcode with human-readable digits under it.
    def barcode(layer, rng, x, y, width, height, color: "black", digits: nil)
      units = []
      units << (1 + rng.rand(4)) while units.sum < 180
      unit = width / units.sum.to_f
      cx = x
      units.each_with_index do |u, i|
        layer.rect(cx, y, u * unit, height, fill: color) if i.even?
        cx += u * unit
      end
      digits ||= Array.new(12) { rng.rand(10) }.join
      layer.text(x + width / 2, y + height + 3.2, digits, size: 8, font: MONO, color: color, anchor: :middle)
    end

    # DataMatrix-like symbol (solid L finder, clock track, random data):
    # looks like a 2-D code but is not a QR code.
    def matrix_code(layer, rng, x, y, size, modules: 22, color: "black")
      m = size.to_f / modules
      modules.times do |r|
        modules.times do |c|
          dark = if c.zero? || r == modules - 1 then true
                 elsif r.zero? then c.even?
                 elsif c == modules - 1 then r.odd?
                 else rng.rand < 0.5
                 end
          layer.rect(x + c * m, y + r * m, m, m, fill: color) if dark
        end
      end
    end

    # "Photo": overlapping colour blobs on a tinted rectangle (screened when
    # the document is printed with a halftone).
    def photo(layer, rng, x, y, w, h)
      layer.rect(x, y, w, h, fill: format("#%02x%02x%02x", 150 + rng.rand(80), 150 + rng.rand(80), 150 + rng.rand(80)))
      (6 + rng.rand(6)).times do
        layer.ellipse(x + rng.rand * w, y + rng.rand * h, w * (0.08 + rng.rand * 0.25), h * (0.08 + rng.rand * 0.25),
                      fill: format("#%02x%02x%02x", rng.rand(256), rng.rand(256), rng.rand(256)), stroke: nil,
                      opacity: 0.85)
      end
    end

    # Ballpoint stroke through the given points with a hand's jitter.
    def pen(layer, rng, points, color: "#1b2f9e", width: 0.45)
      jittered = points.map { |px, py| [px + (rng.rand - 0.5) * 0.8, py + (rng.rand - 0.5) * 0.8] }
      layer.polyline(jittered, color: color, width: width, smooth: true, opacity: 0.9)
    end
  end

  module_function

  def magick_version
    out, status = Open3.capture2e("magick", "-version")
    status.success? ? out[/ImageMagick (\S+)/, 1] : nil
  rescue SystemCallError
    nil
  end

  def available?
    !magick_version.nil?
  end

  # Runs a command (Array) with MAGICK_ENV; raises Error with its output on failure.
  def run!(args)
    out, status = Open3.capture2e(MAGICK_ENV, *args)
    raise Error, "#{args.first(3).join(' ')} ... failed (#{status.exitstatus}): #{out[0, 2000]}" unless status.success?

    out
  end

  # File extension for an output +format+.
  def extension(format)
    FORMATS.fetch(format) { raise ArgumentError, "unknown format #{format.inspect}" }[0]
  end

  # Renders +pages+ (scanned with the same resolution) into one file of
  # +format+ at +path+. +quality+: JPEG quality; +seed+: noise seed.
  def render(pages, path, format:, quality: 85, seed: 0)
    _, format_args, bilevel = FORMATS.fetch(format) { raise ArgumentError, "unknown format #{format.inspect}" }
    if bilevel && !pages.all? { |p| p.scan.bilevel? }
      raise ArgumentError, "#{format} needs a black-and-white scan mode"
    end

    format_args = format_args.map { |a| a == "Q" ? quality.to_s : a }
    scan = pages.first.scan
    output = ["-units", "PixelsPerInch", "-density", "#{scan.dpi_x}x#{scan.dpi_y}"]
    output += %w[-colorspace Gray] if scan.mode == :gray && !format_args.include?("Gray")
    output += [*format_args, "-strip", "-define", "png:exclude-chunks=date,time"]
    FileUtils.mkdir_p(File.dirname(path))
    Dir.mktmpdir("scan_sim") do |tmp|
      if pages.size == 1
        run!(page_command(pages.first, seed, tmp, 0) + output + [path])
      else
        files = pages.each_with_index.map do |page, i|
          file = File.join(tmp, "page#{i}.miff")
          run!(page_command(page, seed + 7919 * i, tmp, i) + ["-depth", "8", file])
          file
        end
        run!(["magick", *files] + output + [path])
      end
    end
    path
  end

  # ImageMagick command (without output) that prints and scans +page+.
  def page_command(page, seed, tmp, index)
    rng = Random.new(seed)
    prefix = File.join(tmp, "p#{index}")
    args = ["magick", "-respect-parentheses", "-seed", seed.to_s]
    args += print_args(page, rng, prefix)
    args += scan_args(page, prefix)
    args
  end

  # --- printing ---------------------------------------------------------

  def print_args(page, rng, prefix)
    doc = page.document
    pr = page.printing
    s = page.work_dpi / MM_PER_INCH
    w = (doc.width * s).round
    h = (doc.height * s).round
    File.write("#{prefix}-ink.mvg", doc.ink.to_mvg(s, w, h))
    # Gray and black-and-white scans are simulated in gray from the start
    # (3x cheaper). Every layer is converted before compositing: onto a gray
    # image ImageMagick would use just the red channel of a colour source.
    # (MVG canvases have an alpha channel: drop it, or noise would make the
    # page partly transparent.)
    space = colorspace_args(page)
    args = ["(", "-background", "white", "mvg:#{prefix}-ink.mvg", "-alpha", "off", *space]
    args += patch_args(page, s, w, h, prefix)
    args += ["-ordered-dither", pr.halftone] if pr.halftone
    args += ["+level", "#{(pr.fade * 100).round(1)}%,100%"] if pr.fade.positive?
    if pr.starvation.positive?
      # Screen with s lightens ink by the factor 1 - s: 1 - (1 - ink)(1 - s).
      write_pgm("#{prefix}-bands.pgm", band_profile(rng, 64, pr.starvation), 64, 1)
      args += ["(", "#{prefix}-bands.pgm", "-resize", "#{w}x#{h}!", ")", "-compose", "Screen", "-composite"]
    end
    defects = defects_mvg(doc, pr, rng, s, w, h)
    if defects
      File.write("#{prefix}-defects.mvg", defects)
      args += ["(", "-background", "none", "mvg:#{prefix}-defects.mvg", *space, ")", "-compose", "Over", "-composite"]
    end
    args += ["-alpha", "off", ")"]
    args += ["-rotate", page.scan.rotation.to_s] unless page.scan.rotation.zero?
    dw, dh = page.doc_pixels
    args += ["-compose", "Over", "-scale", "#{dw}x#{dh}!"]
    # Paper and marks are smooth or drawn with anti-aliasing, and copier
    # optics are no sharper than the scanner's: from here on the scan
    # resolution is enough (and much cheaper than the print resolution).
    args += paper_args(doc, dw, dh, space) + ["-compose", "Multiply", "-composite"]
    unless doc.marks.empty?
      tw, th = page.turned_size
      to_px = Affine.scale(dw / tw, dh / th) * page.turn
      args += marks_args(doc.marks.to_mvg(1.0, dw, dh, affine: to_px), prefix, space)
    end
    pr.copies.times { |g| args += photocopy_args(rng, page, dw, dh, "#{prefix}-copy#{g}") }
    args + ["-compose", "Over"]
  end

  def colorspace_args(page)
    page.scan.mode == :color ? %w[-colorspace sRGB] : %w[-colorspace Gray]
  end

  # Pen and stamp ink, multiplied onto the page.
  def marks_args(mvg, prefix, space)
    File.write("#{prefix}-marks.mvg", mvg)
    ["(", "-background", "white", "mvg:#{prefix}-marks.mvg", "-alpha", "off", *space, ")",
     "-compose", "Multiply", "-composite"]
  end

  # Symbols printed at an angle: rendered upright on their own patch,
  # rotated and composited (opaque where they have a background).
  def patch_args(page, s, w, h, prefix)
    args = []
    page.document.ink.items.each_with_index do |item, i|
      next unless item[0] == :qr && !item[1].angle.zero?

      placement, color, background, quiet, gain, cross = item[1..]
      m = placement.module_mm * s
      side = ((placement.code.modules + 2 * quiet) * m).ceil
      mvg = +"viewbox 0 0 #{side} #{side}\n"
      Mvg.qr(mvg, placement, s, color, background, quiet, gain, cross, origin: [quiet * m, quiet * m])
      File.write("#{prefix}-patch#{i}.mvg", mvg)
      cx, cy = placement.center
      off_x = (cx * s - w / 2.0).round
      off_y = (cy * s - h / 2.0).round
      args += ["(", "-background", "none", "mvg:#{prefix}-patch#{i}.mvg", *colorspace_args(page),
               "-rotate", format("%.3f", placement.angle), ")",
               "-gravity", "center", "-geometry", format("%+d%+d", off_x, off_y), "-compose", "Over", "-composite",
               "-gravity", "NorthWest"]
    end
    args
  end

  # Dead print-head dots (white lines) and toner speckles.
  def defects_mvg(doc, pr, rng, s, w, h)
    return nil if pr.dead_lines.empty? && pr.speckles <= 0

    out = +"viewbox 0 0 #{w} #{h}\n"
    out << "fill none stroke none\n"
    pr.dead_lines.each do |x|
      x0 = (x * s).round
      out << "fill white rectangle #{x0},0 #{x0 + [(0.125 * s).round, 1].max - 1},#{h - 1}\n"
    end
    count = (pr.speckles * doc.width * doc.height / 10_000.0).round
    out << "fill '#222222'\n" if count.positive?
    count.times do
      x = rng.rand * w
      y = rng.rand * h
      r = (0.04 + rng.rand * rng.rand * 0.25) * s
      out << "circle #{Mvg.num(x)},#{Mvg.num(y)} #{Mvg.num(x + r)},#{Mvg.num(y)}\n"
    end
    out
  end

  # Paper colour with mottling (cells of about 2.5 mm; +texture+ is the
  # rms variation in percent).
  def paper_args(doc, w, h, space)
    args = ["(", "-size", "#{w}x#{h}", "xc:#{doc.paper}", *space]
    if doc.texture.positive?
      args += ["(", "-size", "#{(doc.width / 2.5).ceil}x#{(doc.height / 2.5).ceil}", "xc:gray(98%)",
               "-colorspace", "Gray", "-attenuate", format("%.3f", doc.texture / 2.1), "+noise", "Gaussian",
               "-blur", "0x0.8", "-resize", "#{w}x#{h}!", ")", "-compose", "Multiply", "-composite"]
    end
    args << ")"
  end

  # One photocopier generation (at scan resolution): optics blur, harsh
  # contrast, toner specks, a gray band where the lid did not close, slight
  # zoom and skew. The copy comes out on fresh white paper.
  def photocopy_args(rng, page, w, h, prefix)
    s = (page.scan.dpi_x + page.scan.dpi_y) / 2.0 / MM_PER_INCH
    specks = +"viewbox 0 0 #{w} #{h}\nstroke none fill '#1a1a1a'\n"
    (w * h / (s * s) / 4000).round.times do
      x = rng.rand * w
      y = rng.rand * h
      r = (0.03 + rng.rand * 0.12) * s
      specks << "circle #{Mvg.num(x)},#{Mvg.num(y)} #{Mvg.num(x + r)},#{Mvg.num(y)}\n"
    end
    # A gray band along one edge: the copier lid did not close fully.
    edge = rng.rand(4)
    band = (8 + rng.rand * 10) * s
    specks << "fill '#9a9a9a' fill-opacity 0.5\n"
    specks << case edge
              when 0 then "rectangle 0,0 #{band.round},#{h - 1}\n"
              when 1 then "rectangle #{(w - band).round},0 #{w - 1},#{h - 1}\n"
              when 2 then "rectangle 0,0 #{w - 1},#{band.round}\n"
              else "rectangle 0,#{(h - band).round} #{w - 1},#{h - 1}\n"
              end
    File.write("#{prefix}.mvg", specks)
    zoom = 0.985 + rng.rand * 0.015
    angle = (rng.rand - 0.5) * 0.8
    ["-colorspace", "Gray", "-gaussian-blur", "0x#{format('%.2f', 0.04 * s)}", "-level", "14%,86%",
     "-attenuate", "0.25", "+noise", "Gaussian",
     "(", "-background", "white", "mvg:#{prefix}.mvg", "-alpha", "off", "-colorspace", "Gray", ")",
     "-compose", "Multiply", "-composite",
     "-virtual-pixel", "white", "-interpolate", "Bilinear", "-filter", "Point",
     "-distort", "SRT", format("%.4f %.3f", zoom, angle), "+filter", *colorspace_args(page)]
  end

  # --- scanning ---------------------------------------------------------

  def scan_args(page, prefix)
    sc = page.scan
    gw, gh = page.size
    args = []
    if page.placed?
      args += ["-virtual-pixel", "background", "-background", sc.background, "-interpolate", "Bilinear",
               "-filter", "Point", "-define", "distort:viewport=#{gw}x#{gh}+0+0", "-distort", "AffineProjection",
               page.glass.to_magick, "+filter", "+repage"]
    end
    unless sc.warp.empty? && sc.crease.nil?
      scale = write_displacement("#{prefix}-warp.ppm", page, gw, gh)
      # Displace takes x from the map's red and y from its green channel,
      # but only on a colour image.
      args += ["-virtual-pixel", "background", "-background", sc.background, "-colorspace", "sRGB",
               "(", "#{prefix}-warp.ppm", "-resize", "#{gw}x#{gh}!", ")",
               "-compose", "Displace", "-define", "compose:args=#{scale}x#{scale}", "-composite", "-compose", "Over",
               *colorspace_args(page)]
    end
    args += ["-draw", crease_mvg(page)] if sc.crease
    if sc.warp.any? { |w| w[0] == :curl }
      # The lifted paper near a book spine is out of focus.
      write_pgm("#{prefix}-focus.pgm", *curl_mask(page, gw, gh))
      args += ["(", "+clone", "-gaussian-blur", "0x#{format('%.2f', 1.2 * sc.dpi_x / 200.0)}", ")",
               "(", "#{prefix}-focus.pgm", "-resize", "#{gw}x#{gh}!", ")", "-compose", "Over", "-composite"]
    end
    unless sc.illumination.empty?
      write_pgm("#{prefix}-light.pgm", *illumination_map(page, gw, gh))
      args += ["(", "#{prefix}-light.pgm", "-resize", "#{gw}x#{gh}!", *colorspace_args(page), ")",
               "-compose", "Multiply", "-composite",
               "-compose", "Over"]
    end
    sc.streaks.each do |x, darkness, width|
      x0 = (x * gw).round
      args += ["-draw", "fill 'gray(#{((1 - darkness) * 100).round}%)' stroke none rectangle #{x0},0 " \
                        "#{x0 + [width.round, 1].max - 1},#{gh - 1}"]
    end
    args += ["-alpha", "off"]
    args += ["-gaussian-blur", "0x#{format('%.2f', sc.blur)}"] if sc.blur.positive?
    args += ["-attenuate", format("%.3f", sc.noise / NOISE_LEVELS), "+noise", "Gaussian"] if sc.noise.positive?
    args + mode_args(sc)
  end

  # Conversion to the scanner's output mode.
  def mode_args(sc)
    case sc.mode
    when :color then []
    when :gray then %w[-colorspace Gray]
    when :threshold then ["-colorspace", "Gray", "-threshold", "#{sc.threshold}%"]
    when :adaptive
      # Local mean threshold (6 mm window), plus a global one so that large
      # dark areas are not hollowed out.
      win = (6 * sc.dpi_x / MM_PER_INCH).round
      ["-colorspace", "Gray", "(", "+clone", "-lat", "#{win}x#{win}-6%", ")",
       "(", "-clone", "0", "-threshold", "#{sc.threshold - 20}%", ")", "-delete", "0",
       "-compose", "Multiply", "-composite", "-compose", "Over"]
    when :ordered then %w[-colorspace Gray -ordered-dither o8x8]
    when :diffusion then %w[-colorspace Gray -dither FloydSteinberg -monochrome]
    end
  end

  # Fold line across the document: a dark crease with a faint highlight
  # next to it.
  def crease_mvg(page)
    c = page.scan.crease
    t = page.transform
    x, y = t.apply(*c[:at])
    rad = c[:angle] * Math::PI / 180
    dx, dy = t.apply_vector(Math.cos(rad), Math.sin(rad))
    len = Math.hypot(dx, dy)
    dx /= len
    dy /= len
    doc = page.document
    corners = [[0, 0], [doc.width, 0], [doc.width, doc.height], [0, doc.height]].map { |p| t.apply(*p) }
    t0, t1 = clip_line(x, y, dx, dy, corners) || [0.0, 0.0]
    width = [page.scan.dpi_x / 150.0, 1.0].max
    nx = -dy * width
    ny = dx * width
    pts = lambda do |ox, oy|
      "#{Mvg.num(x + ox + dx * t0)},#{Mvg.num(y + oy + dy * t0)} #{Mvg.num(x + ox + dx * t1)},#{Mvg.num(y + oy + dy * t1)}"
    end
    "stroke-linecap butt fill none stroke 'gray(35%)' stroke-opacity #{format('%.2f', c[:shade])} " \
      "stroke-width #{Mvg.num(width)} line #{pts.call(0, 0)} " \
      "stroke 'gray(70%)' stroke-opacity #{format('%.2f', c[:shade] / 2)} stroke-width #{Mvg.num(width * 3)} " \
      "line #{pts.call(-nx * 2, -ny * 2)}"
  end

  # Parameter range [t0, t1] of the line (x, y) + t (dx, dy) inside the
  # convex polygon +corners+ (clockwise or counter-clockwise), or nil.
  def clip_line(x, y, dx, dy, corners)
    t0 = -Float::INFINITY
    t1 = Float::INFINITY
    area = corners.each_with_index.sum do |(ax, ay), i|
      bx, by = corners[(i + 1) % corners.size]
      ax * by - bx * ay
    end
    sign = area.positive? ? 1 : -1
    corners.each_with_index do |(ax, ay), i|
      bx, by = corners[(i + 1) % corners.size]
      # Inside: sign * cross(b - a, p - a) >= 0.
      ex = bx - ax
      ey = by - ay
      base = sign * (ex * (y - ay) - ey * (x - ax))
      slope = sign * (ex * dy - ey * dx)
      if slope.abs < 1e-12
        return nil if base.negative?
      elsif slope.positive?
        t0 = [t0, -base / slope].max
      else
        t1 = [t1, -base / slope].min
      end
    end
    t0 < t1 ? [t0, t1] : nil
  end

  # Low-resolution grid used for smooth maps of a +gw+ x +gh+ image:
  # [map width, map height].
  def map_grid(gw, gh, longest: 384)
    f = [gw, gh].max / longest.to_f
    f = 1.0 if f < 1
    [(gw / f).ceil, (gh / f).ceil]
  end

  # Writes the displacement map (R = x, G = y source offset, 16 bit) and
  # returns the ImageMagick displacement scale in pixels.
  def write_displacement(path, page, gw, gh)
    mw, mh = map_grid(gw, gh)
    sx = page.scan.dpi_x / MM_PER_INCH
    sy = page.scan.dpi_y / MM_PER_INCH
    crease = crease_geometry(page)
    field = Array.new(mw * mh)
    max = 1.0
    mh.times do |j|
      y = (j + 0.5) * gh / mh
      mw.times do |i|
        x = (i + 0.5) * gw / mw
        dx = 0.0
        dy = 0.0
        page.scan.warp.each do |kind, *a|
          case kind
          when :wave
            amp, wavelength, phase, axis = a
            if axis == :y
              dx += amp * sx * Math.sin(2 * Math::PI * (y / sy) / wavelength + phase)
            else
              dy += amp * sy * Math.sin(2 * Math::PI * (x / sx) / wavelength + phase)
            end
          when :curl
            ddx, ddy = curl_offset(a, x, y, gw, gh, sx, sy)
            dx += ddx
            dy += ddy
          end
        end
        if crease
          px, py, nx, ny, shift_x, shift_y, soft = crease
          d = (x - px) * nx + (y - py) * ny
          if d > -soft
            t = d >= soft ? 1.0 : (d + soft) / (2 * soft)
            t = t * t * (3 - 2 * t)
            dx -= shift_x * t
            dy -= shift_y * t
          end
        end
        field[j * mw + i] = [dx, dy]
        max = dx.abs if dx.abs > max
        max = dy.abs if dy.abs > max
      end
    end
    scale = (max + 1).ceil
    data = field.map { |dx, dy| [32_768 + (dx / scale * 32_767).round, 32_768 + (dy / scale * 32_767).round, 32_768] }
    File.binwrite(path, "P6\n#{mw} #{mh}\n65535\n".b + data.flatten.map { |v| v.clamp(0, 65_535) }.pack("n*"))
    scale
  end

  # Crease line in final pixels: [x, y, normal x, normal y, shift x, shift y, softness].
  def crease_geometry(page)
    c = page.scan.crease
    return nil unless c

    t = page.transform
    x, y = t.apply(*c[:at])
    rad = c[:angle] * Math::PI / 180
    dx, dy = t.apply_vector(Math.cos(rad), Math.sin(rad))
    len = Math.hypot(dx, dy)
    sx, sy = t.apply_vector(*c[:shift])
    [x, y, -dy / len, dx / len, sx, sy, 0.6 * page.scan.dpi_x / MM_PER_INCH]
  end

  # Book-spine curl: the paper rises off the glass near +side+, so content
  # there is compressed towards the spine and slightly shrunk vertically.
  def curl_offset(args, x, y, gw, gh, sx, sy)
    side, width, amount = args
    d, along, extent = case side
                       when :left then [x / sx, y, gh]
                       when :right then [(gw - x) / sx, y, gh]
                       when :top then [y / sy, x, gw]
                       else [(gh - y) / sy, x, gw]
                       end
    return [0.0, 0.0] if d >= width

    t = (1 - d / width)**2
    push = amount * t
    shrink = 0.04 * t * (along - extent / 2.0)
    case side
    when :left then [push * sx, shrink]
    when :right then [-push * sx, shrink]
    when :top then [shrink, push * sy]
    else [shrink, -push * sy]
    end
  end

  # Mask (white = blurred) for the out-of-focus band of a curl.
  def curl_mask(page, gw, gh)
    mw, mh = map_grid(gw, gh)
    sx = page.scan.dpi_x / MM_PER_INCH
    sy = page.scan.dpi_y / MM_PER_INCH
    curls = page.scan.warp.select { |w| w[0] == :curl }
    values = Array.new(mw * mh) do |k|
      x = (k % mw + 0.5) * gw / mw
      y = (k / mw + 0.5) * gh / mh
      curls.map do |_, side, width, _|
        d = case side
            when :left then x / sx
            when :right then (gw - x) / sx
            when :top then y / sy
            else (gh - y) / sy
            end
        d >= width ? 0.0 : (1 - d / width)**1.5
      end.max
    end
    [values, mw, mh]
  end

  # Multiplicative illumination map: [values 0..1, width, height].
  def illumination_map(page, gw, gh)
    mw, mh = map_grid(gw, gh)
    sx = page.scan.dpi_x / MM_PER_INCH
    sy = page.scan.dpi_y / MM_PER_INCH
    values = Array.new(mw * mh) do |k|
      u = (k % mw + 0.5) / mw
      v = (k / mw + 0.5) / mh
      page.scan.illumination.reduce(1.0) do |gain, (kind, *a)|
        gain * case kind
               when :gradient
                 rad = a[0] * Math::PI / 180
                 proj = (u - 0.5) * Math.cos(rad) + (v - 0.5) * Math.sin(rad)
                 1 - a[1] * (proj + 0.5).clamp(0.0, 1.0)
               when :shadow
                 side, width, depth = a
                 d = case side
                     when :left then u * gw / sx
                     when :right then (1 - u) * gw / sx
                     when :top then v * gh / sy
                     else (1 - v) * gh / sy
                     end
                 1 - depth * Math.exp(-d / width)
               when :vignette
                 1 - a[0] * (((u - 0.5)**2 + (v - 0.5)**2) * 2)
               else 1.0
               end
      end
    end
    [values, mw, mh]
  end

  # Smooth random profile in 0..amount: how much ink is missing across the page.
  def band_profile(rng, n, amount)
    waves = Array.new(3) { [rng.rand * 6 + 1, rng.rand * 2 * Math::PI, rng.rand] }
    total = waves.sum { |w| w[2] }
    Array.new(n) do |i|
      t = i / (n - 1.0)
      s = waves.sum { |f, ph, a| a * (0.5 + 0.5 * Math.sin(2 * Math::PI * f * t + ph)) } / total
      amount * s
    end
  end

  # 16-bit PGM of +values+ (0..1).
  def write_pgm(path, values, width, height)
    body = values.map { |v| (v.clamp(0.0, 1.0) * 65_535).round }.pack("n*")
    File.binwrite(path, "P5\n#{width} #{height}\n65535\n".b + body)
  end
end
