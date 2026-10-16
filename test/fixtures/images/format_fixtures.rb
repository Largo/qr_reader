# frozen_string_literal: true

require "json"
require "zlib"

# Test support for the image format decoders: access to the generated
# fixtures (see generate.rb), deliberately naive encoders that produce the
# exact variants a test needs, and a fuzzing assertion. Nothing here shares
# code with the decoders.
module FormatFixtures
  DIR = __dir__
  CORPUS = File.expand_path("../../corpus/zxing", __dir__)

  module_function

  def manifest
    @manifest ||= JSON.parse(File.read(File.join(DIR, "manifest.json")))
  end

  # Fixture names starting with +prefix+ ("png_", "gif_", ...).
  def names(prefix)
    manifest.keys.select { |name| name.start_with?(prefix) }
  end

  def read(name)
    File.binread(File.join(DIR, name))
  end

  # The expected luminance image of a fixture: its reference RGBA through
  # Image.from_pixels.
  def expected(name)
    entry = manifest.fetch(name)
    rgba = Zlib::Inflate.inflate(File.binread(File.join(DIR, entry["reference"])))
    QrReader::Image.from_pixels(entry["width"], entry["height"], rgba, :rgba)
  end

  # RGBA rows (Arrays of [r, g, b, a]) -> expected luminance Image.
  def image_from_rgba(rows)
    QrReader::Image.from_pixels(rows[0].size, rows.size, rows.flatten.pack("C*"), :rgba)
  end

  # Truncated and byte-flipped variants of +bytes+ (deterministic).
  def mutations(bytes, seed:, truncations: 64, flips: 64)
    rng = Random.new(seed)
    size = bytes.bytesize
    cuts = (0...[size, 64].min).to_a + Array.new(truncations) { rng.rand(size) }
    variants = cuts.uniq.map { |n| bytes.byteslice(0, n) }
    flips.times do
      copy = bytes.dup
      (1 + rng.rand(3)).times do
        # Bias towards the headers, where most of the structure lives.
        pos = rng.rand < 0.5 ? rng.rand([size, 128].min) : rng.rand(size)
        copy.setbyte(pos, rng.rand(256))
      end
      variants << copy
    end
    variants
  end

  # Minitest assertions.
  module Assertions
    # Decoding +bytes+ must return an Image or raise QrReader::ImageError,
    # quickly; anything else (NoMethodError, TypeError, ...) fails.
    def assert_image_or_image_error(bytes, max_seconds: 2.0, &decoder)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        result = decoder.call(bytes)
        assert_kind_of QrReader::Image, result
        assert_equal result.width * result.height, result.data.bytesize
      rescue QrReader::ImageError
        # expected for corrupt input
      rescue StandardError => e
        flunk "#{e.class}: #{e.message} for input #{bytes.byteslice(0, 48).unpack1('H*')}... " \
              "(#{bytes.bytesize} bytes)\n#{e.backtrace.first(4).join("\n")}"
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      assert_operator elapsed, :<, QrTestHelper.time_limit(max_seconds), "decoding took #{elapsed.round(2)} s"
    end

    def assert_same_image(expected, actual, message = nil)
      assert_equal [expected.width, expected.height], [actual.width, actual.height], message
      return if expected.data == actual.data

      diff = expected.data.bytes.zip(actual.data.bytes).each_with_index.find { |(a, b), _| a != b }
      (a, b), i = diff
      flunk "#{message}: pixel (#{i % expected.width}, #{i / expected.width}) is #{b}, expected #{a}"
    end
  end

  # Minimal PNG encoder: explicit filter types per row (cycled), optional
  # Adam7, arbitrary IDAT splitting and extra chunks.
  module PngWriter
    CHANNELS = { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4 }.freeze
    ADAM7 = [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]].freeze

    module_function

    def chunk(type, data)
      [data.bytesize].pack("N") + type.b + data.b + [Zlib.crc32(type + data)].pack("N")
    end

    # +pixels+: rows of pixels, each pixel an Array of samples at +depth+.
    def encode(pixels, color_type:, depth:, interlace: false, palette: nil, trns: nil, filters: [0, 1, 2, 3, 4],
               idat_sizes: nil, extra_chunks: [], iend: true)
      height = pixels.size
      width = pixels[0].size
      raw = String.new(encoding: Encoding::BINARY)
      if interlace
        ADAM7.each do |x0, y0, dx, dy|
          sub = (y0...height).step(dy).map { |y| (x0...width).step(dx).map { |x| pixels[y][x] } }
          next if sub.empty? || sub[0].empty?

          raw << filter_rows(sub, color_type, depth, filters)
        end
      else
        raw << filter_rows(pixels, color_type, depth, filters)
      end
      png = "\x89PNG\r\n\x1A\n".b
      png << chunk("IHDR", [width, height, depth, color_type, 0, 0, interlace ? 1 : 0].pack("NNCCCCC"))
      png << chunk("PLTE", palette.flatten.pack("C*")) if palette
      png << chunk("tRNS", trns) if trns
      extra_chunks.each { |type, data| png << chunk(type, data) }
      idat(Zlib::Deflate.deflate(raw), idat_sizes).each { |part| png << chunk("IDAT", part) }
      png << chunk("IEND", "") if iend
      png
    end

    def idat(data, sizes)
      return [data] unless sizes

      parts = []
      pos = 0
      sizes.cycle do |n|
        break if pos >= data.bytesize

        parts << data.byteslice(pos, n)
        pos += n
      end
      parts
    end

    def filter_rows(rows, color_type, depth, filters)
      bpp = [(CHANNELS[color_type] * depth + 7) / 8, 1].max
      prev = nil
      out = String.new(encoding: Encoding::BINARY)
      rows.each_with_index do |row, y|
        line = pack_row(row, depth).bytes
        prev ||= Array.new(line.size, 0)
        type = filters[y % filters.size]
        out << type
        line.each_with_index do |x, i|
          a = i >= bpp ? line[i - bpp] : 0
          b = prev[i]
          c = i >= bpp ? prev[i - bpp] : 0
          predicted = [0, a, b, (a + b) / 2, paeth(a, b, c)][type]
          out << ((x - predicted) & 0xff)
        end
        prev = line
      end
      out
    end

    # The PNG specification's reference formulation.
    def paeth(a, b, c)
      p = a + b - c
      pa = (p - a).abs
      pb = (p - b).abs
      pc = (p - c).abs
      if pa <= pb && pa <= pc then a
      elsif pb <= pc then b
      else c
      end
    end

    def pack_row(row, depth)
      samples = row.flatten
      case depth
      when 8 then samples.pack("C*")
      when 16 then samples.pack("n*")
      else [samples.map { |s| s.to_s(2).rjust(depth, "0") }.join].pack("B*")
      end
    end

    # Expected RGBA rows for +pixels+ (independent of the decoder):
    # samples scaled to 8 bits (16-bit: high byte), tRNS and alpha applied.
    def expected_rgba(pixels, color_type:, depth:, palette: nil, trns: nil)
      scale = ->(v) { depth == 16 ? v >> 8 : v * 255 / ((1 << depth) - 1) }
      key = trns && color_type != 3 ? trns.unpack("n*") : nil
      pixels.map do |row|
        row.map do |px|
          case color_type
          when 0 then [scale.(px[0])] * 3 + [key == px ? 0 : 255]
          when 2 then px.map(&scale) + [key == px ? 0 : 255]
          when 3
            alpha = trns&.getbyte(px[0]) || 255
            (palette[px[0]] || [0, 0, 0]) + [alpha]
          when 4 then [scale.(px[0])] * 3 + [scale.(px[1])]
          when 6 then px.map(&scale)
          end
        end
      end
    end
  end

  # Minimal GIF encoder with a textbook LZW compressor.
  module GifWriter
    module_function

    # +indices+: rows of palette indices. +gces+ lists graphic control
    # extensions written before the image (transparent index or nil each);
    # +transparent+ is a shortcut for one. +before+/+after+ are raw blocks.
    def encode(indices, palette: nil, local_palette: nil, screen: nil, offset: [0, 0], transparent: nil,
               gces: nil, interlace: false, min_code_size: nil, clear_when_full: true, end_code: true,
               before: [], after: [], trailer: true)
      height = indices.size
      width = indices[0]&.size || 0
      screen ||= [width, height]
      gif = "GIF89a".b + [screen[0], screen[1]].pack("vv")
      gif << ((palette ? 0x80 | table_bits(palette) : 0) | 0x70) << 0 << 0
      gif << table(palette) if palette
      before.each { |block| gif << block }
      (gces || (transparent ? [transparent] : [])).each { |t| gif << gce(t) }
      gif << 0x2C << [offset[0], offset[1], width, height].pack("vvvv")
      flags = (local_palette ? 0x80 | table_bits(local_palette) : 0) | (interlace ? 0x40 : 0)
      gif << flags
      gif << table(local_palette) if local_palette
      rows = indices
      if interlace
        passes = [[0, 8], [4, 8], [2, 4], [1, 2]]
        rows = passes.flat_map { |first, step| (first...height).step(step).map { |y| indices[y] } }
      end
      colors = (local_palette || palette || [[0, 0, 0]] * 2).size
      min = min_code_size || [(colors - 1).bit_length, 2].max
      gif << min << sub_blocks(lzw(rows.flatten, min, clear_when_full, end_code))
      after.each { |block| gif << block }
      gif << 0x3B if trailer
      gif
    end

    def table_bits(palette)
      [(palette.size - 1).bit_length, 1].max - 1
    end

    def table(palette)
      size = 2 << table_bits(palette)
      (palette + [[0, 0, 0]] * (size - palette.size)).flatten.pack("C*")
    end

    # Graphic control extension; a nil index means no transparency.
    def gce(transparent)
      [0x21, 0xF9, 4, transparent ? 1 : 0, 0, transparent || 0, 0].pack("CCCCvCC")
    end

    def sub_blocks(data)
      out = String.new(encoding: Encoding::BINARY)
      data.bytes.each_slice(255) { |s| out << s.size << s.pack("C*") }
      out << 0
    end

    def comment(text)
      "\x21\xFE".b + sub_blocks(text.b)
    end

    # Codes are packed LSB first; the code size grows once a code that
    # needs the extra bit can occur (the decoder is one entry behind).
    def lzw(indices, min_size, clear_when_full, end_code)
      clear = 1 << min_size
      codes = []
      size = nil
      dict = nil
      next_code = nil
      reset = lambda do
        dict = (0...clear).to_h { |i| [[i], i] }
        size = min_size + 1
        next_code = clear + 2
      end
      reset.call
      codes << [clear, size]
      current = []
      indices.each do |index|
        candidate = current + [index]
        if dict.key?(candidate)
          current = candidate
          next
        end
        codes << [dict[current], size]
        if next_code < 4096
          dict[candidate] = next_code
          next_code += 1
          size += 1 if next_code > (1 << size) && size < 12
        elsif clear_when_full
          codes << [clear, size]
          reset.call
        end
        current = [index]
      end
      codes << [dict[current], size] unless current.empty?
      codes << [clear + 1, size] if end_code
      pack_codes(codes)
    end

    def pack_codes(codes)
      buf = 0
      bits = 0
      out = String.new(encoding: Encoding::BINARY)
      codes.each do |code, size|
        buf |= code << bits
        bits += size
        while bits >= 8
          out << (buf & 0xff)
          buf >>= 8
          bits -= 8
        end
      end
      out << buf if bits.positive?
      out
    end
  end

  # Minimal BMP writer: any header type, palette, masks, raw or RLE data.
  module BmpWriter
    HEADER_SIZES = { core: 12, os2_16: 16, info: 40, v2: 52, v3: 56, os2_64: 64, v4: 108, v5: 124 }.freeze

    module_function

    # +rows+: packed pixel bytes per row, top row first (padding is added).
    # +data+ replaces the pixel array (RLE). +masks+ are written after an
    # info header (BI_BITFIELDS) or into V2+ headers.
    def encode(width:, height:, bpp:, rows: nil, data: nil, palette: nil, header: :info, compression: 0,
               masks: nil, top_down: false, colors_used: 0, data_offset: nil)
      size = HEADER_SIZES.fetch(header)
      if header == :core
        dib = [size, width, height, 1, bpp].pack("Vvvvv")
      else
        dib = [size, width, top_down ? -height : height, 1, bpp, compression, 0, 2835, 2835, colors_used, 0]
              .pack("Vl<l<vvVVl<l<VV").byteslice(0, size)
        dib << ("\0".b * (size - dib.bytesize))
        dib[40, masks.size * 4] = masks.pack("V*") if masks && size >= 52
      end
      extra = masks && size == 40 ? masks.pack("V*") : "".b
      entry = header == :core ? 3 : 4
      pal = (palette || []).map { |r, g, b| entry == 3 ? [b, g, r].pack("C3") : [b, g, r, 0].pack("C4") }.join.b
      pixels = data || pixel_array(rows, width, bpp, top_down)
      offset = data_offset || 14 + dib.bytesize + extra.bytesize + pal.bytesize
      file = "BM".b + [0, 0, offset].pack("VVV") + dib + extra + pal
      file << ("\0".b * (offset - file.bytesize)) if offset > file.bytesize
      file << pixels
      file[2, 4] = [file.bytesize].pack("V")
      file
    end

    def pixel_array(rows, width, bpp, top_down)
      stride = ((width * bpp + 31) / 32) * 4
      padded = rows.map { |r| r.b + ("\0".b * (stride - r.bytesize)) }
      (top_down ? padded : padded.reverse).join
    end
  end
end
