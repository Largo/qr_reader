# frozen_string_literal: true

# Binarizer kernels: local-threshold binarization of a grayscale buffer
# into a bit buffer (one byte per pixel, 1 = dark). Kernel files are plain
# Ruby in the subset that Spinel compiles (see DESIGN.md, "Kernels"): the
# optional qr_reader-native gem builds them into a C extension, otherwise
# they run as they are. See QrReader::Binarizer for the methods.
module QrReaderKernels
  # Blocks with a luminance range up to this are treated as flat.
  BIN_MIN_RANGE = 24

  # zxing-cpp-like hybrid binarization of a width x height (both >= 40)
  # gray buffer: per 8x8 block the threshold (min + max) / 2 if it has
  # contrast, thresholds across edges that run exactly along block borders,
  # 5x5 block means of the thresholds, gaps filled in scan order. Returns
  # the bit buffer.
  # spinel-sample: QrReaderKernels.binarize_hybrid("\x10\xf0\x80\x20".b * 400, 40, 40)
  def self.binarize_hybrid(gray, width, height)
    sub_width = (width + 7) >> 3
    sub_height = (height + 7) >> 3
    size = sub_width * sub_height
    block = Array.new(size, 0)
    lows = Array.new(size, 0)
    highs = Array.new(size, 0)
    by = 0
    while by < sub_height
      y0 = by << 3
      y0 = height - 8 if y0 > height - 8
      bin_midranges_row(gray, width, y0 * width, block, lows, highs, by * sub_width, sub_width)
      by += 1
    end
    by = 0
    while by < sub_height
      bin_bridge_row(block, lows, highs, by * sub_width, sub_width, by + 1 < sub_height)
      by += 1
    end
    thresholds = bin_smooth(block, sub_width, sub_height)
    bin_apply(gray, width, height, thresholds, lows, highs)
  end

  # ZXing (Java) HybridBinarizer-like local means: per 8x8 block its mean,
  # or for flat blocks half its minimum unless the neighbours suggest a dark
  # area; averaged over 5x5 blocks. Returns the bit buffer (width, height
  # >= 40).
  # spinel-sample: QrReaderKernels.binarize_local_mean("\x10\xf0\x80\x20".b * 400, 40, 40)
  def self.binarize_local_mean(gray, width, height)
    sub_width = (width + 7) >> 3
    sub_height = (height + 7) >> 3
    size = sub_width * sub_height
    points = Array.new(size, 0)
    by = 0
    while by < sub_height
      y0 = by << 3
      y0 = height - 8 if y0 > height - 8
      bin_black_points_row(gray, width, y0 * width, points, by * sub_width, sub_width)
      by += 1
    end
    hsum = Array.new(size, 0)
    by = 0
    while by < sub_height
      bin_five_sums_row(points, hsum, by * sub_width, sub_width)
      by += 1
    end
    means = Array.new(size, 0)
    by = 0
    while by < sub_height
      centre = by
      centre = 2 if centre < 2
      centre = sub_height - 3 if centre > sub_height - 3
      bin_five_means_row(hsum, means, by * sub_width, centre * sub_width, sub_width)
      by += 1
    end
    # Block statistics that never classify a block as uniform.
    lows = Array.new(size, 0)
    highs = Array.new(size, 256)
    bin_apply(gray, width, height, means, lows, highs)
  end

  # Black points of one row of 8x8 blocks whose top row starts at +off0+
  # (edge blocks shifted inwards to stay inside the image).
  def self.bin_black_points_row(data, width, off0, points, base, sub_width)
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
        next if max - min <= BIN_MIN_RANGE

        # Enough contrast already: only the sum is still needed.
        while rows < 8
          sum += data.getbyte(off) + data.getbyte(off + 1) + data.getbyte(off + 2) + data.getbyte(off + 3) +
                 data.getbyte(off + 4) + data.getbyte(off + 5) + data.getbyte(off + 6) + data.getbyte(off + 7)
          off += width
          rows += 1
        end
      end

      point = sum >> 6
      if max - min <= BIN_MIN_RANGE
        # A flat block is assumed to be background (white it out) unless
        # its neighbours suggest it lies inside a dark area.
        point = min >> 1
        if base > 0 && bx > 0
          up = base - sub_width + bx
          neighbours = (points[up] + 2 * points[base + bx - 1] + points[up - 1]) >> 2
          point = neighbours if min < neighbours
        end
      end
      points[base + bx] = point
      bx += 1
    end
  end

  # Sums over the 5 blocks around each block of one block row (window
  # clamped to the row).
  def self.bin_five_sums_row(values, hsum, base, sub_width)
    last = sub_width - 3
    bx = 0
    while bx < sub_width
      i = base + (bx < 2 ? 2 : (bx > last ? last : bx))
      hsum[base + bx] = values[i - 2] + values[i - 1] + values[i] + values[i + 1] + values[i + 2]
      bx += 1
    end
  end

  # Means over 5 block rows (centred on the row starting at +centre+).
  def self.bin_five_means_row(hsum, means, base, centre, sub_width)
    two_rows = 2 * sub_width
    bx = 0
    while bx < sub_width
      i = centre + bx
      means[base + bx] = (hsum[i - two_rows] + hsum[i - sub_width] + hsum[i] +
                          hsum[i + sub_width] + hsum[i + two_rows]) / 25
      bx += 1
    end
  end

  # (min + max) / 2 of each block of one block row (top pixel row at
  # +off0+), 0 for flat blocks; minima and maxima into +lows+ / +highs+.
  # Min and max of each 8 pixel row segment come from pairwise
  # comparisons (12 instead of 16 per segment).
  def self.bin_midranges_row(data, width, off0, out, lows, highs, base, sub_width)
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
      out[i] = max - min > BIN_MIN_RANGE ? (max + min) >> 1 : 0
      bx += 1
    end
  end

  # Gives flat blocks of the block row starting at +base+ a threshold when
  # an edge runs along their border: a flat right (or lower) neighbour
  # whose luminance range is more than BIN_MIN_RANGE away from theirs. Both
  # get the threshold halfway across the gap (set thresholds are kept). A
  # smooth gradient never qualifies.
  def self.bin_bridge_row(block, lows, highs, base, sub_width, below)
    i = base
    last = base + sub_width - 1
    while i <= last
      lo = lows[i]
      hi = highs[i]
      if hi - lo <= BIN_MIN_RANGE
        bin_bridge_pair(block, lows, highs, i, i + 1, lo, hi) if i < last
        bin_bridge_pair(block, lows, highs, i, i + sub_width, lo, hi) if below
      end
      i += 1
    end
  end

  # bin_bridge_row for flat block i (range lo..hi) and block j.
  def self.bin_bridge_pair(block, lows, highs, i, j, lo, hi)
    lo2 = lows[j]
    hi2 = highs[j]
    return if hi2 - lo2 > BIN_MIN_RANGE

    t = 0
    if lo2 - hi > BIN_MIN_RANGE
      t = (hi + lo2) >> 1
    elsif lo - hi2 > BIN_MIN_RANGE
      t = (hi2 + lo) >> 1
    else
      return
    end
    block[i] = t if block[i] == 0
    block[j] = t if block[j] == 0
  end

  # Mean over the 5x5 blocks around each block of the thresholds that are
  # set (the block itself counts twice), via separable window sums of the
  # thresholds and of an is-set indicator; then gaps filled in scan order.
  def self.bin_smooth(block, sub_width, sub_height)
    size = sub_width * sub_height
    hsum = Array.new(size, 0)
    hcount = Array.new(size, 0)
    by = 0
    while by < sub_height
      bin_window_row(block, hsum, hcount, by * sub_width, sub_width)
      by += 1
    end
    out = Array.new(size, 0)
    by = 0
    while by < sub_height
      top = by
      top = 2 if top < 2
      top = sub_height - 3 if top > sub_height - 3
      bin_window_means(block, hsum, hcount, out, by * sub_width, (top - 2) * sub_width, sub_width)
      by += 1
    end
    bin_fill_gaps(out, sub_width)
    out
  end

  # Sums and counts of the set (positive) thresholds over the 5 blocks
  # around each block of one block row (window clamped to the row).
  def self.bin_window_row(block, hsum, hcount, base, sub_width)
    last = sub_width - 3
    bx = 0
    while bx < sub_width
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
  def self.bin_window_means(block, hsum, hcount, out, base, top, sub_width)
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

  # Sets every 0 entry to the previous non-zero one in scan order (leading
  # zeros to the first non-zero one); all zero (no contrast anywhere)
  # becomes all -1: everything light.
  def self.bin_fill_gaps(values, row_size)
    n = values.size
    first = 0
    first += 1 while first < n && values[first] <= 0
    if first == n
      i = 0
      while i < n
        values[i] = -1
        i += 1
      end
      return
    end
    last = values[first]
    i = 0
    while i < n
      stop = i + row_size
      stop = n if stop > n
      last = bin_fill_span(values, i, stop, last)
      i = stop
    end
  end

  # bin_fill_gaps for values[i...stop]; returns the last non-zero value.
  def self.bin_fill_span(values, i, stop, last)
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

  # Bit buffer of the pixels at or below their block's threshold (columns
  # past the last full block use the last block). Blocks whose whole range
  # (+lows+ / +highs+ over the 8x8 pixels the threshold was derived from,
  # which contain every pixel that uses it) lies on one side of their
  # threshold are filled without looking at the pixels.
  def self.bin_apply(gray, width, height, thresholds, lows, highs)
    sub_width = (width + 7) >> 3
    patterns = bin_patterns
    out = String.new(capacity: width * height, encoding: Encoding::BINARY)
    y = 0
    off = 0
    while y < height
      out << bin_apply_row(gray, off, width, thresholds, lows, highs, (y >> 3) * sub_width, sub_width, patterns)
      off += width
      y += 1
    end
    out
  end

  # The 256 rows of 8 bits: pattern m has byte k set iff bit k of m is.
  def self.bin_patterns
    patterns = []
    m = 0
    while m < 256
      s = String.new(capacity: 8, encoding: Encoding::BINARY)
      k = 0
      while k < 8
        s << ((m >> k) & 1)
        k += 1
      end
      patterns << s
      m += 1
    end
    patterns
  end

  # One row of bin_apply (block row starting at +base+). Each 8 pixel
  # segment becomes one appended pattern (String#setbyte per pixel costs
  # more than the comparisons).
  def self.bin_apply_row(gray, off, width, thresholds, lows, highs, base, sub_width, patterns)
    full = width >> 3
    row = String.new(capacity: width, encoding: Encoding::BINARY)
    light = patterns[0]
    dark = patterns[255]
    b = base
    stop = base + full
    i = off
    while b < stop
      t = thresholds[b]
      if lows[b] > t
        row << light
      elsif highs[b] <= t
        row << dark
      else
        m = 0
        m |= 1 if gray.getbyte(i) <= t
        m |= 2 if gray.getbyte(i + 1) <= t
        m |= 4 if gray.getbyte(i + 2) <= t
        m |= 8 if gray.getbyte(i + 3) <= t
        m |= 16 if gray.getbyte(i + 4) <= t
        m |= 32 if gray.getbyte(i + 5) <= t
        m |= 64 if gray.getbyte(i + 6) <= t
        m |= 128 if gray.getbyte(i + 7) <= t
        row << patterns[m]
      end
      i += 8
      b += 1
    end
    return row if full == sub_width

    t = thresholds[base + sub_width - 1]
    stop = off + width
    while i < stop
      row << (gray.getbyte(i) <= t ? 1 : 0)
      i += 1
    end
    row
  end
end
