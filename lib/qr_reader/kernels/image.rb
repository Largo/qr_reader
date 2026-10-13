# frozen_string_literal: true

# Image kernels. Kernel files are plain Ruby in the subset that Spinel
# compiles (see DESIGN.md, "Kernels"): the optional qr_reader-native gem
# builds them into a C extension, otherwise they run as they are.
module QrReaderKernels
  # Box-filter downscale of a width x height grayscale buffer by an integer
  # factor (partial edge blocks are dropped). Returns the reduced buffer.
  # spinel-sample: QrReaderKernels.downscale("\x00\x01\x02\x03".b, 2, 2, 2)
  def self.downscale(gray, width, height, factor)
    w = width / factor
    h = height / factor
    out = String.new(capacity: w * h, encoding: Encoding::BINARY)
    step = factor * width
    off = 0
    y = 0
    while y < h
      out << (factor == 2 ? downscale2_row(gray, off, width, w) : downscale_row(gray, off, width, w, factor))
      off += step
      y += 1
    end
    out
  end

  # One 2x-reduced row whose top source row starts at +off+.
  def self.downscale2_row(gray, off, width, w)
    row = String.new(capacity: w, encoding: Encoding::BINARY)
    a = off
    b = off + width
    e = off + 2 * w
    while a < e
      row << ((gray.getbyte(a) + gray.getbyte(a + 1) + gray.getbyte(b) + gray.getbyte(b + 1) + 2) >> 2)
      a += 2
      b += 2
    end
    row
  end

  # One row reduced by +factor+ whose top source row starts at +off+.
  def self.downscale_row(gray, off, width, w, factor)
    row = String.new(capacity: w, encoding: Encoding::BINARY)
    area = factor * factor
    half = area / 2
    x = 0
    start = off
    while x < w
      s = 0
      r = start
      r_end = start + factor * width
      while r < r_end
        i = r
        e = r + factor
        while i < e
          s += gray.getbyte(i)
          i += 1
        end
        r += width
      end
      row << (s + half) / area
      start += factor
      x += 1
    end
    row
  end
end
