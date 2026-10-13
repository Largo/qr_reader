# frozen_string_literal: true

require "qr_reader/image"
require "open3"

# Deterministic image distortions for robustness tests and benchmarks. Every
# function takes a QrReader::Image and returns a new one; randomness comes
# only from the given +seed+. Invalid parameters raise ArgumentError.
#
#   img = QrTestEncoder.build("HELLO").to_image(module_size: 6)
#   img = Distort.perspective_tilt(img, strength: 0.2, seed: 3)
#   img = Distort.blur(Distort.gaussian_noise(img, sigma: 12, seed: 1), 1.0)
#   img = Distort.apply(img, [[:gradient, { from: 1.0, to: 0.4 }], [:jpeg, { quality: 30 }]])
#
# Geometric warps use inverse mapping with bilinear sampling and treat the
# area outside the source as +background+. The perspective convention (corner
# order TL, TR, BR, BL; pixel centres at +0.5) matches QrTestHelper.warp.
#
# Per-pixel work runs in per-row helper methods: YJIT compiles a method only
# after it has been called a few times, so a loop over the whole image inside
# a single call would stay in the interpreter.
module Distort
  # Raised when an optional dev tool (ImageMagick for JPEG) is missing.
  class Unavailable < StandardError; end

  IDENTITY_TABLE = QrReader::Image::TR_ESCAPE.call((0..255).to_a)
  private_constant :IDENTITY_TABLE

  # Largest output image any distortion creates (512 megapixels, 15 A4
  # pages at 600 DPI); more is a parameter mistake, not a test case.
  MAX_PIXELS = 1 << 29

  # Bilinear sampling of an image at pixel-centre coordinates, in 1/256 gray
  # levels; +background+ when a coordinate is more than half a pixel outside
  # the image or NaN. Callers compute a whole row of coordinates first and
  # then sample it with one #sample_row call.
  class BilinearSampler
    def initialize(image, background)
      @src = image.data
      @width = image.width
      @max_x = image.width - 1
      @last_row = (image.height - 1) * image.width
      # Largest coordinates in 1/256 pixels (clamping after the conversion
      # gives the same result as clamping the Float first).
      @max_ui = @max_x * 256
      @max_vi = (image.height - 1) * 256
      @u_limit = image.width - 0.5
      @v_limit = image.height - 0.5
      @background = background * 256
    end

    # For x = 0...count, writes (+round+ + the sum of the +group+ samples at
    # (us[k], vs[k]), k = group * x ...) / +divisor+ to out[off + x].
    def sample_row(us, vs, out, off, count, group, round, divisor)
      src = @src
      width = @width
      max_x = @max_x
      last_row = @last_row
      max_ui = @max_ui
      max_vi = @max_vi
      u_limit = @u_limit
      v_limit = @v_limit
      background = @background
      k = 0
      x = 0
      while x < count
        sum = round
        stop = k + group
        while k < stop
          u = us[k]
          v = vs[k]
          # Written so that NaN coordinates also yield the background.
          if u >= -0.5 && v >= -0.5 && u <= u_limit && v <= v_limit
            ui = (u * 256.0).to_i
            ui = ui < 0 ? 0 : (ui > max_ui ? max_ui : ui)
            vi = (v * 256.0).to_i
            vi = vi < 0 ? 0 : (vi > max_vi ? max_vi : vi)
            x0 = ui >> 8
            fx = ui & 255
            fy = vi & 255
            x1 = x0 < max_x ? x0 + 1 : x0
            r0 = (vi >> 8) * width
            r1 = r0 < last_row ? r0 + width : r0
            top = src.getbyte(r0 + x0) * (256 - fx) + src.getbyte(r0 + x1) * fx
            bottom = src.getbyte(r1 + x0) * (256 - fx) + src.getbyte(r1 + x1) * fx
            sum += (top * (256 - fy) + bottom * fy) >> 8
          else
            sum += background
          end
          k += 1
        end
        out.setbyte(off + x, sum / divisor)
        x += 1
      end
    end
  end

  # Perspective warp by inverse mapping, one output row at a time, with
  # +supersample+ x +supersample+ samples per output pixel.
  class Warp
    def initialize(image, inverse, out_w, supersample, background)
      sw = image.width
      sh = image.height
      a, b, c, d, e, f, g, h, i = inverse
      # Fold the unit-square -> pixel scaling into the inverse transform.
      @b = b * sw
      @c = c * sw
      @e = e * sh
      @f = f * sh
      @h = h
      @i = i
      @ss = supersample
      @offsets = Array.new(supersample) { |k| (k + 0.5) / supersample }
      # Products with the x coordinate of every sample column, tabulated once.
      columns = out_w * supersample
      sub_xs = Array.new(columns) { |j| (j / supersample) + @offsets[j % supersample] }
      @ax = sub_xs.map { |px| a * sw * px }
      @dx = sub_xs.map { |px| d * sh * px }
      @gx = sub_xs.map { |px| g * px }
      # Affine maps have den == 1.0 exactly (x / 1.0 == x): skipping the
      # divisions does not change a single bit.
      @affine = g == 0.0 && h == 0.0 && i == 1.0
      # Coordinates are stored pixel by pixel: the samples of output pixel x
      # occupy slots x * ss**2 ... (sub-row by sub-row).
      @slots = Array.new(columns) { |j| (j / supersample) * supersample * supersample + j % supersample }
      @us = Array.new(columns * supersample, 0.0)
      @vs = Array.new(columns * supersample, 0.0)
      @out_w = out_w
      @sampler = BilinearSampler.new(image, background)
    end

    # Writes output row +y+ into +out+.
    def row(y, out)
      ss = @ss
      oy = 0
      while oy < ss
        coordinates(y + @offsets[oy], oy * ss)
        oy += 1
      end
      samples = ss * ss
      @sampler.sample_row(@us, @vs, out, y * @out_w, @out_w, samples, samples * 128, samples * 256)
    end

    private

    # Source coordinates of the samples on the sub-row at height +py+ (slots
    # +base+ + @slots[j]); NaN where the point lies on or behind the camera's
    # horizon (den <= 0).
    def coordinates(py, base)
      us = @us
      vs = @vs
      ax = @ax
      dx = @dx
      slots = @slots
      n = ax.size
      bpy = @b * py
      epy = @e * py
      c = @c
      f = @f
      j = 0
      if @affine
        while j < n
          k = slots[j] + base
          us[k] = ax[j] + bpy + c - 0.5
          vs[k] = dx[j] + epy + f - 0.5
          j += 1
        end
      else
        gx = @gx
        hpy = @h * py
        i = @i
        while j < n
          k = slots[j] + base
          den = gx[j] + hpy + i
          if den <= 0
            us[k] = Float::NAN
            vs[k] = Float::NAN
          else
            us[k] = (ax[j] + bpy + c) / den - 0.5
            vs[k] = (dx[j] + epy + f) / den - 0.5
          end
          j += 1
        end
      end
    end
  end
  private_constant :BilinearSampler, :Warp

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
    check_finite(low: low, high: high)
    lut(image, (0..255).map { |v| low + (high - low) * v / 255.0 })
  end

  # Brightness offset (positive = lighter), clamped.
  def brightness(image, offset)
    check_finite(offset: offset)
    lut(image, (0..255).map { |v| v + offset })
  end

  def gamma(image, value)
    check_finite(gamma: value)
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
    check_finite(from: from, to: to, angle: angle)
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
    src = image.data
    out = "\0".b * (w * h)
    y = 0
    while y < h
      scale_row(src, out, y * w, w, base + step_y * y, step_x)
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # Radial darkening towards the corners: the factor is 1 at the centre and
  # 1 - +strength+ at the corners (quadratic falloff; negative strengths
  # brighten). Results are clamped to 0..255.
  def vignette(image, strength: 0.5)
    check_finite(strength: strength)
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
      vignette_row(src, out, y * w, w, cx2, dy * dy, k, r2max)
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # A straight-edged shadow over part of the image: pixels on one side of a
  # random line are multiplied by 1 - +darkness+, with a linear penumbra of
  # +softness+ (fraction of the image diagonal). Results are clamped to 0..255.
  def shadow(image, darkness: 0.5, softness: 0.05, seed: 0)
    check_finite(darkness: darkness, softness: softness)
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
    src = image.data
    out = "\0".b * (w * h)
    y = 0
    while y < h
      shadow_row(src, out, y * w, w, (0 - px) * nx + (y - py) * ny, nx, soft / 2, dark, lit, slope)
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # Additive gaussian noise with standard deviation +sigma+ (gray levels).
  def gaussian_noise(image, sigma: 10, seed: 0)
    check_finite(sigma: sigma)
    rng = Random.new(seed)
    table = Array.new(65_536) do
      # Box-Muller; 1 - rand avoids log(0).
      (Math.sqrt(-2 * Math.log(1 - rng.rand)) * Math.cos(2 * Math::PI * rng.rand) * sigma).round
    end
    w = image.width
    h = image.height
    src = image.data
    out = "\0".b * (w * h)
    y = 0
    while y < h
      rows = h - y < 2 ? 1 : 2
      # Two rows per draw: 4w bytes, a multiple of 4, so the byte stream is
      # the same as from one big rng.bytes(2 * w * h) call. Little-endian
      # picks: identical on every platform.
      noise_span(src, out, y * w, rng.bytes(2 * w * rows).unpack("v*"), table)
      y += rows
    end
    QrReader::Image.new(w, h, out)
  end

  # Sets a fraction +amount+ (0..1) of the pixels to black or white at
  # random (positions may repeat).
  def salt_pepper(image, amount: 0.02, seed: 0)
    check_finite(amount: amount)
    rng = Random.new(seed)
    n = image.size
    out = image.data.dup
    (amount.clamp(0.0, 1.0) * n).round.times { out.setbyte(rng.rand(n), rng.rand(2) * 255) }
    QrReader::Image.new(image.width, image.height, out)
  end

  # Gaussian-like blur: three successive box blurs approximating standard
  # deviation +sigma+ (pixels). Edges are clamped.
  def blur(image, sigma)
    check_finite(sigma: sigma)
    return image if sigma <= 0

    box_sizes(sigma, 3).reduce(image) { |img, size| box_blur(img, (size - 1) / 2) }
  end

  # Separable box blur with the given Integer radius (window 2r+1), edges clamped.
  def box_blur(image, radius)
    raise ArgumentError, "box blur radius must be an Integer, got #{radius.inspect}" unless radius.is_a?(Integer)
    return image if radius < 1

    vertical_box(horizontal_box(image, radius), radius)
  end

  # Linear motion blur: average of +length+ (Integer) samples along +angle+ (degrees).
  def motion_blur(image, length: 7, angle: 0)
    raise ArgumentError, "motion blur length must be an Integer, got #{length.inspect}" unless length.is_a?(Integer)

    check_finite(angle: angle)
    return image if length < 2

    w = image.width
    h = image.height
    offsets = motion_offsets(length, angle * Math::PI / 180, w, h)
    margin = offsets.keys.flatten.map(&:abs).max
    padded = pad_replicate(image, margin)
    pw = w + 2 * margin
    deltas = offsets.keys.map { |dx, dy| dy * pw + dx }
    weights = offsets.values
    src = padded.data
    out = "\0".b * (w * h)
    y = 0
    while y < h
      motion_row(src, out, (y + margin) * pw + margin, y * w, w, deltas, weights, length)
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # --- geometric -----------------------------------------------------------

  # Resamples by +factor+ (e.g. 0.25 turns 6 px/module into 1.5 px/module):
  # area averaging when shrinking, bilinear interpolation when enlarging.
  def scale(image, factor)
    check_finite(factor: factor)
    raise ArgumentError, "scale factor must be positive, got #{factor.inspect}" unless factor.positive?
    raise ArgumentError, "scale factor #{factor} gives more than #{MAX_PIXELS} pixels" if image.size * factor * factor > MAX_PIXELS

    out_w = [(image.width * factor).round, 1].max
    out_h = [(image.height * factor).round, 1].max
    resize(image, out_w, out_h)
  end

  def resize(image, out_w, out_h)
    check_size(out_w, out_h)

    xw = resample_weights(image.width, out_w)
    yw = resample_weights(image.height, out_h)
    w = image.width
    h = image.height
    src = image.data
    # Horizontal pass into an Integer buffer (values scaled by 2**12).
    tmp = Array.new(out_w * h, 0)
    y = 0
    while y < h
      resample_row(src, y * w, tmp, y * out_w, out_w, xw)
      y += 1
    end
    out = "\0".b * (out_w * out_h)
    y = 0
    while y < out_h
      idx, wts = yw[y]
      resample_column_row(tmp, idx.map { |j| j * out_w }, wts, out, y * out_w, out_w)
      y += 1
    end
    QrReader::Image.new(out_w, out_h, out)
  end

  # Maps the source image's corners to +corners+ ([[x, y]] * 4: TL, TR, BR,
  # BL) on an +out_w+ x +out_h+ canvas, sampling +supersample+ x +supersample+
  # points per output pixel. Same geometry as QrTestHelper.warp.
  def perspective(image, corners, out_w, out_h, background: 255, supersample: 1)
    unless corners.is_a?(Array) && corners.size == 4 && corners.all? { |p| p.is_a?(Array) && p.size == 2 }
      raise ArgumentError, "corners must be four [x, y] pairs, got #{corners.inspect}"
    end
    corners.each { |x, y| check_finite(x: x, y: y) }
    check_size(out_w, out_h)
    check_byte(background: background)
    unless supersample.is_a?(Integer) && supersample.between?(1, 16)
      raise ArgumentError, "supersample must be an Integer 1..16, got #{supersample.inspect}"
    end

    warp = Warp.new(image, invert3(square_to_quad(corners)), out_w, supersample, background)
    out = "\0".b * (out_w * out_h)
    y = 0
    while y < out_h
      warp.row(y, out)
      y += 1
    end
    QrReader::Image.new(out_w, out_h, out)
  end

  # Random perspective tilt: each corner moves inwards by up to +strength+ of
  # the image size; the canvas keeps the input size.
  def perspective_tilt(image, strength: 0.2, seed: 0, background: 255)
    check_finite(strength: strength)
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
    check_finite(degrees: degrees)
    raise ArgumentError, "margin must be a non-negative Integer, got #{margin.inspect}" unless margin.is_a?(Integer) && margin >= 0

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
    raise ArgumentError, "arc must be 0..360 degrees, got #{arc.inspect}" unless arc.is_a?(Numeric) && arc.between?(0, 360)

    check_finite(bulge: bulge)
    check_byte(background: background)
    return image if arc.zero?

    w = image.width
    h = image.height
    half_arc = arc * Math::PI / 360
    radius = (w / 2.0) / half_arc
    cx = w / 2.0
    cy = h / 2.0
    # Half width of the visible (front) side in the output.
    limit = half_arc >= Math::PI / 2 ? radius : radius * Math.sin(half_arc)
    # Per output column: source x (NaN off the cylinder) and vertical scale.
    us = Array.new(w, Float::NAN)
    scales = Array.new(w, 1.0)
    w.times do |x|
      px = x + 0.5 - cx
      next if px.abs > limit

      theta = Math.asin(px / radius)
      us[x] = cx + radius * theta - 0.5
      scales[x] = 1 + bulge * (Math.cos(theta) - Math.cos(half_arc))
    end
    sampler = BilinearSampler.new(image, background)
    vs = Array.new(w, 0.0)
    out = "\0".b * (w * h)
    y = 0
    while y < h
      cylinder_coordinates(vs, scales, w, cy, y + 0.5 - cy)
      sampler.sample_row(us, vs, out, y * w, w, 1, 128, 256)
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # Radial lens distortion: k > 0 gives barrel distortion (straight lines bow
  # outwards), k < 0 pincushion. k is relative to the half diagonal.
  def barrel(image, k: 0.1, background: 255)
    check_finite(k: k)
    check_byte(background: background)
    w = image.width
    h = image.height
    cx = w / 2.0
    cy = h / 2.0
    kr = k / (cx * cx + cy * cy)
    dxs = Array.new(w) { |x| x + 0.5 - cx }
    dx2s = dxs.map { |dx| dx * dx }
    sampler = BilinearSampler.new(image, background)
    us = Array.new(w, 0.0)
    vs = Array.new(w, 0.0)
    out = "\0".b * (w * h)
    y = 0
    while y < h
      barrel_coordinates(us, vs, dxs, dx2s, cx, cy, y + 0.5 - cy, kr)
      sampler.sample_row(us, vs, out, y * w, w, 1, 128, 256)
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # Surrounds the image with a border of +margin+ pixels of +value+.
  def pad(image, margin, value: 255)
    raise ArgumentError, "margin must be a non-negative Integer, got #{margin.inspect}" unless margin.is_a?(Integer) && margin >= 0

    check_byte(value: value)
    check_size(image.width + 2 * margin, image.height + 2 * margin)
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

  # Pastes +placements+ ([[image, x, y], ...], Integer positions) onto a new canvas.
  def compose(width, height, placements, background: 255)
    check_size(width, height)
    check_byte(background: background)
    out = background.chr.b * (width * height)
    placements.each do |img, x0, y0|
      raise ArgumentError, "placement positions must be Integers, got #{[x0, y0].inspect}" unless x0.is_a?(Integer) && y0.is_a?(Integer)
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

  # JPEG-compresses the image with ImageMagick (+quality+ 1..100). +color+
  # writes a 3-component YCbCr JPEG with 4:2:0 chroma subsampling instead of
  # a grayscale one.
  def jpeg_bytes(image, quality: 75, color: false, progressive: false)
    raise ArgumentError, "JPEG quality must be an Integer 1..100, got #{quality.inspect}" unless quality.is_a?(Integer) && quality.between?(1, 100)
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

  # --- validation ------------------------------------------------------------

  def check_finite(**values)
    values.each do |name, value|
      raise ArgumentError, "#{name} must be a finite number, got #{value.inspect}" unless value.is_a?(Numeric) && value.real? && value.finite?
    end
  end

  def check_byte(**values)
    values.each do |name, value|
      raise ArgumentError, "#{name} must be an Integer 0..255, got #{value.inspect}" unless value.is_a?(Integer) && value.between?(0, 255)
    end
  end

  def check_size(width, height)
    unless width.is_a?(Integer) && height.is_a?(Integer) && width.positive? && height.positive?
      raise ArgumentError, "invalid output size #{width.inspect}x#{height.inspect}"
    end
    raise ArgumentError, "output size #{width}x#{height} exceeds #{MAX_PIXELS} pixels" if width * height > MAX_PIXELS
  end

  # --- per-row kernels ---------------------------------------------------------

  # Multiplies the +w+ pixels at +off+ by a factor (1/65536 units) starting
  # at +f+ and growing by +step+ per pixel.
  def scale_row(src, out, off, w, f, step)
    x = 0
    while x < w
      v = (src.getbyte(off + x) * (f < 0 ? 0 : f)) >> 16
      out.setbyte(off + x, v > 255 ? 255 : v)
      f += step
      x += 1
    end
  end

  def vignette_row(src, out, off, w, cx2, dy2, k, r2max)
    x = 0
    while x < w
      dx = 2 * x - cx2
      v = (src.getbyte(off + x) * (65_536 - k * (dx * dx + dy2) / r2max)) >> 16
      out.setbyte(off + x, v < 0 ? 0 : (v > 255 ? 255 : v))
      x += 1
    end
  end

  # +d+ is the signed distance of the row's first pixel from the shadow line;
  # it grows by +nx+ per pixel.
  def shadow_row(src, out, off, w, d, nx, half_soft, dark, lit, slope)
    x = 0
    while x < w
      f = if d <= -half_soft then dark
          elsif d >= half_soft then lit
          else dark + ((d + half_soft) * slope).to_i
          end
      v = (src.getbyte(off + x) * f) >> 16
      out.setbyte(off + x, v < 0 ? 0 : (v > 255 ? 255 : v))
      d += nx
      x += 1
    end
  end

  def noise_span(src, out, off, picks, table)
    n = picks.size
    i = 0
    while i < n
      v = src.getbyte(off + i) + table[picks[i]]
      out.setbyte(off + i, v < 0 ? 0 : (v > 255 ? 255 : v))
      i += 1
    end
  end

  # Weighted sum of +length+ samples (+deltas+ / +weights+ around +base+ in
  # the edge-padded source) for each of the +w+ pixels of one output row.
  def motion_row(src, out, base, off, w, deltas, weights, length)
    count = deltas.size
    half = length / 2
    x = 0
    while x < w
      s = 0
      k = 0
      p = base + x
      while k < count
        s += src.getbyte(p + deltas[k]) * weights[k]
        k += 1
      end
      out.setbyte(off + x, (s + half) / length)
      x += 1
    end
  end

  # Horizontal resampling pass for one source row into +tmp+ (scaled by 2**12).
  def resample_row(src, off, tmp, toff, out_w, xw)
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
  end

  # Vertical resampling pass for one output row: +rows+ are the offsets in
  # +tmp+ of the contributing rows, +wts+ their weights (scaled by 2**12).
  def resample_column_row(tmp, rows, wts, out, off, out_w)
    n = rows.size
    x = 0
    while x < out_w
      s = 0
      k = 0
      while k < n
        s += tmp[rows[k] + x] * wts[k]
        k += 1
      end
      v = (s + 8_388_608) >> 24
      out.setbyte(off + x, v > 255 ? 255 : v)
      x += 1
    end
  end

  def cylinder_coordinates(vs, scales, w, cy, dy)
    x = 0
    while x < w
      vs[x] = cy + dy / scales[x] - 0.5
      x += 1
    end
  end

  # +dxs+: horizontal distance of every column from the centre, +dx2s+ its square.
  def barrel_coordinates(us, vs, dxs, dx2s, cx, cy, dy, kr)
    dy2 = dy * dy
    w = dxs.size
    x = 0
    while x < w
      dx = dxs[x]
      s = 1 + kr * (dx2s[x] + dy2)
      us[x] = cx + dx * s - 0.5
      vs[x] = cy + dy * s - 0.5
      x += 1
    end
  end

  # --- helpers -------------------------------------------------------------

  # {[dx, dy] => weight} for a motion blur of +length+ samples at whole-pixel
  # steps t = -length/2 ... (length - 1)/2 along +rad+ (centring an even
  # length at half-pixel positions and rounding half away from zero would
  # skip the centre pixel: -4, -3, -2, -1, 1, 2, 3, 4 for length 8).
  # Offsets beyond the image size all land on the replicated edge, so they
  # are clamped (bounding the padding) and equal ones are merged into
  # weights (bounding the work per pixel). Both coordinates are monotone in
  # t, so every offset covers one interval of t: a binary search finds its
  # end, which keeps huge lengths cheap (O(w + h) offsets, not O(length)).
  def motion_offsets(length, rad, w, h)
    cos = Math.cos(rad)
    sin = Math.sin(rad)
    offset = ->(t) { [(t * cos).round.clamp(-w, w), (t * sin).round.clamp(-h, h)] }
    weights = {}
    t = -(length / 2)
    last = length - 1 - length / 2
    while t <= last
      current = offset.(t)
      lo = t
      hi = last
      while lo < hi
        mid = (lo + hi + 1) / 2
        if offset.(mid) == current
          lo = mid
        else
          hi = mid - 1
        end
      end
      weights[current] = lo - t + 1
      t = lo + 1
    end
    weights
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
    y = 0
    while y < h
      horizontal_box_row(src, out, y * w, w, r)
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  # The window starts at -r: r copies of the first pixel, then pixels
  # 0...r (clamped to the last one), summed in O(min(r, w)).
  def horizontal_box_row(src, out, off, w, r)
    size = 2 * r + 1
    half = size / 2
    last = w - 1
    head = r < w ? r : w
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
      s -= sub < 0 ? first_v : src.getbyte(off + sub)
      x += 1
    end
  end

  def vertical_box(image, r)
    w = image.width
    h = image.height
    src = image.data
    out = "\0".b * (w * h)
    last = h - 1
    head = r < h ? r : h
    last_off = last * w
    # Running column sums of the window for row 0, minus its newest row.
    sums = Array.new(w) { |x| src.getbyte(x) * r + (r - head) * src.getbyte(last_off + x) }
    k = 0
    while k < head
      add_row(sums, src, k * w, w)
      k += 1
    end
    y = 0
    while y < h
      add = y + r
      sub = y - r
      vertical_box_row(src, out, sums, y * w, w, (add > last ? last : add) * w, (sub < 0 ? 0 : sub) * w, 2 * r + 1)
      y += 1
    end
    QrReader::Image.new(w, h, out)
  end

  def add_row(sums, src, off, w)
    x = 0
    while x < w
      sums[x] += src.getbyte(off + x)
      x += 1
    end
  end

  def vertical_box_row(src, out, sums, off, w, add_off, sub_off, size)
    half = size / 2
    x = 0
    while x < w
      s = sums[x] + src.getbyte(add_off + x)
      out.setbyte(off + x, (s + half) / size)
      sums[x] = s - src.getbyte(sub_off + x)
      x += 1
    end
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

  private_class_method :check_finite, :check_byte, :check_size, :scale_row, :vignette_row, :shadow_row,
                       :noise_span, :motion_row, :resample_row, :resample_column_row, :cylinder_coordinates,
                       :barrel_coordinates, :motion_offsets, :resample_weights, :box_sizes, :horizontal_box,
                       :horizontal_box_row, :vertical_box, :add_row, :vertical_box_row, :pad_replicate,
                       :square_to_quad, :invert3
end
