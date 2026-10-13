# frozen_string_literal: true

require "qr_reader/image"
require "open3"

# Deterministic image distortions for robustness tests and benchmarks. Every
# function takes a QrReader::Image and returns a new one; randomness comes
# only from the given +seed+.
#
#   img = QrTestEncoder.build("HELLO").to_image(module_size: 6)
#   img = Distort.perspective_tilt(img, strength: 0.2, seed: 3)
#   img = Distort.blur(Distort.gaussian_noise(img, sigma: 12, seed: 1), 1.0)
#   img = Distort.apply(img, [[:gradient, { from: 1.0, to: 0.4 }], [:jpeg, { quality: 30 }]])
#
# Geometric warps use inverse mapping with bilinear sampling and treat the
# area outside the source as +background+. The perspective convention (corner
# order TL, TR, BR, BL; pixel centres at +0.5) matches QrTestHelper.warp.
module Distort
  # Raised when an optional dev tool (ImageMagick for JPEG) is missing.
  class Unavailable < StandardError; end

  IDENTITY_TABLE = QrReader::Image::TR_ESCAPE.call((0..255).to_a)
  private_constant :IDENTITY_TABLE

  # Bilinear sampling of an image at pixel-centre coordinates (u, v), in
  # 1/256 gray levels; +background+ (also 1/256 units) when more than half a
  # pixel outside. Clamping is done in Float only, which keeps the call
  # sites monomorphic (noticeably faster under YJIT).
  class BilinearSampler
    attr_reader :background

    def initialize(image, background)
      @src = image.data
      @width = image.width
      @max_x = image.width - 1
      @max_y = image.height - 1
      @max_u = @max_x.to_f
      @max_v = @max_y.to_f
      @u_limit = image.width - 0.5
      @v_limit = image.height - 0.5
      @background = background * 256
    end

    def at(u, v)
      # Written so that NaN coordinates also yield the background.
      return @background unless u >= -0.5 && v >= -0.5 && u <= @u_limit && v <= @v_limit

      ui = ((u < 0.0 ? 0.0 : (u > @max_u ? @max_u : u)) * 256.0).to_i
      vi = ((v < 0.0 ? 0.0 : (v > @max_v ? @max_v : v)) * 256.0).to_i
      src = @src
      x0 = ui >> 8
      fx = ui & 255
      fy = vi & 255
      x1 = x0 < @max_x ? x0 + 1 : x0
      y0 = vi >> 8
      r0 = y0 * @width
      r1 = y0 < @max_y ? r0 + @width : r0
      top = src.getbyte(r0 + x0) * (256 - fx) + src.getbyte(r0 + x1) * fx
      bottom = src.getbyte(r1 + x0) * (256 - fx) + src.getbyte(r1 + x1) * fx
      (top * (256 - fy) + bottom * fy) >> 8
    end
  end
  private_constant :BilinearSampler

  module_function

  # Applies a list of steps in order. A step is a method name, optionally
  # followed by positional arguments and/or an options Hash:
  # [:invert, [:blur, 1.5], [:gradient, { to: 0.3 }], [:scale, 0.5]].
  # Steps that take a seed get +seed+ + their index unless they specify one.
  def apply(image, steps, seed: 0)
    steps.each_with_index.reduce(image) do |img, (step, i)|
      name, *args = Array(step)
      raise ArgumentError, "unknown distortion step #{step.inspect}" unless STEPS.include?(name)

      opts = args.last.is_a?(Hash) ? args.pop.dup : {}
      opts[:seed] ||= seed + i if method(name).parameters.any? { |_, key| key == :seed }
      public_send(name, img, *args, **opts)
    end
  end

  # --- photometric ---------------------------------------------------------

  # Maps every pixel through a 256-entry lookup table (C speed via String#tr).
  # Values are rounded and clamped to 0..255 (infinities included).
  def lut(image, table)
    raise ArgumentError, "lookup table needs 256 entries, got #{table.size}" unless table.size == 256
    raise ArgumentError, "lookup table contains NaN" if table.any? { |v| v.respond_to?(:nan?) && v.nan? }

    to = QrReader::Image::TR_ESCAPE.call(table.map { |v| v.clamp(0, 255).round })
    QrReader::Image.new(image.width, image.height, image.data.tr(IDENTITY_TABLE, to))
  end

  # Linear contrast reduction: black becomes +low+, white becomes +high+.
  def contrast(image, low: 64, high: 192)
    lut(image, (0..255).map { |v| low + (high - low) * v / 255.0 })
  end

  # Brightness offset (positive = lighter), clamped.
  def brightness(image, offset)
    lut(image, (0..255).map { |v| v + offset })
  end

  def gamma(image, value)
    lut(image, (0..255).map { |v| 255.0 * ((v / 255.0)**value) })
  end

  def invert(image)
    image.invert
  end

  def mirror(image)
    image.mirror
  end

  # Multiplicative illumination falling linearly from +from+ to +to+ along
  # the direction +angle+ (degrees, 0 = left to right, 90 = top to bottom).
  def gradient(image, from: 1.0, to: 0.4, angle: 0)
    w = image.width
    h = image.height
    rad = angle * Math::PI / 180
    dx = Math.cos(rad)
    dy = Math.sin(rad)
    # Projection range of the image corners onto the direction.
    projections = [[0, 0], [w - 1, 0], [0, h - 1], [w - 1, h - 1]].map { |x, y| x * dx + y * dy }
    pmin, pmax = projections.minmax
    span = [pmax - pmin, 1e-9].max
    # Factor in 1/65536 units; it changes by a constant step per pixel.
    step_x = ((to - from) * dx / span * 65_536).round
    step_y = ((to - from) * dy / span * 65_536).round
    base = ((from - (to - from) * pmin / span) * 65_536).round
    scale_pixels(image) { |y| [base + step_y * y, step_x] }
  end

  # Radial darkening towards the corners: the factor is 1 at the centre and
  # 1 - +strength+ at the corners (quadratic falloff; negative strengths
  # brighten). Results are clamped to 0..255.
  def vignette(image, strength: 0.5)
    w = image.width
    h = image.height
    src = image.data
    out = "\0".b * (w * h)
    cx2 = w - 1 # doubled coordinates avoid fractions
    cy2 = h - 1
    r2max = cx2 * cx2 + cy2 * cy2
    r2max = 1 if r2max.zero?
    k = (strength * 65_536).round
    y = 0
    while y < h
      dy = 2 * y - cy2
      dy2 = dy * dy
      x = 0
      off = y * w
      while x < w
        dx = 2 * x - cx2
        f = 65_536 - k * (dx * dx + dy2) / r2max
        v = (src.getbyte(off + x) * f) >> 16
        out.setbyte(off + x, v.negative? ? 0 : (v > 255 ? 255 : v))
        x += 1
      end
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # A straight-edged shadow over part of the image: pixels on one side of a
  # random line are multiplied by 1 - +darkness+, with a linear penumbra of
  # +softness+ (fraction of the image diagonal). Results are clamped to 0..255.
  def shadow(image, darkness: 0.5, softness: 0.05, seed: 0)
    rng = Random.new(seed)
    w = image.width
    h = image.height
    angle = rng.rand * 2 * Math::PI
    nx = Math.cos(angle)
    ny = Math.sin(angle)
    # The line passes through a random point in the middle 60 % of the image.
    px = w * (0.2 + 0.6 * rng.rand)
    py = h * (0.2 + 0.6 * rng.rand)
    diag = Math.sqrt(w * w + h * h)
    soft = [softness * diag, 1.0].max
    lit = 65_536
    dark = ((1 - darkness) * 65_536).round
    # Signed distance d from the line; factor = dark for d <= -soft/2, lit for
    # d >= soft/2, linear in between. Computed per pixel in 1/65536 units.
    slope = (lit - dark) / soft
    w_dist = lambda { |x, y| (x - px) * nx + (y - py) * ny }
    src = image.data
    out = "\0".b * (w * h)
    y = 0
    while y < h
      d = w_dist.call(0, y)
      x = 0
      off = y * w
      while x < w
        f = if d <= -soft / 2 then dark
            elsif d >= soft / 2 then lit
            else dark + ((d + soft / 2) * slope).to_i
            end
        v = (src.getbyte(off + x) * f) >> 16
        out.setbyte(off + x, v.negative? ? 0 : (v > 255 ? 255 : v))
        d += nx
        x += 1
      end
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # Additive gaussian noise with standard deviation +sigma+ (gray levels).
  def gaussian_noise(image, sigma: 10, seed: 0)
    rng = Random.new(seed)
    table = Array.new(65_536) do
      # Box-Muller; 1 - rand avoids log(0).
      (Math.sqrt(-2 * Math.log(1 - rng.rand)) * Math.cos(2 * Math::PI * rng.rand) * sigma).round
    end
    n = image.size
    picks = rng.bytes(2 * n).unpack("v*") # little-endian: identical on every platform
    src = image.data
    out = "\0".b * n
    i = 0
    while i < n
      v = src.getbyte(i) + table[picks[i]]
      out.setbyte(i, v.negative? ? 0 : (v > 255 ? 255 : v))
      i += 1
    end
    QrReader::Image.new(image.width, image.height, out)
  end

  # Sets a fraction +amount+ (0..1) of the pixels to black or white at
  # random (positions may repeat).
  def salt_pepper(image, amount: 0.02, seed: 0)
    rng = Random.new(seed)
    n = image.size
    out = image.data.dup
    (amount.clamp(0.0, 1.0) * n).round.times { out.setbyte(rng.rand(n), rng.rand(2) * 255) }
    QrReader::Image.new(image.width, image.height, out)
  end

  # Gaussian-like blur: three successive box blurs approximating standard
  # deviation +sigma+ (pixels). Edges are clamped.
  def blur(image, sigma)
    raise ArgumentError, "blur sigma must be finite, got #{sigma.inspect}" unless sigma.finite?
    return image if sigma <= 0

    box_sizes(sigma, 3).reduce(image) { |img, size| box_blur(img, (size - 1) / 2) }
  end

  # Separable box blur with the given radius (window 2r+1), edges clamped.
  def box_blur(image, radius)
    return image if radius < 1

    vertical_box(horizontal_box(image, radius), radius)
  end

  # Linear motion blur: average of +length+ samples along +angle+ (degrees).
  def motion_blur(image, length: 7, angle: 0)
    return image if length < 2

    w = image.width
    h = image.height
    rad = angle * Math::PI / 180
    # Whole-pixel steps -length/2 ... (length - 1)/2: centring an even
    # length at half-pixel positions and rounding half away from zero would
    # skip the centre pixel (-4, -3, -2, -1, 1, 2, 3, 4 for length 8).
    # Offsets beyond the image size all land on the replicated edge, so
    # they are clamped (bounding the padding) and equal ones are merged
    # into weights (bounding the work per pixel).
    offsets = Array.new(length) do |i|
      t = i - length / 2
      [(t * Math.cos(rad)).round.clamp(-w, w), (t * Math.sin(rad)).round.clamp(-h, h)]
    end.tally
    margin = offsets.keys.flatten.map(&:abs).max
    padded = pad_replicate(image, margin)
    pw = w + 2 * margin
    deltas = offsets.keys.map { |dx, dy| dy * pw + dx }
    weights = offsets.values
    src = padded.data
    out = "\0".b * (w * h)
    count = deltas.size
    half = length / 2
    y = 0
    while y < h
      base = (y + margin) * pw + margin
      off = y * w
      x = 0
      while x < w
        s = 0
        k = 0
        while k < count
          s += src.getbyte(base + x + deltas[k]) * weights[k]
          k += 1
        end
        out.setbyte(off + x, (s + half) / length)
        x += 1
      end
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # --- geometric -----------------------------------------------------------

  # Resamples by +factor+ (e.g. 0.25 turns 6 px/module into 1.5 px/module):
  # area averaging when shrinking, bilinear interpolation when enlarging.
  def scale(image, factor)
    raise ArgumentError, "scale factor must be positive and finite, got #{factor.inspect}" unless factor.positive? && factor.finite?

    out_w = [(image.width * factor).round, 1].max
    out_h = [(image.height * factor).round, 1].max
    resize(image, out_w, out_h)
  end

  def resize(image, out_w, out_h)
    unless out_w.is_a?(Integer) && out_h.is_a?(Integer) && out_w.positive? && out_h.positive?
      raise ArgumentError, "invalid output size #{out_w.inspect}x#{out_h.inspect}"
    end

    xw = resample_weights(image.width, out_w)
    yw = resample_weights(image.height, out_h)
    w = image.width
    h = image.height
    src = image.data
    # Horizontal pass into an Integer buffer (values scaled by 2**12).
    tmp = Array.new(out_w * h, 0)
    y = 0
    while y < h
      off = y * w
      toff = y * out_w
      x = 0
      while x < out_w
        idx, wts = xw[x]
        s = 0
        k = 0
        n = idx.size
        while k < n
          s += src.getbyte(off + idx[k]) * wts[k]
          k += 1
        end
        tmp[toff + x] = s
        x += 1
      end
      y += 1
    end
    out = "\0".b * (out_w * out_h)
    round = 1 << 23
    y = 0
    while y < out_h
      idx, wts = yw[y]
      n = idx.size
      off = y * out_w
      x = 0
      while x < out_w
        s = 0
        k = 0
        while k < n
          s += tmp[idx[k] * out_w + x] * wts[k]
          k += 1
        end
        v = (s + round) >> 24
        out.setbyte(off + x, v > 255 ? 255 : v)
        x += 1
      end
      y += 1
    end
    QrReader::Image.new(out_w, out_h, out)
  end

  # Maps the source image's corners to +corners+ ([[x, y]] * 4: TL, TR, BR,
  # BL) on an +out_w+ x +out_h+ canvas. Same geometry as QrTestHelper.warp.
  #
  # The products a * px, d * px, g * px are tabulated once per column; the
  # arithmetic (and so every output byte) is the same as evaluating the
  # transform per sample, about 20 % faster with and without YJIT.
  def perspective(image, corners, out_w, out_h, background: 255, supersample: 1)
    inv = invert3(square_to_quad(corners))
    sw = image.width
    sh = image.height
    a, b, c, d, e, f, g, hh, i = inv
    # Fold the unit-square -> pixel scaling into the inverse transform.
    a *= sw
    b *= sw
    c *= sw
    d *= sh
    e *= sh
    f *= sh
    sampler = BilinearSampler.new(image, background)
    bg = sampler.background
    ss = supersample
    offsets = Array.new(ss) { |k| (k + 0.5) / ss }
    samples = ss * ss
    round = samples * 128
    divisor = samples * 256
    # Column tables, indexed by x * ss + ox.
    sub_xs = Array.new(out_w * ss) { |k| (k / ss) + offsets[k % ss] }
    ax = sub_xs.map { |px| a * px }
    dx = sub_xs.map { |px| d * px }
    gx = sub_xs.map { |px| g * px }
    acc = Array.new(out_w, 0)
    out = "\0".b * (out_w * out_h)
    y = 0
    while y < out_h
      acc.fill(0)
      oy = 0
      while oy < ss
        py = y + offsets[oy]
        bpy = b * py
        epy = e * py
        hpy = hh * py
        k = 0
        x = 0
        while x < out_w
          sum = 0
          ox = 0
          while ox < ss
            den = gx[k] + hpy + i
            # den <= 0: the point lies on or behind the camera's horizon.
            sum += den <= 0 ? bg : sampler.at((ax[k] + bpy + c) / den - 0.5, (dx[k] + epy + f) / den - 0.5)
            k += 1
            ox += 1
          end
          acc[x] += sum
          x += 1
        end
        oy += 1
      end
      off = y * out_w
      x = 0
      while x < out_w
        out.setbyte(off + x, (acc[x] + round) / divisor)
        x += 1
      end
      y += 1
    end
    QrReader::Image.new(out_w, out_h, out)
  end

  # Random perspective tilt: each corner moves inwards by up to +strength+ of
  # the image size; the canvas keeps the input size.
  def perspective_tilt(image, strength: 0.2, seed: 0, background: 255)
    rng = Random.new(seed)
    w = image.width
    h = image.height
    jitter = ->(size) { rng.rand * strength * size }
    corners = [
      [jitter.(w), jitter.(h)], [w - jitter.(w), jitter.(h)],
      [w - jitter.(w), h - jitter.(h)], [jitter.(w), h - jitter.(h)]
    ]
    perspective(image, corners, w, h, background: background, supersample: 2)
  end

  # Rotation by an arbitrary angle (degrees, counter-clockwise) onto a canvas
  # that holds the whole result plus +margin+, like QrTestHelper.rotate.
  def rotate(image, degrees, margin: 10, background: 255)
    rad = degrees * Math::PI / 180
    cos = Math.cos(rad)
    sin = Math.sin(rad)
    w = image.width
    h = image.height
    pts = [[0, 0], [w, 0], [w, h], [0, h]].map { |x, y| [x * cos + y * sin, -x * sin + y * cos] }
    min_x, max_x = pts.map(&:first).minmax
    min_y, max_y = pts.map(&:last).minmax
    out_w = (max_x - min_x).ceil + 2 * margin
    out_h = (max_y - min_y).ceil + 2 * margin
    corners = pts.map { |x, y| [x - min_x + margin, y - min_y + margin] }
    perspective(image, corners, out_w, out_h, background: background, supersample: 2)
  end

  # Wraps the image around a vertical cylinder seen from the front: the full
  # width covers +arc+ degrees of the circumference (60 = mild, 150 = strong,
  # up to 360; beyond 180 the outer parts are hidden behind the cylinder;
  # 0 leaves the image flat). +bulge+ adds the vertical magnification of
  # the nearer middle part.
  def cylinder(image, arc: 90, bulge: 0.05, background: 255)
    raise ArgumentError, "arc must be 0..360 degrees, got #{arc.inspect}" unless arc.between?(0, 360)
    return image if arc.zero?

    w = image.width
    h = image.height
    half_arc = arc * Math::PI / 360
    radius = (w / 2.0) / half_arc
    cx = w / 2.0
    cy = h / 2.0
    # Half width of the visible (front) side in the output.
    limit = half_arc >= Math::PI / 2 ? radius : radius * Math.sin(half_arc)
    # Per output column: source x and vertical scale (source x is nil off
    # the cylinder).
    us = Array.new(w)
    scales = Array.new(w, 1.0)
    w.times do |x|
      px = x + 0.5 - cx
      next if px.abs > limit

      theta = Math.asin(px / radius)
      us[x] = cx + radius * theta - 0.5
      scales[x] = 1 + bulge * (Math.cos(theta) - Math.cos(half_arc))
    end
    sampler = BilinearSampler.new(image, background)
    out = "\0".b * (w * h)
    y = 0
    while y < h
      dy = y + 0.5 - cy
      off = y * w
      x = 0
      while x < w
        u = us[x]
        out.setbyte(off + x, u ? (sampler.at(u, cy + dy / scales[x] - 0.5) + 128) >> 8 : background)
        x += 1
      end
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # Radial lens distortion: k > 0 gives barrel distortion (straight lines bow
  # outwards), k < 0 pincushion. k is relative to the half diagonal.
  def barrel(image, k: 0.1, background: 255)
    w = image.width
    h = image.height
    cx = w / 2.0
    cy = h / 2.0
    r2max = cx * cx + cy * cy
    kr = k / r2max
    sampler = BilinearSampler.new(image, background)
    out = "\0".b * (w * h)
    y = 0
    while y < h
      dy = y + 0.5 - cy
      dy2 = dy * dy
      off = y * w
      x = 0
      while x < w
        dx = x + 0.5 - cx
        s = 1 + kr * (dx * dx + dy2)
        out.setbyte(off + x, (sampler.at(cx + dx * s - 0.5, cy + dy * s - 0.5) + 128) >> 8)
        x += 1
      end
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # Surrounds the image with a border of +margin+ pixels of +value+.
  def pad(image, margin, value: 255)
    w = image.width
    nw = w + 2 * margin
    fill = value.chr.b
    side = fill * margin
    out = String.new(capacity: nw * (image.height + 2 * margin), encoding: Encoding::BINARY)
    blank = fill * nw
    margin.times { out << blank }
    image.height.times { |y| out << side << image.row(y) << side }
    margin.times { out << blank }
    QrReader::Image.new(nw, image.height + 2 * margin, out)
  end

  # Pastes +placements+ ([[image, x, y], ...]) onto a new canvas.
  def compose(width, height, placements, background: 255)
    out = background.chr.b * (width * height)
    placements.each do |img, x0, y0|
      raise ArgumentError, "placement outside canvas" if x0.negative? || y0.negative? || x0 + img.width > width || y0 + img.height > height

      img.height.times { |y| out.bytesplice((y0 + y) * width + x0, img.width, img.row(y)) }
    end
    QrReader::Image.new(width, height, out)
  end

  # --- JPEG (ImageMagick, development only) ---------------------------------

  def jpeg_available?
    return @jpeg_available unless @jpeg_available.nil?

    @jpeg_available = begin
      _, status = Open3.capture2e("magick", "-version")
      status.success?
    rescue SystemCallError
      false
    end
  end

  # JPEG-compresses the image with ImageMagick. +color+ writes a 3-component
  # YCbCr JPEG with 4:2:0 chroma subsampling instead of a grayscale one.
  def jpeg_bytes(image, quality: 75, color: false, progressive: false)
    raise Unavailable, "ImageMagick (magick) is not installed" unless jpeg_available?

    args = ["magick", "pgm:-", "-quality", quality.to_s]
    args += ["-type", "TrueColor", "-sampling-factor", "2x2,1x1,1x1"] if color
    args += ["-interlace", "JPEG"] if progressive
    args << "jpg:-"
    out, err, status = Open3.capture3(*args, stdin_data: pgm_bytes(image), binmode: true)
    raise Unavailable, "magick failed: #{err}" unless status.success?

    out
  end

  # JPEG round trip: compress, then decode back with ImageMagick.
  def jpeg(image, quality: 75, color: false)
    data = jpeg_bytes(image, quality: quality, color: color)
    out, err, status = Open3.capture3("magick", "jpg:-", "-colorspace", "Gray", "-depth", "8", "pgm:-",
                                      stdin_data: data, binmode: true)
    raise Unavailable, "magick failed: #{err}" unless status.success?

    parse_pgm(out)
  end

  # Binary PGM (P5) bytes.
  def pgm_bytes(image)
    "P5\n#{image.width} #{image.height}\n255\n".b + image.data
  end

  # Binary PGM (P5, maxval <= 255; header comments allowed) to an Image.
  def parse_pgm(bytes)
    header = bytes.b.match(/\AP5(?:\s+|#[^\n]*\n)+(\d+)(?:\s+|#[^\n]*\n)+(\d+)(?:\s+|#[^\n]*\n)+(\d+)\s/n)
    raise ArgumentError, "not a binary PGM" unless header

    w, h, maxval = header.captures.map(&:to_i)
    raise ArgumentError, "unsupported PGM maxval #{maxval}" unless maxval.between?(1, 255)

    data = bytes.byteslice(header.end(0), w * h)
    data = data.tr(IDENTITY_TABLE, QrReader::Image::TR_ESCAPE.call((0..255).map { |v| [(v * 255 + maxval / 2) / maxval, 255].min })) if maxval != 255
    QrReader::Image.new(w, h, data)
  end

  # --- helpers -------------------------------------------------------------

  # Multiplies each pixel by a per-pixel factor (1/65536 units) that starts
  # at row_start and grows by step per column: the block returns
  # [row_start, step] for row y.
  def scale_pixels(image)
    w = image.width
    h = image.height
    src = image.data
    out = "\0".b * (w * h)
    y = 0
    while y < h
      f, step = yield(y)
      off = y * w
      x = 0
      while x < w
        v = (src.getbyte(off + x) * (f.negative? ? 0 : f)) >> 16
        out.setbyte(off + x, v > 255 ? 255 : v)
        f += step
        x += 1
      end
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # Source indices and weights (summing to 4096) for each output sample of
  # a 1-D resampling from +src+ to +dst+ samples.
  def resample_weights(src, dst)
    ratio = src.fdiv(dst)
    Array.new(dst) do |i|
      if ratio >= 1
        # Area average over [i, i + 1) * ratio.
        lo = i * ratio
        hi = lo + ratio
        idx = (lo.floor...[hi.ceil, src].min).to_a
        raw = idx.map { |j| [[j + 1, hi].min - [j, lo].max, 0].max }
      else
        # Bilinear: pixel centres.
        pos = ((i + 0.5) * ratio - 0.5).clamp(0, src - 1)
        j = pos.floor
        t = pos - j
        idx = [j, [j + 1, src - 1].min]
        raw = [1 - t, t]
      end
      total = raw.sum
      wts = raw.map { |r| (r.fdiv(total) * 4096).round }
      wts[wts.index(wts.max)] += 4096 - wts.sum
      [idx, wts]
    end
  end

  # Box sizes for n successive box blurs approximating a gaussian (W. Jarosz).
  def box_sizes(sigma, n)
    ideal = Math.sqrt(12 * sigma * sigma / n + 1)
    wl = ideal.floor
    wl -= 1 if wl.even?
    wu = wl + 2
    m = ((12 * sigma * sigma - n * wl * wl - 4 * n * wl - 3 * n) / (-4 * wl - 4)).round
    Array.new(n) { |i| i < m ? wl : wu }
  end

  def horizontal_box(image, r)
    w = image.width
    h = image.height
    src = image.data
    out = "\0".b * (w * h)
    size = 2 * r + 1
    half = size / 2
    last = w - 1
    y = 0
    # The window starts at -r: r copies of the first pixel, then pixels
    # 0...r (clamped to the last one), summed in O(min(r, w)).
    head = r < w ? r : w
    while y < h
      off = y * w
      first_v = src.getbyte(off)
      last_v = src.getbyte(off + last)
      s = first_v * r + (r - head) * last_v
      k = 0
      while k < head
        s += src.getbyte(off + k)
        k += 1
      end
      x = 0
      while x < w
        add = x + r
        s += add > last ? last_v : src.getbyte(off + add)
        out.setbyte(off + x, (s + half) / size)
        sub = x - r
        s -= sub.negative? ? first_v : src.getbyte(off + sub)
        x += 1
      end
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  def vertical_box(image, r)
    w = image.width
    h = image.height
    src = image.data
    out = "\0".b * (w * h)
    size = 2 * r + 1
    half = size / 2
    last = h - 1
    sums = Array.new(w, 0)
    head = r < h ? r : h
    last_off = last * w
    x = 0
    while x < w
      s = src.getbyte(x) * r + (r - head) * src.getbyte(last_off + x)
      k = 0
      while k < head
        s += src.getbyte(k * w + x)
        k += 1
      end
      sums[x] = s
      x += 1
    end
    y = 0
    while y < h
      add = y + r
      add_off = (add > last ? last : add) * w
      sub = y - r
      sub_off = (sub.negative? ? 0 : sub) * w
      off = y * w
      x = 0
      while x < w
        s = sums[x] + src.getbyte(add_off + x)
        out.setbyte(off + x, (s + half) / size)
        sums[x] = s - src.getbyte(sub_off + x)
        x += 1
      end
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # Copy of +image+ with +margin+ pixels of replicated edge on every side.
  def pad_replicate(image, margin)
    w = image.width
    h = image.height
    out = String.new(capacity: (w + 2 * margin) * (h + 2 * margin), encoding: Encoding::BINARY)
    rows = Array.new(h) do |y|
      row = image.row(y)
      (row.byteslice(0, 1) * margin) + row + (row.byteslice(w - 1, 1) * margin)
    end
    margin.times { out << rows[0] }
    rows.each { |row| out << row }
    margin.times { out << rows[h - 1] }
    QrReader::Image.new(w + 2 * margin, h + 2 * margin, out)
  end

  # Homography taking the unit square (0,0),(1,0),(1,1),(0,1) to quad +p+.
  def square_to_quad(p)
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = p.map { |x, y| [x.to_f, y.to_f] }
    dx3 = x0 - x1 + x2 - x3
    dy3 = y0 - y1 + y2 - y3
    if dx3.abs < 1e-12 && dy3.abs < 1e-12
      [x1 - x0, x2 - x1, x0, y1 - y0, y2 - y1, y0, 0.0, 0.0, 1.0]
    else
      dx1 = x1 - x2
      dx2 = x3 - x2
      dy1 = y1 - y2
      dy2 = y3 - y2
      den = dx1 * dy2 - dx2 * dy1
      a13 = (dx3 * dy2 - dx2 * dy3) / den
      a23 = (dx1 * dy3 - dx3 * dy1) / den
      [x1 - x0 + a13 * x1, x3 - x0 + a23 * x3, x0,
       y1 - y0 + a13 * y1, y3 - y0 + a23 * y3, y0,
       a13, a23, 1.0]
    end
  end

  def invert3(m)
    a, b, c, d, e, f, g, h, i = m
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
     (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
     (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
  end

  # Public image -> image functions usable as #apply steps.
  STEPS = %i[lut contrast brightness gamma invert mirror gradient vignette shadow gaussian_noise salt_pepper
             blur box_blur motion_blur scale resize perspective perspective_tilt rotate cylinder barrel pad jpeg].freeze

  private_class_method :scale_pixels, :resample_weights, :box_sizes, :horizontal_box,
                       :vertical_box, :pad_replicate, :square_to_quad, :invert3
end
