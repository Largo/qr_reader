# frozen_string_literal: true

require "zlib"
require "qr_reader"

begin
  require "rqrcode_core"
rescue LoadError
  # rqrcode_core is a development dependency (bundle exec)
end

# Helpers for building synthetic test images. Independent of the library's
# own detector code on purpose (separate perspective math, separate PNG writer).
module QrTestHelper
  module_function

  # QR symbol as a QrReader::BitMatrix, encoded by rqrcode_core.
  # level: :l, :m, :q, :h; size: version (1..40) or nil for automatic;
  # mode: nil, :number, :alphanumeric, :byte_8bit.
  def rqr_matrix(text, level: :m, size: nil, mode: nil)
    opts = { level: level }
    opts[:size] = size if size
    opts[:mode] = mode if mode
    qr = RQRCodeCore::QRCode.new(text, **opts)
    QrReader::BitMatrix.from_rows(qr.modules)
  end

  # Axis-aligned rendering of a symbol: dark modules = +dark+, light = +light+,
  # surrounded by a +quiet+ zone of light modules.
  def render(matrix, module_size: 4, quiet: 4, dark: 0, light: 255)
    n = matrix.width
    side = (n + 2 * quiet) * module_size
    data = light.chr.b * (side * side)
    dark_row = dark.chr.b * module_size
    n.times do |my|
      n.times do |mx|
        next unless matrix.dark?(mx, my)

        x0 = (mx + quiet) * module_size
        y0 = (my + quiet) * module_size
        module_size.times { |dy| data[(y0 + dy) * side + x0, module_size] = dark_row }
      end
    end
    QrReader::Image.new(side, side, data)
  end

  # 3x3 homography mapping the unit square (0,0),(1,0),(1,1),(0,1) to the quad
  # p0..p3 (each [x, y]). Returns a 9-element array (row-major).
  def square_to_quad(p)
    p = p.map { |x, y| [x.to_f, y.to_f] }
    x0, y0 = p[0]
    x1, y1 = p[1]
    x2, y2 = p[2]
    x3, y3 = p[3]
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

  # Warps +image+ so that its corners land on +corners+ ([[x,y]]*4: TL, TR,
  # BR, BL) of a new out_w x out_h canvas filled with +background+.
  # Bilinear sampling with optional supersampling for smooth edges.
  def warp(image, corners, out_w, out_h, background: 255, supersample: 2)
    m = square_to_quad(corners)
    inv = invert3(m)
    sw = image.width
    sh = image.height
    src = image.data
    out = "\0".b * (out_w * out_h)
    ss = supersample
    offsets = (0...ss).map { |k| (k + 0.5) / ss }
    a, b, c, d, e, f, g, h, i = inv
    out_h.times do |y|
      out_w.times do |x|
        acc = 0.0
        offsets.each do |oy|
          py = y + oy
          offsets.each do |ox|
            px = x + ox
            den = g * px + h * py + i
            if den <= 0
              acc += background
              next
            end
            u = (a * px + b * py + c) / den * sw - 0.5
            v = (d * px + e * py + f) / den * sh - 0.5
            # Written so that NaN also falls through to the background.
            acc += if u >= -0.5 && v >= -0.5 && u <= sw - 0.5 && v <= sh - 0.5
                     bilinear(src, sw, sh, u, v)
                   else
                     background
                   end
          end
        end
        out.setbyte(y * out_w + x, (acc / (ss * ss)).round.clamp(0, 255))
      end
    end
    QrReader::Image.new(out_w, out_h, out)
  end

  def bilinear(src, w, h, u, v)
    x0 = u.floor.clamp(0, w - 1)
    y0 = v.floor.clamp(0, h - 1)
    x1 = (x0 + 1).clamp(0, w - 1)
    y1 = (y0 + 1).clamp(0, h - 1)
    fx = (u - x0).clamp(0.0, 1.0)
    fy = (v - y0).clamp(0.0, 1.0)
    p00 = src.getbyte(y0 * w + x0)
    p10 = src.getbyte(y0 * w + x1)
    p01 = src.getbyte(y1 * w + x0)
    p11 = src.getbyte(y1 * w + x1)
    top = p00 + (p10 - p00) * fx
    bottom = p01 + (p11 - p01) * fx
    top + (bottom - top) * fy
  end

  # Rotates +image+ by +degrees+ (counter-clockwise, arbitrary angle) onto a
  # canvas large enough to hold it, with +margin+ pixels around.
  def rotate(image, degrees, margin: 10, background: 255)
    rad = degrees * Math::PI / 180
    cos = Math.cos(rad)
    sin = Math.sin(rad)
    w = image.width
    h = image.height
    pts = [[0, 0], [w, 0], [w, h], [0, h]].map { |x, y| [x * cos + y * sin, -x * sin + y * cos] }
    min_x = pts.map(&:first).min
    min_y = pts.map(&:last).min
    out_w = (pts.map(&:first).max - min_x).ceil + 2 * margin
    out_h = (pts.map(&:last).max - min_y).ceil + 2 * margin
    corners = pts.map { |x, y| [x - min_x + margin, y - min_y + margin] }
    warp(image, corners, out_w, out_h, background: background)
  end

  # Adds deterministic pseudo-random noise of amplitude +amount+.
  def add_noise(image, amount, seed: 1)
    rng = Random.new(seed)
    data = image.data.dup
    data.bytesize.times do |i|
      data.setbyte(i, (data.getbyte(i) + rng.rand(-amount..amount)).clamp(0, 255))
    end
    QrReader::Image.new(image.width, image.height, data)
  end

  # Box blur with the given radius (separable, edge-clamped).
  def blur(image, radius)
    return image if radius < 1

    w = image.width
    h = image.height
    tmp = Array.new(w * h, 0)
    src = image.data
    h.times do |y|
      w.times do |x|
        s = 0
        (-radius..radius).each { |k| s += src.getbyte(y * w + (x + k).clamp(0, w - 1)) }
        tmp[y * w + x] = s
      end
    end
    out = "\0".b * (w * h)
    n = (2 * radius + 1)**2
    h.times do |y|
      w.times do |x|
        s = 0
        (-radius..radius).each { |k| s += tmp[(y + k).clamp(0, h - 1) * w + x] }
        out.setbyte(y * w + x, (s.to_f / n).round)
      end
    end
    QrReader::Image.new(w, h, out)
  end

  # Grayscale PNG encoder (for writing fixtures / debugging failures).
  def png_bytes(image)
    raw = String.new(encoding: Encoding::BINARY)
    image.height.times { |y| raw << "\0" << image.row(y) }
    chunk = lambda do |type, body|
      [body.bytesize].pack("N") + type + body + [Zlib.crc32(type + body)].pack("N")
    end
    "\x89PNG\r\n\x1a\n".b +
      chunk.call("IHDR", [image.width, image.height, 8, 0, 0, 0, 0].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(raw)) +
      chunk.call("IEND", "".b)
  end

  def write_png(image, path)
    File.binwrite(path, png_bytes(image))
  end

  # Binary PGM (P5) bytes.
  def pgm_bytes(image)
    "P5\n#{image.width} #{image.height}\n255\n".b + image.data
  end
end
