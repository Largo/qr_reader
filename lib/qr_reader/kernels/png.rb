# frozen_string_literal: true

require_relative "../errors"
require_relative "pixels"

# PNG kernels: row unfiltering fused with the conversion to luminance.
# Plain Ruby in the subset Spinel compiles (see DESIGN.md, "Kernels").
#
# Rows are unfiltered into a fresh String per row (appending with String#<<
# is much cheaper than setbyte). 8-bit gray+alpha, RGB and RGBA rows are
# unfiltered and converted in one pass by fused helpers (one per filter
# type and pixel layout); other layouts are unfiltered first and then
# converted. Each helper is a small method called once per row: YJIT
# compiles methods, not loops, and keeping dispatch out of the loops means
# that one layout never makes another one's loop side-exit.
module QrReaderKernels
  # Paeth predictor without branches: with da = b - c and db = a - c (a =
  # left, b = up, c = up-left) the predictor is c + PNG_PAETH[...], where
  # the table holds db (choose a), da (choose b) or 0 (choose c), indexed
  # by (da + 255) * 511 + (db + 255). For fixed da the choice is a function
  # of db made of a few intervals (derived from |da| <= |db|,
  # |da| <= |da + db| and |db| <= |da + db|), so each row of the table is
  # built from C-level fills instead of 261k iterations.
  def self.png_paeth_table
    base = Array.new(511, 0)
    i = 0
    while i < 511
      base[i] = i - 255 # choose a: predictor offset db
      i += 1
    end
    table = []
    da = -255
    while da <= 255
      row = base.dup
      if da > 0
        # b for ceil(-d/2) <= db < d, c for -2d < db < ceil(-d/2)
        split = -(da / 2)
        png_paeth_fill(row, 0, -2 * da + 1, split - 1)
        png_paeth_fill(row, da, split, da - 1)
      elsif da < 0
        # b for -d < db <= floor(d/2), c for floor(d/2) < db < 2d
        d = -da
        png_paeth_fill(row, da, -d + 1, d / 2)
        png_paeth_fill(row, 0, d / 2 + 1, 2 * d - 1)
      end
      table.concat(row)
      da += 1
    end
    table
  end

  def self.png_paeth_fill(row, value, from, to)
    from = -255 if from < -255
    to = 255 if to > 255
    row.fill(value, from + 255, to - from + 1) if to >= from
    row
  end

  # Byte -> its 8, 4 or 2 samples of +depth+ bits (MSB first) as bytes.
  def self.png_unpack_table(depth)
    mask = (1 << depth) - 1
    table = []
    b = 0
    while b < 256
      s = String.new(capacity: 8, encoding: Encoding::BINARY)
      shift = 8 - depth
      while shift >= 0
        s << ((b >> shift) & mask)
        shift -= depth
      end
      table << s
      b += 1
    end
    table
  end

  PNG_PAETH = png_paeth_table.freeze
  PNG_PAETH_CENTER = 255 * 511 + 255
  PNG_UNPACK1 = png_unpack_table(1).freeze
  PNG_UNPACK2 = png_unpack_table(2).freeze
  PNG_UNPACK4 = png_unpack_table(4).freeze
  # Adam7 passes: x0, y0, dx, dy.
  PNG_ADAM7 = [0, 0, 8, 8, 4, 0, 8, 8, 0, 4, 4, 8, 2, 0, 4, 4, 0, 2, 2, 4, 1, 0, 2, 2, 0, 1, 1, 2].freeze

  # Unfilters +rows+ rows of +width+ pixels (+channels+ samples of +depth+
  # bits each), stored from byte +pos+ of +raw+ as a filter type byte
  # followed by the filtered row, and converts them: to luminance with alpha
  # over white for 8/16-bit colour or alpha, to one byte per sample value
  # (0 .. 2**depth - 1) for gray/palette images of depth <= 8, which the
  # caller maps with String#tr. 16-bit samples keep their high byte.
  # +prev+ is the unfiltered row above the first one ("" at the top of an
  # image or pass). +key+ is the tRNS colour key as raw sample bytes (16-bit
  # gray, RGB): matching pixels become white; "" for none.
  # Returns rows * width output bytes followed by the last unfiltered row
  # (the +prev+ of the next call when an image is decoded in slices).
  # spinel-sample: QrReaderKernels.png_rows("\x01\x10\x20\x03\x01\x02".b, 0, 2, 2, 8, 1, "".b, "".b)
  def self.png_rows(raw, pos, rows, width, depth, channels, prev, key)
    len = (width * channels * depth + 7) >> 3
    bpp = (channels * depth + 7) >> 3
    raise QrReader::ImageError, "truncated PNG image data" if pos + rows * (len + 1) > raw.bytesize

    prev = "\0".b * len if prev.bytesize < len
    out = String.new(capacity: rows * width + len, encoding: Encoding::BINARY)
    fused = depth == 8 && channels > 1
    y = 0
    while y < rows
      filter = raw.getbyte(pos)
      png_bad_filter(filter) if filter > 4
      ri = pos + 1
      if fused && filter != 0
        cur = png_fused_row(raw, ri, prev, len, channels, filter)
        lum = cur.byteslice(len, width) || ""
      else
        cur = png_unfilter_row(raw, ri, prev, len, bpp, filter)
        lum = png_convert_row(cur, width, depth, channels)
      end
      lum = png_key_row(cur, lum, width, key) unless key.empty?
      out << lum
      prev = cur
      pos = ri + len
      y += 1
    end
    out << prev.byteslice(0, len)
    out
  end

  # Decodes a whole Adam7-interlaced image: the seven passes stored one
  # after the other in +raw+ (as png_rows reads them), then scattered into
  # +width+ x +height+ output bytes (luminance or sample values, see
  # png_rows).
  # spinel-sample: QrReaderKernels.png_adam7("\x00\x10".b, 1, 1, 8, 1, "".b)
  def self.png_adam7(raw, width, height, depth, channels, key)
    passes = String.new(capacity: width * height, encoding: Encoding::BINARY)
    starts = []
    widths = []
    pos = 0
    p = 0
    while p < 7
      x0 = PNG_ADAM7[4 * p]
      y0 = PNG_ADAM7[4 * p + 1]
      dx = PNG_ADAM7[4 * p + 2]
      dy = PNG_ADAM7[4 * p + 3]
      pw = width > x0 ? (width - x0 + dx - 1) / dx : 0
      ph = height > y0 ? (height - y0 + dy - 1) / dy : 0
      pw = 0 if ph == 0
      starts << passes.bytesize
      widths << pw
      if pw > 0
        res = png_rows(raw, pos, ph, pw, depth, channels, "".b, key)
        passes << res.byteslice(0, pw * ph)
        pos += ph * (1 + ((pw * channels * depth + 7) >> 3))
      end
      p += 1
    end
    out = String.new(capacity: width * height, encoding: Encoding::BINARY)
    y = 0
    while y < height
      out << png_adam7_row(passes, starts, widths, y, width)
      y += 1
    end
    out
  end

  # Output row +y+ of an interlaced image from the decoded passes.
  def self.png_adam7_row(passes, starts, widths, y, width)
    row = "\0".b * width
    p = 0
    while p < 7
      pw = widths[p]
      y0 = PNG_ADAM7[4 * p + 1]
      dy = PNG_ADAM7[4 * p + 3]
      if pw > 0 && y >= y0 && (y - y0) % dy == 0
        src = starts[p] + (y - y0) / dy * pw
        x = PNG_ADAM7[4 * p]
        dx = PNG_ADAM7[4 * p + 2]
        stop = src + pw
        while src < stop
          row.setbyte(x, passes.getbyte(src))
          x += dx
          src += 1
        end
      end
      p += 1
    end
    row
  end

  # Unfiltered row (+len+ bytes) followed by its luminance, for 8-bit
  # gray+alpha, RGB and RGBA rows with filter type 1..4. (Dispatchers return
  # a String on every branch, never nil: in the native build a nilable
  # String would make every byte loop that reads it polymorphic.)
  def self.png_fused_row(raw, ri, prev, len, channels, filter)
    t = PNG_PAETH
    case channels
    when 2
      case filter
      when 1 then png_ga8_sub(raw, ri, len)
      when 2 then png_ga8_up(raw, ri, prev, len)
      when 3 then png_ga8_avg(raw, ri, prev, len)
      else png_ga8_paeth(raw, ri, prev, len, t)
      end
    when 3
      case filter
      when 1 then png_rgb8_sub(raw, ri, len)
      when 2 then png_rgb8_up(raw, ri, prev, len)
      when 3 then png_rgb8_avg(raw, ri, prev, len)
      else png_rgb8_paeth(raw, ri, prev, len, t)
      end
    else
      case filter
      when 1 then png_rgba8_sub(raw, ri, len)
      when 2 then png_rgba8_up(raw, ri, prev, len)
      when 3 then png_rgba8_avg(raw, ri, prev, len)
      else png_rgba8_paeth(raw, ri, prev, len, t)
      end
    end
  end

  # The unfiltered row of +len+ bytes.
  def self.png_unfilter_row(raw, ri, prev, len, bpp, filter)
    case filter
    when 0 then raw.byteslice(ri, len) || ""
    when 1 then bpp == 1 ? png_sub1(raw, ri, len) : png_sub(raw, ri, len, bpp)
    when 2 then png_up(raw, ri, prev, len)
    when 3 then bpp == 1 ? png_avg1(raw, ri, prev, len) : png_avg(raw, ri, prev, len, bpp)
    else bpp == 1 ? png_paeth1(raw, ri, prev, len, PNG_PAETH) : png_paeth(raw, ri, prev, len, bpp, PNG_PAETH)
    end
  end

  def self.png_bad_filter(filter)
    raise QrReader::ImageError, "invalid PNG filter type #{filter}"
  end

  # Output bytes of an unfiltered row (see png_rows).
  def self.png_convert_row(cur, width, depth, channels)
    if channels == 1
      return cur if depth == 8
      return px_gray_row(cur, 0, width, 0, 2) if depth == 16

      png_unpack_row(cur, width, depth)
    elsif depth == 8
      case channels
      when 2 then px_gray_alpha_row(cur, 0, width, 0, 1, 2)
      when 3 then px_rgb_row(cur, 0, width, 0, 1, 2, 3)
      else px_rgba_row(cur, 0, width, 0, 1, 2, 3, 4)
      end
    else # 16-bit samples: their high bytes
      case channels
      when 2 then px_gray_alpha_row(cur, 0, width, 0, 2, 4)
      when 3 then px_rgb_row(cur, 0, width, 0, 2, 4, 6)
      else px_rgba_row(cur, 0, width, 0, 2, 4, 6, 8)
      end
    end
  end

  # Samples of 1, 2 or 4 bits -> one byte per sample.
  def self.png_unpack_row(cur, width, depth)
    table = depth == 1 ? PNG_UNPACK1 : (depth == 2 ? PNG_UNPACK2 : PNG_UNPACK4)
    per = 8 / depth
    full = width / per
    row = String.new(capacity: width + per, encoding: Encoding::BINARY)
    i = 0
    while i < full
      row << table[cur.getbyte(i)]
      i += 1
    end
    rest = width - full * per
    row << table[cur.getbyte(full)].byteslice(0, rest) if rest > 0
    row
  end

  # +lum+ with the pixels of +cur+ that equal the colour +key+ made white.
  def self.png_key_row(cur, lum, width, key)
    size = key.bytesize
    row = String.new(capacity: width, encoding: Encoding::BINARY)
    i = 0
    o = 0
    while i < width
      j = 0
      while j < size && cur.getbyte(o + j) == key.getbyte(j)
        j += 1
      end
      row << (j == size ? 255 : lum.getbyte(i))
      o += size
      i += 1
    end
    row
  end

  # --- the five filter types, reversed, for any pixel size ------------------

  def self.png_sub(raw, ri, len, bpp)
    # (A byteslice of +raw+ would be a UTF-8 String in the native build,
    # where << then appends characters, not bytes: build a binary one.)
    cur = String.new(capacity: len, encoding: Encoding::BINARY)
    k = 0
    while k < bpp
      cur << raw.getbyte(ri + k)
      k += 1
    end
    while k < len
      cur << ((raw.getbyte(ri + k) + cur.getbyte(k - bpp)) & 0xff)
      k += 1
    end
    cur
  end

  def self.png_sub1(raw, ri, len)
    cur = String.new(capacity: len, encoding: Encoding::BINARY)
    a = 0
    stop = ri + len
    while ri < stop
      a = (raw.getbyte(ri) + a) & 0xff
      cur << a
      ri += 1
    end
    cur
  end

  def self.png_up(raw, ri, prev, len)
    cur = String.new(capacity: len, encoding: Encoding::BINARY)
    k = 0
    while k < len
      cur << ((raw.getbyte(ri + k) + prev.getbyte(k)) & 0xff)
      k += 1
    end
    cur
  end

  def self.png_avg(raw, ri, prev, len, bpp)
    cur = String.new(capacity: len, encoding: Encoding::BINARY)
    k = 0
    while k < bpp && k < len
      cur << ((raw.getbyte(ri + k) + (prev.getbyte(k) >> 1)) & 0xff)
      k += 1
    end
    while k < len
      cur << ((raw.getbyte(ri + k) + ((cur.getbyte(k - bpp) + prev.getbyte(k)) >> 1)) & 0xff)
      k += 1
    end
    cur
  end

  def self.png_avg1(raw, ri, prev, len)
    cur = String.new(capacity: len, encoding: Encoding::BINARY)
    a = 0
    k = 0
    while k < len
      a = (raw.getbyte(ri + k) + ((a + prev.getbyte(k)) >> 1)) & 0xff
      cur << a
      k += 1
    end
    cur
  end

  def self.png_paeth(raw, ri, prev, len, bpp, t)
    cur = String.new(capacity: len, encoding: Encoding::BINARY)
    k = 0
    while k < bpp && k < len
      cur << ((raw.getbyte(ri + k) + prev.getbyte(k)) & 0xff)
      k += 1
    end
    while k < len
      c = prev.getbyte(k - bpp)
      cur << ((raw.getbyte(ri + k) + c + t[(prev.getbyte(k) - c) * 511 + cur.getbyte(k - bpp) - c + 130_560]) & 0xff)
      k += 1
    end
    cur
  end

  def self.png_paeth1(raw, ri, prev, len, t)
    cur = String.new(capacity: len, encoding: Encoding::BINARY)
    a = c = 0
    k = 0
    while k < len
      u = prev.getbyte(k)
      a = (raw.getbyte(ri + k) + c + t[(u - c) * 511 + a - c + 130_560]) & 0xff
      cur << a
      c = u
      k += 1
    end
    cur
  end

  # --- fused: unfilter + luminance, 8-bit gray + alpha ----------------------
  # Each returns the unfiltered row followed by the row's luminance.

  def self.png_ga8_sub(raw, ri, len)
    cur = String.new(capacity: len + (len >> 1), encoding: Encoding::BINARY)
    lum = String.new(capacity: len >> 1, encoding: Encoding::BINARY)
    v = a = 0
    i = ri
    stop = ri + len
    while i < stop
      v = (raw.getbyte(i) + v) & 0xff
      a = (raw.getbyte(i + 1) + a) & 0xff
      cur << v << a
      lum << (a == 255 ? v : ((v - 255) * a + 65_152) / 255)
      i += 2
    end
    cur << lum
  end

  def self.png_ga8_up(raw, ri, prev, len)
    cur = String.new(capacity: len + (len >> 1), encoding: Encoding::BINARY)
    lum = String.new(capacity: len >> 1, encoding: Encoding::BINARY)
    k = 0
    i = ri
    while k < len
      v = (raw.getbyte(i) + prev.getbyte(k)) & 0xff
      a = (raw.getbyte(i + 1) + prev.getbyte(k + 1)) & 0xff
      cur << v << a
      lum << (a == 255 ? v : ((v - 255) * a + 65_152) / 255)
      k += 2
      i += 2
    end
    cur << lum
  end

  def self.png_ga8_avg(raw, ri, prev, len)
    cur = String.new(capacity: len + (len >> 1), encoding: Encoding::BINARY)
    lum = String.new(capacity: len >> 1, encoding: Encoding::BINARY)
    v = a = 0
    k = 0
    i = ri
    while k < len
      v = (raw.getbyte(i) + ((v + prev.getbyte(k)) >> 1)) & 0xff
      a = (raw.getbyte(i + 1) + ((a + prev.getbyte(k + 1)) >> 1)) & 0xff
      cur << v << a
      lum << (a == 255 ? v : ((v - 255) * a + 65_152) / 255)
      k += 2
      i += 2
    end
    cur << lum
  end

  def self.png_ga8_paeth(raw, ri, prev, len, t)
    cur = String.new(capacity: len + (len >> 1), encoding: Encoding::BINARY)
    lum = String.new(capacity: len >> 1, encoding: Encoding::BINARY)
    v = a = cv = ca = 0
    k = 0
    i = ri
    while k < len
      u = prev.getbyte(k)
      v = (raw.getbyte(i) + cv + t[(u - cv) * 511 + v - cv + 130_560]) & 0xff
      cv = u
      u = prev.getbyte(k + 1)
      a = (raw.getbyte(i + 1) + ca + t[(u - ca) * 511 + a - ca + 130_560]) & 0xff
      ca = u
      cur << v << a
      lum << (a == 255 ? v : ((v - 255) * a + 65_152) / 255)
      k += 2
      i += 2
    end
    cur << lum
  end

  # --- fused: unfilter + luminance, 8-bit RGB -------------------------------

  def self.png_rgb8_sub(raw, ri, len)
    cur = String.new(capacity: len + len / 3, encoding: Encoding::BINARY)
    lum = String.new(capacity: len / 3, encoding: Encoding::BINARY)
    r = g = b = 0
    i = ri
    stop = ri + len
    while i < stop
      r = (raw.getbyte(i) + r) & 0xff
      g = (raw.getbyte(i + 1) + g) & 0xff
      b = (raw.getbyte(i + 2) + b) & 0xff
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      i += 3
    end
    cur << lum
  end

  def self.png_rgb8_up(raw, ri, prev, len)
    cur = String.new(capacity: len + len / 3, encoding: Encoding::BINARY)
    lum = String.new(capacity: len / 3, encoding: Encoding::BINARY)
    k = 0
    i = ri
    while k < len
      r = (raw.getbyte(i) + prev.getbyte(k)) & 0xff
      g = (raw.getbyte(i + 1) + prev.getbyte(k + 1)) & 0xff
      b = (raw.getbyte(i + 2) + prev.getbyte(k + 2)) & 0xff
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      k += 3
      i += 3
    end
    cur << lum
  end

  def self.png_rgb8_avg(raw, ri, prev, len)
    cur = String.new(capacity: len + len / 3, encoding: Encoding::BINARY)
    lum = String.new(capacity: len / 3, encoding: Encoding::BINARY)
    r = g = b = 0
    k = 0
    i = ri
    while k < len
      r = (raw.getbyte(i) + ((r + prev.getbyte(k)) >> 1)) & 0xff
      g = (raw.getbyte(i + 1) + ((g + prev.getbyte(k + 1)) >> 1)) & 0xff
      b = (raw.getbyte(i + 2) + ((b + prev.getbyte(k + 2)) >> 1)) & 0xff
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      k += 3
      i += 3
    end
    cur << lum
  end

  def self.png_rgb8_paeth(raw, ri, prev, len, t)
    cur = String.new(capacity: len + len / 3, encoding: Encoding::BINARY)
    lum = String.new(capacity: len / 3, encoding: Encoding::BINARY)
    r = g = b = cr = cg = cb = 0
    k = 0
    i = ri
    while k < len
      u = prev.getbyte(k)
      r = (raw.getbyte(i) + cr + t[(u - cr) * 511 + r - cr + 130_560]) & 0xff
      cr = u
      u = prev.getbyte(k + 1)
      g = (raw.getbyte(i + 1) + cg + t[(u - cg) * 511 + g - cg + 130_560]) & 0xff
      cg = u
      u = prev.getbyte(k + 2)
      b = (raw.getbyte(i + 2) + cb + t[(u - cb) * 511 + b - cb + 130_560]) & 0xff
      cb = u
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      k += 3
      i += 3
    end
    cur << lum
  end

  # --- fused: unfilter + luminance, 8-bit RGBA ------------------------------

  def self.png_rgba8_sub(raw, ri, len)
    cur = String.new(capacity: len + (len >> 2), encoding: Encoding::BINARY)
    lum = String.new(capacity: len >> 2, encoding: Encoding::BINARY)
    r = g = b = a = 0
    i = ri
    stop = ri + len
    while i < stop
      r = (raw.getbyte(i) + r) & 0xff
      g = (raw.getbyte(i + 1) + g) & 0xff
      b = (raw.getbyte(i + 2) + b) & 0xff
      a = (raw.getbyte(i + 3) + a) & 0xff
      cur << r << g << b << a
      v = (306 * r + 601 * g + 117 * b + 0x200) >> 10
      lum << (a == 255 ? v : ((v - 255) * a + 65_152) / 255)
      i += 4
    end
    cur << lum
  end

  def self.png_rgba8_up(raw, ri, prev, len)
    cur = String.new(capacity: len + (len >> 2), encoding: Encoding::BINARY)
    lum = String.new(capacity: len >> 2, encoding: Encoding::BINARY)
    k = 0
    i = ri
    while k < len
      r = (raw.getbyte(i) + prev.getbyte(k)) & 0xff
      g = (raw.getbyte(i + 1) + prev.getbyte(k + 1)) & 0xff
      b = (raw.getbyte(i + 2) + prev.getbyte(k + 2)) & 0xff
      a = (raw.getbyte(i + 3) + prev.getbyte(k + 3)) & 0xff
      cur << r << g << b << a
      v = (306 * r + 601 * g + 117 * b + 0x200) >> 10
      lum << (a == 255 ? v : ((v - 255) * a + 65_152) / 255)
      k += 4
      i += 4
    end
    cur << lum
  end

  def self.png_rgba8_avg(raw, ri, prev, len)
    cur = String.new(capacity: len + (len >> 2), encoding: Encoding::BINARY)
    lum = String.new(capacity: len >> 2, encoding: Encoding::BINARY)
    r = g = b = a = 0
    k = 0
    i = ri
    while k < len
      r = (raw.getbyte(i) + ((r + prev.getbyte(k)) >> 1)) & 0xff
      g = (raw.getbyte(i + 1) + ((g + prev.getbyte(k + 1)) >> 1)) & 0xff
      b = (raw.getbyte(i + 2) + ((b + prev.getbyte(k + 2)) >> 1)) & 0xff
      a = (raw.getbyte(i + 3) + ((a + prev.getbyte(k + 3)) >> 1)) & 0xff
      cur << r << g << b << a
      v = (306 * r + 601 * g + 117 * b + 0x200) >> 10
      lum << (a == 255 ? v : ((v - 255) * a + 65_152) / 255)
      k += 4
      i += 4
    end
    cur << lum
  end

  def self.png_rgba8_paeth(raw, ri, prev, len, t)
    cur = String.new(capacity: len + (len >> 2), encoding: Encoding::BINARY)
    lum = String.new(capacity: len >> 2, encoding: Encoding::BINARY)
    r = g = b = a = cr = cg = cb = ca = 0
    k = 0
    i = ri
    while k < len
      u = prev.getbyte(k)
      r = (raw.getbyte(i) + cr + t[(u - cr) * 511 + r - cr + 130_560]) & 0xff
      cr = u
      u = prev.getbyte(k + 1)
      g = (raw.getbyte(i + 1) + cg + t[(u - cg) * 511 + g - cg + 130_560]) & 0xff
      cg = u
      u = prev.getbyte(k + 2)
      b = (raw.getbyte(i + 2) + cb + t[(u - cb) * 511 + b - cb + 130_560]) & 0xff
      cb = u
      u = prev.getbyte(k + 3)
      a = (raw.getbyte(i + 3) + ca + t[(u - ca) * 511 + a - ca + 130_560]) & 0xff
      ca = u
      cur << r << g << b << a
      v = (306 * r + 601 * g + 117 * b + 0x200) >> 10
      lum << (a == 255 ? v : ((v - 255) * a + 65_152) / 255)
      k += 4
      i += 4
    end
    cur << lum
  end
end
