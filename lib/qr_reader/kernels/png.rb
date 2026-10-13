# frozen_string_literal: true

require_relative "../errors"
require_relative "pixels"

# PNG kernels: row unfiltering fused with the conversion to luminance.
# Plain Ruby in the subset Spinel compiles (see DESIGN.md, "Kernels").
#
# Rows are unfiltered into a fresh String per row (appending with String#<<
# is much cheaper than setbyte under YJIT). PNG filters work on bytes, each
# byte predicted from the same byte of the pixel to the left, above and
# above-left, so the bytes of every sample position form independent lanes:
# for 16-bit samples only the high-byte lanes are unfiltered (the low bytes
# never reach the luminance), which halves the work. 8 and 16-bit gray,
# gray+alpha, RGB and RGBA rows are unfiltered and converted in one pass by
# fused helpers (one per filter type and layout); rows whose filtered bytes
# are all zero with the Up filter (flat areas: margins, backgrounds) are
# the previous row again and cost a memcmp.
#
# Each helper is a small method called once per row: YJIT compiles methods,
# not loops, and keeping dispatch out of the loops means that one layout
# never makes another one's loop side-exit. Methods with a byte loop
# reference no constants and call nothing that does (tables are passed in
# as arguments, buffers come from png_buf): with YJIT (Ruby 4.0), when a
# constant cache in the loop method or in a method it calls is invalidated
# after compilation - e.g. Encoding::BINARY once any constant named BINARY
# is defined anywhere (decoder/character_set.rb, Zlib) - the loop keeps
# running at interpreter speed, 5-7x slower, for the rest of the process.
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
      s = png_buf(8)
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

  # An empty binary String with room for +size+ bytes. (String.new without
  # a source String is binary; naming Encoding::BINARY here would put a
  # constant cache into every row helper's call path, see the module
  # comment.)
  def self.png_buf(size)
    String.new(capacity: size)
  end

  PNG_PAETH = png_paeth_table.freeze
  PNG_UNPACK1 = png_unpack_table(1).freeze
  PNG_UNPACK2 = png_unpack_table(2).freeze
  PNG_UNPACK4 = png_unpack_table(4).freeze
  # Adam7 passes: x0, y0, dx, dy.
  PNG_ADAM7 = [0, 0, 8, 8, 4, 0, 8, 8, 0, 4, 4, 8, 2, 0, 4, 4, 0, 2, 2, 4, 1, 0, 2, 2, 0, 1, 1, 2].freeze

  # Unfilters +rows+ rows of +width+ pixels (+channels+ samples of +depth+
  # bits each), stored from byte +pos+ of +raw+ as a filter type byte
  # followed by the filtered row, and converts them:
  #
  # * gray/palette of depth <= 8 (+channels+ 1): the unfiltered rows as
  #   they are, (width * depth + 7) / 8 bytes each (sample values, packed
  #   below 8 bits), for the caller to map;
  # * otherwise: width bytes of luminance per row, alpha over white, 16-bit
  #   samples by their high byte. +key+ is the tRNS colour key as raw sample
  #   bytes (16-bit gray, 8/16-bit RGB): matching pixels become white; ""
  #   for none.
  #
  # +prev+ is the previous row as this kernel returned it ("" at the top of
  # an image or pass). Returns the converted rows followed by the last
  # unfiltered row (the +prev+ of the next call when an image is decoded in
  # slices; its size depends on the layout).
  # spinel-sample: QrReaderKernels.png_rows("\x01\x10\x20\x03\x01\x02".b, 0, 2, 2, 8, 1, "".b, "".b)
  def self.png_rows(raw, pos, rows, width, depth, channels, prev, key)
    t = PNG_PAETH
    if channels == 1 && depth <= 8
      png_rows_bytes(raw, pos, rows, (width * depth + 7) >> 3, prev, t)
    elsif key.bytesize > 0
      png_rows_keyed(raw, pos, rows, width, depth, channels, prev, key, t)
    elsif channels == 2 || channels == 4
      png_rows_alpha(raw, pos, rows, width, channels, depth >> 3, prev, t)
    else
      png_rows_luma(raw, pos, rows, width, channels, depth >> 3, prev, t)
    end
  end

  def self.png_check(raw, pos, rows, len)
    raise QrReader::ImageError, "truncated PNG image data" if pos + rows * (len + 1) > raw.bytesize
  end

  def self.png_bad_filter(filter)
    raise QrReader::ImageError, "invalid PNG filter type #{filter}"
  end

  # +len+ zero bytes.
  def self.png_zeros(len)
    "\0".b * len
  end

  # True if the +len+ filtered bytes at +ri+ are all zero (cheap rejection
  # first: noisy rows rarely start and end with zero).
  def self.png_zero_row(raw, ri, len, zeros)
    raw.getbyte(ri) == 0 && raw.getbyte(ri + len - 1) == 0 && raw.byteslice(ri, len) == zeros
  end

  # Rows of +len+ one-byte samples (gray or palette, any depth <= 8).
  def self.png_rows_bytes(raw, pos, rows, len, prev, t)
    png_check(raw, pos, rows, len)
    prev = png_zeros(len) if prev.bytesize < len
    zeros = png_zeros(len)
    out = png_buf(rows * len + len)
    y = 0
    while y < rows
      filter = raw.getbyte(pos)
      ri = pos + 1
      cur =
        if filter == 0
          raw.byteslice(ri, len) || ""
        elsif filter == 2 && png_zero_row(raw, ri, len, zeros)
          prev
        else
          png_bad_filter(filter) if filter > 4
          png_gray_row(raw, ri, prev, len, 1, filter, t)
        end
      out << cur
      prev = cur
      pos = ri + len
      y += 1
    end
    out << prev
  end

  # Rows of 8 or 16-bit (+sw+ = 1 or 2 bytes per sample) gray or RGB
  # without colour key: luminance. +prev+ / the returned last row hold the
  # high bytes only (width * channels bytes).
  def self.png_rows_luma(raw, pos, rows, width, channels, sw, prev, t)
    clen = width * channels
    rlen = clen * sw
    png_check(raw, pos, rows, rlen)
    prev = png_zeros(clen) if prev.bytesize < clen
    zeros = png_zeros(rlen)
    out = png_buf(rows * width + clen)
    prev_lum = "" # luminance of prev, computed when first needed
    y = 0
    while y < rows
      filter = raw.getbyte(pos)
      ri = pos + 1
      if filter == 2 && png_zero_row(raw, ri, rlen, zeros)
        cur = prev
        prev_lum = png_luma(prev, width, channels) if prev_lum.bytesize == 0
        lum = prev_lum
      elsif filter == 0
        cur = sw == 1 ? (raw.byteslice(ri, clen) || "") : px_gray_row(raw, ri, clen, 0, 2)
        lum = png_luma(cur, width, channels)
      else
        png_bad_filter(filter) if filter > 4
        cur = png_fused_row(raw, ri, prev, width, channels, sw, filter, t)
        lum = channels == 1 ? cur : (cur.byteslice(clen, width) || "")
      end
      out << lum
      prev = cur
      prev_lum = lum
      pos = ri + rlen
      y += 1
    end
    out << (prev.byteslice(0, clen) || "")
  end

  # Rows of 8 or 16-bit gray+alpha or RGBA: luminance over white. Rows
  # that are entirely opaque (alpha 255, the common case) are tracked as
  # such: while the row above is opaque, the next one is unfiltered by the
  # opaque helpers, which skip the alpha lane (it stays 255 exactly when its
  # filtered bytes are 0, the first pixel aside) and keep the colour
  # samples only. A row that turns out not to be opaque is redone by the
  # full helpers, which report whether their row was opaque. The returned
  # last row has width * channels bytes, or width * (channels - 1) when
  # opaque (that is how +prev+ tells).
  def self.png_rows_alpha(raw, pos, rows, width, channels, sw, prev, t)
    clen = width * channels
    olen = clen - width
    rlen = clen * sw
    png_check(raw, pos, rows, rlen)
    opaque = prev.bytesize == olen
    prev = png_zeros(clen) if !opaque && prev.bytesize < clen
    zeros = png_zeros(rlen)
    out = png_buf(rows * width + clen)
    prev_lum = "" # luminance of prev, computed when first needed
    y = 0
    while y < rows
      filter = raw.getbyte(pos)
      ri = pos + 1
      if filter == 2 && png_zero_row(raw, ri, rlen, zeros)
        cur = prev
        prev_lum = png_alpha_luma(prev, width, channels, opaque) if prev_lum.bytesize == 0
        lum = prev_lum
      elsif filter == 0
        cur = sw == 1 ? (raw.byteslice(ri, clen) || "") : px_gray_row(raw, ri, clen, 0, 2)
        lum = png_luma(cur, width, channels)
        opaque = false
      else
        png_bad_filter(filter) if filter > 4
        cur = ""
        if opaque
          cur = png_opaque_row(raw, ri, prev, width, channels, sw, filter, t)
          if cur.bytesize == 0
            prev = png_unopaque(prev, width, channels)
            opaque = false
          end
        end
        if opaque
          lum = channels == 2 ? cur : (cur.byteslice(olen, width) || "")
        else
          cur = png_fused_row(raw, ri, prev, width, channels, sw, filter, t)
          lum = cur.byteslice(clen, width) || ""
          if cur.getbyte(clen + width) == 255
            opaque = true
            cur = channels == 2 ? lum : png_rgb_lanes(cur, width)
          end
        end
      end
      out << lum
      prev = cur
      prev_lum = lum
      pos = ri + rlen
      y += 1
    end
    out << (prev.byteslice(0, opaque ? olen : clen) || "")
  end

  # Luminance of a previous row (opaque: colour samples only).
  def self.png_alpha_luma(prev, width, channels, opaque)
    if opaque
      channels == 2 ? (prev.byteslice(0, width) || "") : px_rgb_row(prev, 0, width, 0, 1, 2, 3)
    else
      png_luma(prev, width, channels)
    end
  end

  # An opaque row (colour samples only) with its alpha samples (255) back.
  def self.png_unopaque(prev, width, channels)
    row = png_buf(width * channels)
    k = 0
    if channels == 2
      while k < width
        row << prev.getbyte(k) << 255
        k += 1
      end
    else
      stop = 3 * width
      while k < stop
        row << prev.getbyte(k) << prev.getbyte(k + 1) << prev.getbyte(k + 2) << 255
        k += 3
      end
    end
    row
  end

  # The RGB samples of an RGBA row.
  def self.png_rgb_lanes(cur, width)
    row = png_buf(3 * width)
    k = 0
    stop = 4 * width
    while k < stop
      row << cur.getbyte(k) << cur.getbyte(k + 1) << cur.getbyte(k + 2)
      k += 4
    end
    row
  end

  # Rows with a tRNS colour key (16-bit gray, 8/16-bit RGB): the key
  # compares whole samples, so every byte is unfiltered.
  def self.png_rows_keyed(raw, pos, rows, width, depth, channels, prev, key, t)
    len = (width * channels * depth + 7) >> 3
    bpp = (channels * depth + 7) >> 3
    png_check(raw, pos, rows, len)
    prev = png_zeros(len) if prev.bytesize < len
    out = png_buf(rows * width + len)
    sw = depth >> 3
    y = 0
    while y < rows
      filter = raw.getbyte(pos)
      png_bad_filter(filter) if filter > 4
      ri = pos + 1
      cur = png_unfilter_row(raw, ri, prev, len, bpp, filter, t)
      lum = channels == 1 ? px_gray_row(cur, 0, width, 0, sw) : px_rgb_row(cur, 0, width, 0, sw, 2 * sw, 3 * sw)
      out << png_key_row(cur, lum, width, key)
      prev = cur
      pos = ri + len
      y += 1
    end
    out << prev
  end

  # Luminance of a row of 8-bit samples (high bytes) of +channels+ each.
  def self.png_luma(cur, width, channels)
    case channels
    when 1 then cur.byteslice(0, width) || ""
    when 2 then px_gray_alpha_row(cur, 0, width, 0, 1, 2)
    when 3 then px_rgb_row(cur, 0, width, 0, 1, 2, 3)
    else px_rgba_row(cur, 0, width, 0, 1, 2, 3, 4)
    end
  end

  # Decodes a whole Adam7-interlaced image: the seven passes stored one
  # after the other in +raw+ (as png_rows reads them), then scattered into
  # +width+ x +height+ output bytes (luminance or sample values, see
  # png_rows; samples below 8 bits come out one per byte).
  # spinel-sample: QrReaderKernels.png_adam7("\x00\x10".b, 1, 1, 8, 1, "".b)
  def self.png_adam7(raw, width, height, depth, channels, key)
    passes = png_buf(width * height)
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
        res = png_rows(raw, pos, ph, pw, depth, channels, "", key)
        len = (pw * channels * depth + 7) >> 3
        if channels == 1 && depth < 8
          passes << png_unpack_rows(res, ph, pw, len, depth)
        else
          passes << (res.byteslice(0, pw * ph) || "")
        end
        pos += ph * (1 + len)
      end
      p += 1
    end
    out = png_buf(width * height)
    y = 0
    while y < height
      if (y & 1) == 1
        # odd rows are pass 7 rows, complete
        start = starts[6] + (y >> 1) * width
        out << (passes.byteslice(start, width) || "")
      else
        out << png_adam7_row(passes, starts, widths, y, width, PNG_ADAM7)
      end
      y += 1
    end
    out
  end

  # Samples of 1, 2 or 4 bits of +rows+ packed rows (+len+ bytes each)
  # -> one byte per sample, +width+ per row.
  # spinel-sample: QrReaderKernels.png_unpack_rows("\xE4\x1B".b, 2, 3, 1, 2)
  def self.png_unpack_rows(packed, rows, width, len, depth)
    table = depth == 1 ? PNG_UNPACK1 : (depth == 2 ? PNG_UNPACK2 : PNG_UNPACK4)
    out = png_buf(rows * width)
    y = 0
    while y < rows
      out << png_unpack_row(packed, y * len, width, depth, table)
      y += 1
    end
    out
  end

  def self.png_unpack_row(packed, off, width, depth, table)
    per = 8 / depth
    full = width / per
    row = png_buf(width + per)
    i = off
    stop = off + full
    while i < stop
      row << table[packed.getbyte(i)]
      i += 1
    end
    rest = width - full * per
    row << (table[packed.getbyte(stop)].byteslice(0, rest) || "") if rest > 0
    row
  end

  # Even output row +y+ of an interlaced image from the decoded passes.
  def self.png_adam7_row(passes, starts, widths, y, width, a7)
    row = png_zeros(width)
    p = 0
    while p < 6
      pw = widths[p]
      y0 = a7[4 * p + 1]
      dy = a7[4 * p + 3]
      if pw > 0 && y >= y0 && (y - y0) % dy == 0
        png_scatter(row, passes, starts[p] + (y - y0) / dy * pw, pw, a7[4 * p], a7[4 * p + 2])
      end
      p += 1
    end
    row
  end

  # Copies +n+ bytes from +src+ at +from+ to every +dx+-th byte of +row+
  # starting at +x+ (+row+ is the caller's own String).
  def self.png_scatter(row, src, from, n, x, dx)
    stop = from + n
    while from < stop
      row.setbyte(x, src.getbyte(from))
      x += dx
      from += 1
    end
    row
  end

  # --- generic unfiltering (any pixel size, all bytes) -----------------------

  # The unfiltered row of +len+ bytes.
  def self.png_unfilter_row(raw, ri, prev, len, bpp, filter, t)
    case filter
    when 0 then raw.byteslice(ri, len) || ""
    when 1 then png_sub(raw, ri, len, bpp)
    when 2 then png_g_up(raw, ri, prev, len, 1)
    when 3 then png_avg(raw, ri, prev, len, bpp)
    else png_paeth(raw, ri, prev, len, bpp, t)
    end
  end

  # +lum+ with the pixels of +cur+ that equal the colour +key+ made white.
  def self.png_key_row(cur, lum, width, key)
    size = key.bytesize
    row = png_buf(width)
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

  def self.png_sub(raw, ri, len, bpp)
    # (A byteslice of +raw+ would be a UTF-8 String in the native build,
    # where << then appends characters, not bytes: build a binary one.)
    cur = png_buf(len)
    k = 0
    while k < bpp && k < len
      cur << raw.getbyte(ri + k)
      k += 1
    end
    while k < len
      cur << ((raw.getbyte(ri + k) + cur.getbyte(k - bpp)) & 0xff)
      k += 1
    end
    cur
  end

  def self.png_avg(raw, ri, prev, len, bpp)
    cur = png_buf(len)
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

  def self.png_paeth(raw, ri, prev, len, bpp, t)
    cur = png_buf(len)
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

  # --- fused: unfilter (+ luminance) per layout --------------------------------
  # Arguments: the filtered row starts at byte +i+ of +raw+, +n+ pixels,
  # +sw+ bytes per sample (only the first, high byte of each is read);
  # +prev+ holds the previous row's (high) sample bytes. Gray helpers return
  # the unfiltered row (which is its luminance); the others return the
  # unfiltered row followed by the row's luminance, and those with alpha
  # then one more byte: 255 if every alpha sample was 255. (Dispatchers return a
  # String on every branch, never nil: in the native build a nilable String
  # would make every byte loop that reads it polymorphic.)

  def self.png_fused_row(raw, i, prev, n, channels, sw, filter, t)
    case channels
    when 1 then png_gray_row(raw, i, prev, n, sw, filter, t)
    when 2
      case filter
      when 1 then png_ga_sub(raw, i, n, sw)
      when 2 then png_ga_up(raw, i, prev, n, sw)
      when 3 then png_ga_avg(raw, i, prev, n, sw)
      else png_ga_paeth(raw, i, prev, n, sw, t)
      end
    when 3
      case filter
      when 1 then png_rgb_sub(raw, i, n, sw)
      when 2 then png_rgb_up(raw, i, prev, n, sw)
      when 3 then png_rgb_avg(raw, i, prev, n, sw)
      else png_rgb_paeth(raw, i, prev, n, sw, t)
      end
    else
      case filter
      when 1 then png_rgba_sub(raw, i, n, sw)
      when 2 then png_rgba_up(raw, i, prev, n, sw)
      when 3 then png_rgba_avg(raw, i, prev, n, sw)
      else png_rgba_paeth(raw, i, prev, n, sw, t)
      end
    end
  end

  # One gray sample per pixel (also packed low-depth and palette rows,
  # byte by byte: +n+ bytes, +sw+ 1). Average and Paeth, the filters that
  # noisy scans use most, do two bytes per iteration when +sw+ is 1 (10%
  # faster with YJIT).
  def self.png_gray_row(raw, i, prev, n, sw, filter, t)
    case filter
    when 1 then png_g_sub(raw, i, n, sw)
    when 2 then png_g_up(raw, i, prev, n, sw)
    when 3 then png_g_avg(raw, i, prev, n, sw)
    else png_g_paeth(raw, i, prev, n, sw, t)
    end
  end

  def self.png_g_sub(raw, i, n, sw)
    cur = png_buf(n)
    v = 0
    stop = i + n * sw
    while i < stop
      v = (raw.getbyte(i) + v) & 0xff
      cur << v
      i += sw
    end
    cur
  end

  def self.png_g_up(raw, i, prev, n, sw)
    cur = png_buf(n)
    k = 0
    while k < n
      cur << ((raw.getbyte(i) + prev.getbyte(k)) & 0xff)
      i += sw
      k += 1
    end
    cur
  end

  def self.png_g_avg(raw, i, prev, n, sw)
    cur = png_buf(n)
    v = 0
    k = 0
    if sw == 1
      stop = n - 1
      while k < stop
        v = (raw.getbyte(i) + ((v + prev.getbyte(k)) >> 1)) & 0xff
        w = (raw.getbyte(i + 1) + ((v + prev.getbyte(k + 1)) >> 1)) & 0xff
        cur << v << w
        v = w
        i += 2
        k += 2
      end
    end
    while k < n
      v = (raw.getbyte(i) + ((v + prev.getbyte(k)) >> 1)) & 0xff
      cur << v
      i += sw
      k += 1
    end
    cur
  end

  def self.png_g_paeth(raw, i, prev, n, sw, t)
    cur = png_buf(n)
    v = c = 0
    k = 0
    if sw == 1
      stop = n - 1
      while k < stop
        u = prev.getbyte(k)
        v = (raw.getbyte(i) + c + t[(u - c) * 511 + v - c + 130_560]) & 0xff
        c = prev.getbyte(k + 1)
        w = (raw.getbyte(i + 1) + u + t[(c - u) * 511 + v - u + 130_560]) & 0xff
        cur << v << w
        v = w
        i += 2
        k += 2
      end
    end
    while k < n
      u = prev.getbyte(k)
      v = (raw.getbyte(i) + c + t[(u - c) * 511 + v - c + 130_560]) & 0xff
      cur << v
      c = u
      i += sw
      k += 1
    end
    cur
  end

  # --- opaque rows: colour lanes only ----------------------------------------
  # The row above is opaque and given by its colour samples. Each helper
  # returns "" as soon as an alpha byte shows that this row is not opaque
  # (alpha 255 needs filtered alpha 0, except for the first pixel: 255 for
  # Sub, whose left neighbour is 0, and 128 for Average, (0 + 255) >> 1 =
  # 127), otherwise the gray samples (= the luminance) or the RGB samples
  # followed by the luminance.

  def self.png_opaque_row(raw, i, prev, n, channels, sw, filter, t)
    if channels == 2
      case filter
      when 1 then png_gao_sub(raw, i, n, sw)
      when 2 then png_gao_up(raw, i, prev, n, sw)
      when 3 then png_gao_avg(raw, i, prev, n, sw)
      else png_gao_paeth(raw, i, prev, n, sw, t)
      end
    else
      case filter
      when 1 then png_rgbo_sub(raw, i, n, sw)
      when 2 then png_rgbo_up(raw, i, prev, n, sw)
      when 3 then png_rgbo_avg(raw, i, prev, n, sw)
      else png_rgbo_paeth(raw, i, prev, n, sw, t)
      end
    end
  end

  def self.png_gao_sub(raw, i, n, sw)
    return "" if raw.getbyte(i + sw) != 255

    cur = png_buf(n)
    v = raw.getbyte(i)
    cur << v
    step = 2 * sw
    i += step
    stop = i + (n - 1) * step
    while i < stop
      return "" if raw.getbyte(i + sw) != 0

      v = (raw.getbyte(i) + v) & 0xff
      cur << v
      i += step
    end
    cur
  end

  def self.png_gao_up(raw, i, prev, n, sw)
    cur = png_buf(n)
    step = 2 * sw
    k = 0
    while k < n
      return "" if raw.getbyte(i + sw) != 0

      cur << ((raw.getbyte(i) + prev.getbyte(k)) & 0xff)
      i += step
      k += 1
    end
    cur
  end

  def self.png_gao_avg(raw, i, prev, n, sw)
    return "" if raw.getbyte(i + sw) != 128

    cur = png_buf(n)
    v = (raw.getbyte(i) + (prev.getbyte(0) >> 1)) & 0xff
    cur << v
    step = 2 * sw
    i += step
    k = 1
    while k < n
      return "" if raw.getbyte(i + sw) != 0

      v = (raw.getbyte(i) + ((v + prev.getbyte(k)) >> 1)) & 0xff
      cur << v
      i += step
      k += 1
    end
    cur
  end

  def self.png_gao_paeth(raw, i, prev, n, sw, t)
    cur = png_buf(n)
    v = c = 0
    step = 2 * sw
    k = 0
    while k < n
      return "" if raw.getbyte(i + sw) != 0

      u = prev.getbyte(k)
      v = (raw.getbyte(i) + c + t[(u - c) * 511 + v - c + 130_560]) & 0xff
      cur << v
      c = u
      i += step
      k += 1
    end
    cur
  end

  def self.png_rgbo_sub(raw, i, n, sw)
    s2 = 2 * sw
    s3 = 3 * sw
    return "" if raw.getbyte(i + s3) != 255

    cur = png_buf(4 * n)
    lum = png_buf(n)
    r = raw.getbyte(i)
    g = raw.getbyte(i + sw)
    b = raw.getbyte(i + s2)
    cur << r << g << b
    lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
    step = 4 * sw
    i += step
    stop = i + (n - 1) * step
    while i < stop
      return "" if raw.getbyte(i + s3) != 0

      r = (raw.getbyte(i) + r) & 0xff
      g = (raw.getbyte(i + sw) + g) & 0xff
      b = (raw.getbyte(i + s2) + b) & 0xff
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      i += step
    end
    cur << lum
  end

  def self.png_rgbo_up(raw, i, prev, n, sw)
    cur = png_buf(4 * n)
    lum = png_buf(n)
    s2 = 2 * sw
    s3 = 3 * sw
    step = 4 * sw
    k = 0
    stop = 3 * n
    while k < stop
      return "" if raw.getbyte(i + s3) != 0

      r = (raw.getbyte(i) + prev.getbyte(k)) & 0xff
      g = (raw.getbyte(i + sw) + prev.getbyte(k + 1)) & 0xff
      b = (raw.getbyte(i + s2) + prev.getbyte(k + 2)) & 0xff
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      i += step
      k += 3
    end
    cur << lum
  end

  def self.png_rgbo_avg(raw, i, prev, n, sw)
    s2 = 2 * sw
    s3 = 3 * sw
    return "" if raw.getbyte(i + s3) != 128

    cur = png_buf(4 * n)
    lum = png_buf(n)
    r = (raw.getbyte(i) + (prev.getbyte(0) >> 1)) & 0xff
    g = (raw.getbyte(i + sw) + (prev.getbyte(1) >> 1)) & 0xff
    b = (raw.getbyte(i + s2) + (prev.getbyte(2) >> 1)) & 0xff
    cur << r << g << b
    lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
    step = 4 * sw
    i += step
    k = 3
    stop = 3 * n
    while k < stop
      return "" if raw.getbyte(i + s3) != 0

      r = (raw.getbyte(i) + ((r + prev.getbyte(k)) >> 1)) & 0xff
      g = (raw.getbyte(i + sw) + ((g + prev.getbyte(k + 1)) >> 1)) & 0xff
      b = (raw.getbyte(i + s2) + ((b + prev.getbyte(k + 2)) >> 1)) & 0xff
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      i += step
      k += 3
    end
    cur << lum
  end

  def self.png_rgbo_paeth(raw, i, prev, n, sw, t)
    cur = png_buf(4 * n)
    lum = png_buf(n)
    r = g = b = cr = cg = cb = 0
    s2 = 2 * sw
    s3 = 3 * sw
    step = 4 * sw
    k = 0
    stop = 3 * n
    while k < stop
      return "" if raw.getbyte(i + s3) != 0

      u = prev.getbyte(k)
      r = (raw.getbyte(i) + cr + t[(u - cr) * 511 + r - cr + 130_560]) & 0xff
      cr = u
      u = prev.getbyte(k + 1)
      g = (raw.getbyte(i + sw) + cg + t[(u - cg) * 511 + g - cg + 130_560]) & 0xff
      cg = u
      u = prev.getbyte(k + 2)
      b = (raw.getbyte(i + s2) + cb + t[(u - cb) * 511 + b - cb + 130_560]) & 0xff
      cb = u
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      i += step
      k += 3
    end
    cur << lum
  end

  # --- gray + alpha -------------------------------------------------------------

  def self.png_ga_sub(raw, i, n, sw)
    cur = png_buf(3 * n + 1)
    lum = png_buf(n)
    m = 255
    v = a = 0
    step = 2 * sw
    stop = i + n * step
    while i < stop
      v = (raw.getbyte(i) + v) & 0xff
      a = (raw.getbyte(i + sw) + a) & 0xff
      cur << v << a
      lum << ((((v - 255) * a + 65_152) * 0x8081) >> 23)
      m &= a
      i += step
    end
    cur << lum << m
  end

  def self.png_ga_up(raw, i, prev, n, sw)
    cur = png_buf(3 * n + 1)
    lum = png_buf(n)
    m = 255
    step = 2 * sw
    k = 0
    stop = 2 * n
    while k < stop
      v = (raw.getbyte(i) + prev.getbyte(k)) & 0xff
      a = (raw.getbyte(i + sw) + prev.getbyte(k + 1)) & 0xff
      cur << v << a
      lum << ((((v - 255) * a + 65_152) * 0x8081) >> 23)
      m &= a
      i += step
      k += 2
    end
    cur << lum << m
  end

  def self.png_ga_avg(raw, i, prev, n, sw)
    cur = png_buf(3 * n + 1)
    lum = png_buf(n)
    m = 255
    v = a = 0
    step = 2 * sw
    k = 0
    stop = 2 * n
    while k < stop
      v = (raw.getbyte(i) + ((v + prev.getbyte(k)) >> 1)) & 0xff
      a = (raw.getbyte(i + sw) + ((a + prev.getbyte(k + 1)) >> 1)) & 0xff
      cur << v << a
      lum << ((((v - 255) * a + 65_152) * 0x8081) >> 23)
      m &= a
      i += step
      k += 2
    end
    cur << lum << m
  end

  def self.png_ga_paeth(raw, i, prev, n, sw, t)
    cur = png_buf(3 * n + 1)
    lum = png_buf(n)
    m = 255
    v = a = cv = ca = 0
    step = 2 * sw
    k = 0
    stop = 2 * n
    while k < stop
      u = prev.getbyte(k)
      v = (raw.getbyte(i) + cv + t[(u - cv) * 511 + v - cv + 130_560]) & 0xff
      cv = u
      u = prev.getbyte(k + 1)
      a = (raw.getbyte(i + sw) + ca + t[(u - ca) * 511 + a - ca + 130_560]) & 0xff
      ca = u
      cur << v << a
      lum << ((((v - 255) * a + 65_152) * 0x8081) >> 23)
      m &= a
      i += step
      k += 2
    end
    cur << lum << m
  end

  # --- RGB ------------------------------------------------------------------------

  def self.png_rgb_sub(raw, i, n, sw)
    cur = png_buf(4 * n)
    lum = png_buf(n)
    r = g = b = 0
    s2 = 2 * sw
    step = 3 * sw
    stop = i + n * step
    while i < stop
      r = (raw.getbyte(i) + r) & 0xff
      g = (raw.getbyte(i + sw) + g) & 0xff
      b = (raw.getbyte(i + s2) + b) & 0xff
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      i += step
    end
    cur << lum
  end

  def self.png_rgb_up(raw, i, prev, n, sw)
    cur = png_buf(4 * n)
    lum = png_buf(n)
    s2 = 2 * sw
    step = 3 * sw
    k = 0
    stop = 3 * n
    while k < stop
      r = (raw.getbyte(i) + prev.getbyte(k)) & 0xff
      g = (raw.getbyte(i + sw) + prev.getbyte(k + 1)) & 0xff
      b = (raw.getbyte(i + s2) + prev.getbyte(k + 2)) & 0xff
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      i += step
      k += 3
    end
    cur << lum
  end

  def self.png_rgb_avg(raw, i, prev, n, sw)
    cur = png_buf(4 * n)
    lum = png_buf(n)
    r = g = b = 0
    s2 = 2 * sw
    step = 3 * sw
    k = 0
    stop = 3 * n
    while k < stop
      r = (raw.getbyte(i) + ((r + prev.getbyte(k)) >> 1)) & 0xff
      g = (raw.getbyte(i + sw) + ((g + prev.getbyte(k + 1)) >> 1)) & 0xff
      b = (raw.getbyte(i + s2) + ((b + prev.getbyte(k + 2)) >> 1)) & 0xff
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      i += step
      k += 3
    end
    cur << lum
  end

  def self.png_rgb_paeth(raw, i, prev, n, sw, t)
    cur = png_buf(4 * n)
    lum = png_buf(n)
    r = g = b = cr = cg = cb = 0
    s2 = 2 * sw
    step = 3 * sw
    k = 0
    stop = 3 * n
    while k < stop
      u = prev.getbyte(k)
      r = (raw.getbyte(i) + cr + t[(u - cr) * 511 + r - cr + 130_560]) & 0xff
      cr = u
      u = prev.getbyte(k + 1)
      g = (raw.getbyte(i + sw) + cg + t[(u - cg) * 511 + g - cg + 130_560]) & 0xff
      cg = u
      u = prev.getbyte(k + 2)
      b = (raw.getbyte(i + s2) + cb + t[(u - cb) * 511 + b - cb + 130_560]) & 0xff
      cb = u
      cur << r << g << b
      lum << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
      i += step
      k += 3
    end
    cur << lum
  end

  # --- RGBA -----------------------------------------------------------------------

  def self.png_rgba_sub(raw, i, n, sw)
    cur = png_buf(5 * n + 1)
    lum = png_buf(n)
    m = 255
    r = g = b = a = 0
    s2 = 2 * sw
    s3 = 3 * sw
    step = 4 * sw
    stop = i + n * step
    while i < stop
      r = (raw.getbyte(i) + r) & 0xff
      g = (raw.getbyte(i + sw) + g) & 0xff
      b = (raw.getbyte(i + s2) + b) & 0xff
      a = (raw.getbyte(i + s3) + a) & 0xff
      cur << r << g << b << a
      v = (306 * r + 601 * g + 117 * b + 0x200) >> 10
      lum << ((((v - 255) * a + 65_152) * 0x8081) >> 23)
      m &= a
      i += step
    end
    cur << lum << m
  end

  def self.png_rgba_up(raw, i, prev, n, sw)
    cur = png_buf(5 * n + 1)
    lum = png_buf(n)
    m = 255
    s2 = 2 * sw
    s3 = 3 * sw
    step = 4 * sw
    k = 0
    stop = 4 * n
    while k < stop
      r = (raw.getbyte(i) + prev.getbyte(k)) & 0xff
      g = (raw.getbyte(i + sw) + prev.getbyte(k + 1)) & 0xff
      b = (raw.getbyte(i + s2) + prev.getbyte(k + 2)) & 0xff
      a = (raw.getbyte(i + s3) + prev.getbyte(k + 3)) & 0xff
      cur << r << g << b << a
      v = (306 * r + 601 * g + 117 * b + 0x200) >> 10
      lum << ((((v - 255) * a + 65_152) * 0x8081) >> 23)
      m &= a
      i += step
      k += 4
    end
    cur << lum << m
  end

  def self.png_rgba_avg(raw, i, prev, n, sw)
    cur = png_buf(5 * n + 1)
    lum = png_buf(n)
    m = 255
    r = g = b = a = 0
    s2 = 2 * sw
    s3 = 3 * sw
    step = 4 * sw
    k = 0
    stop = 4 * n
    while k < stop
      r = (raw.getbyte(i) + ((r + prev.getbyte(k)) >> 1)) & 0xff
      g = (raw.getbyte(i + sw) + ((g + prev.getbyte(k + 1)) >> 1)) & 0xff
      b = (raw.getbyte(i + s2) + ((b + prev.getbyte(k + 2)) >> 1)) & 0xff
      a = (raw.getbyte(i + s3) + ((a + prev.getbyte(k + 3)) >> 1)) & 0xff
      cur << r << g << b << a
      v = (306 * r + 601 * g + 117 * b + 0x200) >> 10
      lum << ((((v - 255) * a + 65_152) * 0x8081) >> 23)
      m &= a
      i += step
      k += 4
    end
    cur << lum << m
  end

  def self.png_rgba_paeth(raw, i, prev, n, sw, t)
    cur = png_buf(5 * n + 1)
    lum = png_buf(n)
    m = 255
    r = g = b = a = cr = cg = cb = ca = 0
    s2 = 2 * sw
    s3 = 3 * sw
    step = 4 * sw
    k = 0
    stop = 4 * n
    while k < stop
      u = prev.getbyte(k)
      r = (raw.getbyte(i) + cr + t[(u - cr) * 511 + r - cr + 130_560]) & 0xff
      cr = u
      u = prev.getbyte(k + 1)
      g = (raw.getbyte(i + sw) + cg + t[(u - cg) * 511 + g - cg + 130_560]) & 0xff
      cg = u
      u = prev.getbyte(k + 2)
      b = (raw.getbyte(i + s2) + cb + t[(u - cb) * 511 + b - cb + 130_560]) & 0xff
      cb = u
      u = prev.getbyte(k + 3)
      a = (raw.getbyte(i + s3) + ca + t[(u - ca) * 511 + a - ca + 130_560]) & 0xff
      ca = u
      cur << r << g << b << a
      v = (306 * r + 601 * g + 117 * b + 0x200) >> 10
      lum << ((((v - 255) * a + 65_152) * 0x8081) >> 23)
      m &= a
      i += step
      k += 4
    end
    cur << lum << m
  end
end
