# frozen_string_literal: true

# Pixel conversion kernels: interleaved 8-bit samples to luminance, with
# alpha composited over white. Plain Ruby in the subset Spinel compiles (see
# DESIGN.md, "Kernels"); the per-row helpers are shared by the image
# decoders' kernels (kernels/png.rb).
#
# Luminance is Rec. 601 with 10-bit fixed point weights (Image.luma):
#   (306 * r + 601 * g + 117 * b + 0x200) >> 10
# and a sample v with alpha a over white is
#   (v * a + 255 * (255 - a) + 127) / 255 == ((v - 255) * a + 65_152) / 255
# (the numerator is never negative, so floor and C division agree).
module QrReaderKernels
  # Luminance of +height+ rows of +width+ pixels of +stride+ bytes each.
  # Row y starts at byte +offset+ + y * +pitch+ of +data+ (a negative pitch
  # walks bottom-up rows; padding between rows is skipped). Channel byte
  # offsets within a pixel: red +ro+, green +go+, blue +bo+, alpha +ao+;
  # +go+ < 0 means a single gray sample at +ro+, +ao+ < 0 means opaque.
  # Returns width * height luminance bytes.
  # spinel-sample: QrReaderKernels.pixels_luma("\x01\x02\x03\x04".b, 0, 4, 1, 1, 4, 0, 1, 2, 3)
  def self.pixels_luma(data, offset, pitch, width, height, stride, ro, go, bo, ao)
    out = String.new(capacity: width * height, encoding: Encoding::BINARY)
    off = offset
    y = 0
    while y < height
      out << px_row(data, off, width, stride, ro, go, bo, ao)
      off += pitch
      y += 1
    end
    out
  end

  # One row of pixels_luma (dispatch only: the loops live in helpers that
  # YJIT compiles separately).
  def self.px_row(src, off, n, stride, ro, go, bo, ao)
    if go < 0
      if ao < 0
        stride == 1 ? src.byteslice(off, n) || "" : px_gray_row(src, off, n, ro, stride)
      else
        px_gray_alpha_row(src, off, n, ro, ao, stride)
      end
    elsif ao < 0
      px_rgb_row(src, off, n, ro, go, bo, stride)
    else
      px_rgba_row(src, off, n, ro, go, bo, ao, stride)
    end
  end

  # Every +stride+-th byte starting at +off+ + +vo+ (e.g. the high bytes of
  # 16-bit samples).
  def self.px_gray_row(src, off, n, vo, stride)
    row = String.new(capacity: n, encoding: Encoding::BINARY)
    i = off + vo
    stop = i + n * stride
    while i < stop
      row << src.getbyte(i)
      i += stride
    end
    row
  end

  def self.px_gray_alpha_row(src, off, n, vo, ao, stride)
    row = String.new(capacity: n, encoding: Encoding::BINARY)
    i = off
    stop = off + n * stride
    while i < stop
      a = src.getbyte(i + ao)
      v = src.getbyte(i + vo)
      row << (a == 255 ? v : ((v - 255) * a + 65_152) / 255)
      i += stride
    end
    row
  end

  def self.px_rgb_row(src, off, n, ro, go, bo, stride)
    row = String.new(capacity: n, encoding: Encoding::BINARY)
    i = off
    stop = off + n * stride
    while i < stop
      row << ((306 * src.getbyte(i + ro) + 601 * src.getbyte(i + go) + 117 * src.getbyte(i + bo) + 0x200) >> 10)
      i += stride
    end
    row
  end

  def self.px_rgba_row(src, off, n, ro, go, bo, ao, stride)
    row = String.new(capacity: n, encoding: Encoding::BINARY)
    i = off
    stop = off + n * stride
    while i < stop
      v = (306 * src.getbyte(i + ro) + 601 * src.getbyte(i + go) + 117 * src.getbyte(i + bo) + 0x200) >> 10
      a = src.getbyte(i + ao)
      row << (a == 255 ? v : ((v - 255) * a + 65_152) / 255)
      i += stride
    end
    row
  end
end
