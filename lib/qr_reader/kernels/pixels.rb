# frozen_string_literal: true

require_relative "../errors"

# Pixel conversion kernels: interleaved 8-bit samples to luminance, with
# alpha composited over white. Plain Ruby in the subset Spinel compiles (see
# DESIGN.md, "Kernels"); the per-row helpers are shared by the image
# decoders' kernels (kernels/png.rb).
#
# Luminance is Rec. 601 with 10-bit fixed point weights (Image.luma):
#   (306 * r + 601 * g + 117 * b + 0x200) >> 10
# and a sample v with alpha a over white is
#   (v * a + 255 * (255 - a) + 127) / 255 == ((v - 255) * a + 65_152) / 255
# computed as (((v - 255) * a + 65_152) * 0x8081) >> 23: x / 255 equals
# (x * 0x8081) >> 23 for every 0 <= x < 65_536, and the numerator is
# 127..65_152 (a multiplication instead of a division call under YJIT).
#
# The row helpers reference no constants and allocate through px_buf (see
# kernels/png.rb for why that matters to YJIT).
module QrReaderKernels
  # Luminance of +height+ rows of +width+ pixels of +stride+ bytes each.
  # Row y starts at byte +offset+ + y * +pitch+ of +data+ (a negative pitch
  # walks bottom-up rows; padding between rows is skipped). Channel byte
  # offsets within a pixel: red +ro+, green +go+, blue +bo+, alpha +ao+;
  # +go+ < 0 means a single gray sample at +ro+, +ao+ < 0 means opaque.
  # Returns width * height luminance bytes.
  # spinel-sample: QrReaderKernels.pixels_luma("\x01\x02\x03\x04".b, 0, 4, 1, 1, 4, 0, 1, 2, 3)
  def self.pixels_luma(data, offset, pitch, width, height, stride, ro, go, bo, ao)
    last = offset + (height - 1) * pitch
    first = last < offset ? last : offset
    if width < 1 || height < 1 || stride < 1 || first < 0 || (last > offset ? last : offset) + width * stride > data.bytesize
      raise QrReader::ImageError, "pixel data too short"
    end

    out = px_buf(width * height)
    off = offset
    y = 0
    while y < height
      out << px_row(data, off, width, stride, ro, go, bo, ao)
      off += pitch
      y += 1
    end
    out
  end

  # An empty binary String with room for +size+ bytes.
  def self.px_buf(size)
    String.new(capacity: size)
  end

  # One row of pixels_luma (dispatch only: the loops live in helpers that
  # YJIT compiles separately).
  def self.px_row(src, off, n, stride, ro, go, bo, ao)
    if go < 0
      if ao < 0
        stride == 1 ? (src.byteslice(off + ro, n) || "") : px_gray_row(src, off, n, ro, stride)
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
    row = px_buf(n)
    i = off + vo
    stop = i + n * stride
    while i < stop
      row << src.getbyte(i)
      i += stride
    end
    row
  end

  def self.px_gray_alpha_row(src, off, n, vo, ao, stride)
    row = px_buf(n)
    i = off
    stop = off + n * stride
    while i < stop
      a = src.getbyte(i + ao)
      v = src.getbyte(i + vo)
      row << (a == 255 ? v : (((v - 255) * a + 65_152) * 0x8081) >> 23)
      i += stride
    end
    row
  end

  def self.px_rgb_row(src, off, n, ro, go, bo, stride)
    row = px_buf(n)
    i = off
    stop = off + n * stride
    while i < stop
      row << ((306 * src.getbyte(i + ro) + 601 * src.getbyte(i + go) + 117 * src.getbyte(i + bo) + 0x200) >> 10)
      i += stride
    end
    row
  end

  def self.px_rgba_row(src, off, n, ro, go, bo, ao, stride)
    row = px_buf(n)
    i = off
    stop = off + n * stride
    while i < stop
      v = (306 * src.getbyte(i + ro) + 601 * src.getbyte(i + go) + 117 * src.getbyte(i + bo) + 0x200) >> 10
      a = src.getbyte(i + ao)
      row << (a == 255 ? v : (((v - 255) * a + 65_152) * 0x8081) >> 23)
      i += stride
    end
    row
  end
end
