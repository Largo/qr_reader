# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/images/format_fixtures"

# Adversarial tests for the image format decoders: pathological inputs that
# used to be slow or memory hungry, leniency that real decoders (libnetpbm,
# ImageMagick, Pillow, browsers) show and we must match, and exhaustive
# checks against independent references (a spec-literal RLE expander in this
# file, Image.from_pixels for alpha, and the naive writers of FormatFixtures).
class TestFormatsAdversarial < Minitest::Test
  include FormatFixtures::Assertions

  F = QrReader::Formats
  PNG = FormatFixtures::PngWriter
  GIF = FormatFixtures::GifWriter
  BMP = FormatFixtures::BmpWriter

  def luma(r, g, b)
    QrReader::Image.luma(r, g, b)
  end

  def elapsed
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end

  def random_palette(n, seed)
    rng = Random.new(seed)
    Array.new(n) { [rng.rand(256), rng.rand(256), rng.rand(256)] }
  end

  # --- BMP RLE ---------------------------------------------------------------

  # The RLE8/RLE4 specification read literally: a white canvas, runs and
  # absolute groups clipped at the right edge (no wrapping), deltas, end of
  # line, end of bitmap. Rows are in file order (bottom-up unless top_down).
  def reference_rle(data, width, height, lumas, rle4:, top_down: false)
    rows = Array.new(height) { Array.new(width, 255) }
    x = y = i = 0
    nibble = ->(byte, k) { k.even? ? byte >> 4 : byte & 15 }
    draw = lambda do |index|
      rows[y][x] = lumas[index] || 0 if x < width
      x += 1
    end
    while y < height
      count = data.getbyte(i)
      value = data.getbyte(i + 1)
      i += 2
      if count.positive?
        count.times { |k| draw.(rle4 ? nibble.(value, k) : value) }
      elsif value.zero?
        x = 0
        y += 1
      elsif value == 1
        break
      elsif value == 2
        x += data.getbyte(i)
        y += data.getbyte(i + 1)
        i += 2
      else
        value.times { |k| draw.(rle4 ? nibble.(data.getbyte(i + k / 2), k) : data.getbyte(i + k)) }
        size = rle4 ? (value + 1) / 2 : value
        i += size + size % 2
      end
    end
    (top_down ? rows : rows.reverse).flatten
  end

  # A random but valid RLE stream: runs, absolute groups, deltas and early
  # ends of line, often crossing the right edge; ends with end of bitmap.
  def random_rle(rng, width, height, rle4:)
    data = String.new(encoding: Encoding::BINARY)
    max_index = rle4 ? 15 : 255
    height.times do
      x = 0
      while x < width + 10 && rng.rand > 0.08
        case rng.rand(10)
        when 0..4
          count = rng.rand < 0.7 ? rng.rand(1..9) : rng.rand(10..60)
          data << count << (rle4 ? rng.rand(256) : rng.rand(max_index + 1))
          x += count
        when 5..7
          count = rng.rand(3..(rng.rand < 0.8 ? 12 : 80))
          data << 0 << count
          bytes = rle4 ? Array.new((count + 1) / 2) { rng.rand(256) } : Array.new(count) { rng.rand(256) }
          bytes << 0 if bytes.size.odd?
          data << bytes.pack("C*")
          x += count
        else
          data << 0 << 2 << rng.rand(0..4) << (rng.rand < 0.15 ? 1 : 0)
        end
      end
      data << 0 << 0
    end
    data << 0 << 1
  end

  def test_rle_matches_a_spec_literal_expander_on_random_streams
    rng = Random.new(2024)
    60.times do |n|
      rle4 = n.odd?
      width = rng.rand(1..48)
      height = rng.rand(1..12)
      top_down = (n % 4) >= 2
      palette = random_palette(n % 5 == 0 ? 7 : (rle4 ? 16 : 256), n) # some palettes are short
      lumas = palette.map { |rgb| luma(*rgb) }
      data = random_rle(rng, width, height, rle4: rle4)
      bmp = BMP.encode(width: width, height: height, bpp: rle4 ? 4 : 8, data: data, palette: palette,
                       compression: rle4 ? 2 : 1, top_down: top_down)
      expected = reference_rle(data, width, height, lumas, rle4: rle4, top_down: top_down)
      assert_equal expected, F.decode(bmp).data.bytes, "case #{n}: #{width}x#{height} rle4=#{rle4}"
    end
  end

  # Absolute groups used to be mapped with a fresh 256-entry String#tr table
  # each: ~15 us per 3-pixel group, i.e. seconds for a small image.
  def test_rle_absolute_groups_decode_in_linear_time
    width = 600
    height = 400
    rng = Random.new(5)
    palette = random_palette(256, 1)
    lumas = palette.map { |rgb| luma(*rgb) }
    [false, true].each do |rle4|
      data = String.new(encoding: Encoding::BINARY)
      height.times do
        (width / 3).times do
          data << (rle4 ? [0, 3, rng.rand(256), rng.rand(256)] : [0, 3, rng.rand(256), rng.rand(256), rng.rand(256), 0])
                  .pack("C*")
        end
        data << "\0\0".b
      end
      data << "\0\1".b
      bmp = BMP.encode(width: width, height: height, bpp: rle4 ? 4 : 8, data: data,
                       palette: rle4 ? palette.first(16) : palette, compression: rle4 ? 2 : 1)
      image = nil
      time = elapsed { image = F.decode(bmp) }
      assert_operator time, :<, 1.0, "RLE#{rle4 ? 4 : 8} absolute groups took #{time.round(2)} s"
      assert_equal reference_rle(data, width, height, lumas, rle4: rle4), image.data.bytes
    end
  end

  def test_rle_streams_of_short_runs_and_no_op_deltas_stay_fast
    palette = random_palette(256, 3)
    runs = ([1, 7].pack("C*") * 800 + "\0\0".b) * 500 + "\0\1".b # 400k one-pixel runs, mostly clipped
    deltas = [0, 2, 0, 0].pack("C*") * 300_000 + "\0\1".b # deltas that do not move
    [runs, deltas].each do |data|
      bmp = BMP.encode(width: 300, height: 500, bpp: 8, data: data, palette: palette, compression: 1)
      time = elapsed { F.decode(bmp) }
      assert_operator time, :<, 2.0, "#{data.bytesize} bytes of RLE opcodes took #{time.round(2)} s"
    end
  end

  # --- GIF ---------------------------------------------------------------------

  # ImageMagick, Pillow and browsers skip stray bytes between blocks (some
  # encoders write extra block terminators); the GIF87a spec says to scan
  # for the next image separator.
  def test_gif_stray_bytes_between_blocks_are_skipped
    palette = [[0, 0, 0], [255, 255, 255], [255, 0, 0], [0, 0, 255]]
    indices = [[0, 1, 2, 3], [3, 2, 1, 0]]
    expected = F.decode(GIF.encode(indices, palette: palette))
    ["\0".b, "\0\0\0".b, "\x01\x02\x03".b, "#{GIF.comment('hi')}\0\0".b, "\x80\xFF".b].each do |junk|
      gif = GIF.encode(indices, palette: palette, before: [junk])
      assert_same_image expected, F.decode(gif), junk.inspect
      assert_equal [4, 2], F.dimensions(gif)
    end
    # Junk only: still no image.
    assert_raises(QrReader::ImageError) { F.decode("GIF89a\x01\x00\x01\x00\x00\x00\x00\x01\x02\x03;".b) }
    assert_raises(QrReader::ImageError) { F.decode("GIF89a\x01\x00\x01\x00\x00\x00\x00#{"\x07" * 100_000}".b) }
  end

  def test_huge_frame_ended_at_once_is_a_white_canvas
    # A 16384x8192 frame whose data is just a clear code and an end code
    # (0x2C: codes 4 and 5 at 3 bits). Decoding must not reserve buffers of
    # the claimed frame size beyond the canvas itself.
    gif = "GIF89a".b + [16_384, 8192, 0x80, 0, 0].pack("vvCCC") + "\0\0\0\xFF\xFF\xFF".b +
          "\x2C".b + [0, 0, 16_384, 8192, 0].pack("vvvvC") + "\x02\x01\x2C\x00\x3B".b
    growth = peak_memory_growth_kib { F.decode(gif) }
    assert_operator growth, :<, 200 * 1024, "a 128 MiB canvas took #{growth / 1024} MiB" if growth
    image = F.decode(gif)
    assert_equal [16_384, 8192], [image.width, image.height]
    assert_equal image.data.bytesize, image.data.count("\xFF".b)
  end

  # --- PNM ---------------------------------------------------------------------

  # libnetpbm and ImageMagick: a comment may follow the last header value
  # directly, and the end of its line is then the single separator byte.
  # (Expected bytes are ImageMagick's decoding of the same files.)
  def test_pnm_comment_directly_after_the_last_header_value
    {
      "P5 2 1 255#comment\nAB" => [65, 66],
      "P5 2 1 255#c\rAB" => [65, 66],
      "P5 2 1 255#c\r\nAB" => [10, 65], # the CR is the separator
      "P5 2 1#x\n255#c\nAB" => [65, 66],
      "P5 2 1 255 #c\nAB" => [35, 99], # whitespace first: the comment is raster data
      "P4 8 1#c\n\x81" => [0, 255, 255, 255, 255, 255, 255, 0],
      "P6 1 1 255#c\n\x10\x20\x30" => [luma(16, 32, 48)],
      "P5 1 1 65535#c\n\x12\x34" => [0x12]
    }.each do |pnm, expected|
      assert_equal expected, F.decode(pnm.b).data.bytes, pnm.inspect
    end
    assert_raises(QrReader::ImageError) { F.decode("P5 2 1 255#no end of line".b) }
  end

  def test_plain_maxval_65535_keeps_the_high_byte_like_raw_rasters
    values = [0x00C0, 0x0180, 0x7FFF, 0x80FF, 0xFE80, 0xFFFF, 0x1234, 0x0101]
    raw = F.decode("P5 8 1 65535\n".b + values.pack("n*"))
    plain = F.decode("P2 8 1 65535\n#{values.join(' ')}\n".b)
    png = F.decode(PNG.encode([values.map { |v| [v] }], color_type: 0, depth: 16))
    assert_equal values.map { |v| v >> 8 }, raw.data.bytes
    assert_equal raw.data, plain.data
    assert_equal raw.data, png.data
    rgb = values.first(6)
    assert_equal F.decode("P6 2 1 65535\n".b + rgb.pack("n*")).data, F.decode("P3 2 1 65535 #{rgb.join(' ')}".b).data
  end

  def test_plain_samples_with_any_whitespace_or_stray_characters
    expected = [1, 2, 3, 4]
    ["1\t2\v3\f4\r\n", "1 2 # c 9\n3 4", "1,2;3x4 junk", "1\x002\x003\x004", "  1\n\n2 3 4 5 6"].each do |raster|
      assert_equal expected, F.decode("P2 4 1 255\n#{raster}".b).data.bytes, raster.inspect
    end
    assert_raises(QrReader::ImageError) { F.decode("P2 4 1 255\n1 2 3".b) }
    assert_raises(QrReader::ImageError) { F.decode("P2 4 1 255\n1 2 3 # 4".b) }
  end

  def test_sixteen_bit_pam_with_alpha_reads_high_bytes_in_place
    rng = Random.new(8)
    { "GRAYSCALE_ALPHA" => [2, :gray_alpha], "RGB_ALPHA" => [4, :rgba], "RGB" => [3, :rgb] }.each do |type, (depth, fmt)|
      samples = Array.new(5 * 3 * depth) { rng.rand(65_536) }
      samples[depth - 1] = 0 if depth.even? # one fully transparent pixel
      pam = "P7\nWIDTH 5\nHEIGHT 3\nDEPTH #{depth}\nMAXVAL 65535\nTUPLTYPE #{type}\nENDHDR\n".b + samples.pack("n*")
      expected = QrReader::Image.from_pixels(5, 3, samples.map { |v| v >> 8 }.pack("C*"), fmt)
      assert_same_image expected, F.decode(pam), type
    end
  end

  def test_sixteen_bit_maxvals_below_65535_are_scaled_with_rounding
    rng = Random.new(9)
    [256, 1000, 4095, 65_534].each do |max|
      samples = Array.new(4 * 2 * 3) { rng.rand(max + 1) }
      samples[0] = max + 7 if max < 65_000 # above maxval: saturates
      scaled = samples.map { |v| v >= max ? 255 : (v * 255 + max / 2) / max }
      expected = QrReader::Image.from_pixels(4, 2, scaled.pack("C*"), :rgb)
      assert_same_image expected, F.decode("P6 4 2 #{max}\n".b + samples.pack("n*")), "maxval #{max}"
    end
  end

  # --- alpha over white: every (value, alpha) pair --------------------------

  def test_alpha_compositing_matches_image_from_pixels_for_every_value_pair
    gray_alpha = (0..255).flat_map { |a| (0..255).flat_map { |v| [v, a] } }.pack("C*")
    expected = QrReader::Image.from_pixels(256, 256, gray_alpha, :gray_alpha)

    pixels = gray_alpha.bytes.each_slice(2).each_slice(256).to_a
    assert_same_image expected, F.decode(PNG.encode(pixels, color_type: 4, depth: 8, filters: [0])), "PNG"
    pam = "P7\nWIDTH 256\nHEIGHT 256\nDEPTH 2\nMAXVAL 255\nTUPLTYPE GRAYSCALE_ALPHA\nENDHDR\n".b + gray_alpha
    assert_same_image expected, F.decode(pam), "PAM"
  end

  def test_rgba_compositing_matches_image_from_pixels
    rgba = (0..255).flat_map { |a| (0..63).flat_map { |x| [x * 4, (x * 7 + a) & 255, 255 - x * 3, a] } }.pack("C*")
    expected = QrReader::Image.from_pixels(64, 256, rgba, :rgba)
    pixels = rgba.bytes.each_slice(4).each_slice(64).to_a
    assert_same_image expected, F.decode(PNG.encode(pixels, color_type: 6, depth: 8)), "PNG RGBA"
    wide = pixels.map { |row| row.map { |px| px.map { |v| v * 257 } } }
    assert_same_image expected, F.decode(PNG.encode(wide, color_type: 6, depth: 16)), "PNG RGBA 16"

    # BMP stores BGRA bottom-up; 32 bpp BI_RGB uses the fourth byte as alpha.
    bgra_rows = pixels.map { |row| row.map { |r, g, b, a| [b, g, r, a] }.flatten.pack("C*") }
    bmp = BMP.encode(width: 64, height: 256, bpp: 32, rows: bgra_rows)
    assert_same_image expected, F.decode(bmp), "BMP BI_RGB"
    # Unusual masks (alpha in the low byte) take the generic masked path.
    argb_rows = pixels.map { |row| row.map { |r, g, b, a| [a, r, g, b] }.flatten.pack("C*") }
    bmp = BMP.encode(width: 64, height: 256, bpp: 32, rows: argb_rows, compression: 3, header: :v5,
                     masks: [0xFF00, 0xFF0000, 0xFF000000, 0xFF])
    assert_same_image expected, F.decode(bmp), "BMP masks"
  end

  # --- PNG -------------------------------------------------------------------

  def test_two_byte_pixels_with_every_filter
    rng = Random.new(11)
    [[4, 8], [0, 16]].each do |color_type, depth|
      max = (1 << depth) - 1
      channels = color_type == 4 ? 2 : 1
      [1, 2, 3, 37, 300].each do |width|
        pixels = Array.new(5) { Array.new(width) { Array.new(channels) { rng.rand(max + 1) } } }
        expected = FormatFixtures.image_from_rgba(PNG.expected_rgba(pixels, color_type: color_type, depth: depth))
        [[0], [1], [2], [3], [4], [4, 3, 1, 2, 0]].each do |filters|
          [false, true].each do |interlace|
            png = PNG.encode(pixels, color_type: color_type, depth: depth, filters: filters, interlace: interlace)
            assert_same_image expected, F.decode(png), "ct #{color_type} depth #{depth} width #{width} #{filters}"
          end
        end
      end
    end
  end

  # Peak resident memory growth (KiB) while running the block in a child
  # process, or nil where that cannot be measured (Linux only: the peak is
  # reset through /proc/self/clear_refs, since a forked child inherits the
  # parent's high-water mark).
  def peak_memory_growth_kib
    return nil unless Process.respond_to?(:fork) && File.writable?("/proc/self/clear_refs")

    reader, writer = IO.pipe
    pid = fork do
      reader.close
      hwm = -> { File.read("/proc/self/status")[/VmHWM:\s+(\d+)/, 1].to_i }
      File.write("/proc/self/clear_refs", "5")
      before = hwm.call
      begin
        yield
      rescue QrReader::ImageError
        nil
      end
      writer.write((hwm.call - before).to_s)
      writer.close
    ensure
      exit!(0) # never run the test suite's at_exit hooks in the child
    end
    writer.close
    Process.wait(pid)
    result = reader.read
    flunk "the measuring child process failed" if result.empty?
    result.to_i
  end

  def test_tiny_png_claiming_a_huge_image_does_not_reserve_its_size
    ihdr = [11_585, 11_585, 16, 6, 0, 0, 0].pack("NNCCCCC") # 2^27 RGBA16 pixels: 1 GiB of raw data
    png = "\x89PNG\r\n\x1A\n".b + PNG.chunk("IHDR", ihdr) +
          PNG.chunk("IDAT", Zlib::Deflate.deflate("\0".b * 100)) + PNG.chunk("IEND", "")
    # Measured first: a decode in this process could leave freed memory behind.
    growth = peak_memory_growth_kib { F.decode(png) }
    error = assert_raises(QrReader::ImageError) { F.decode(png) }
    assert_match(/truncated/, error.message)
    skip "peak memory not measurable here" unless growth
    assert_operator growth, :<, 64 * 1024, "decoding a #{png.bytesize}-byte PNG grew memory by #{growth / 1024} MiB"
  end

  def test_many_tiny_chunks_stay_linear
    z = Zlib::Deflate.deflate("\0".b * (601 * 600))
    png = "\x89PNG\r\n\x1A\n".b + PNG.chunk("IHDR", [600, 600, 8, 0, 0, 0, 0].pack("NNCCCCC"))
    png << (PNG.chunk("tEXt", "a\0b") * 100_000)
    z.each_byte { |b| png << PNG.chunk("IDAT", b.chr) }
    png << PNG.chunk("IEND", "")
    image = nil
    time = elapsed { image = F.decode(png) }
    assert_equal "\0".b * 360_000, image.data
    assert_operator time, :<, 2.0
  end

  # --- dispatcher ---------------------------------------------------------------

  # TIFF and PDF go to their own decoders (first page); truncated headers are
  # reported by those decoders as corrupt data.
  def test_tiff_and_pdf_headers_reach_their_decoders
    { "II*\0\x08\0\0\0" => :tiff, "MM\0*\0\0\0\x08" => :tiff, "%PDF-1.7\n" => :pdf }.each do |bytes, format|
      assert_equal format, F.format_of(bytes.b)
      assert_raises(QrReader::ImageError) { F.decode(bytes.b) }
    end
  end

  # --- structured corruption ------------------------------------------------

  INTERESTING = [0, 1, 2, 3, 7, 8, 12, 13, 16, 40, 108, 124, 255, 256, 0x7FFF, 0x8000, 0xFFFF, 0x10000,
                 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF].freeze

  # Header fields set to boundary values (rather than random bytes): sizes,
  # offsets, counts, bit depths and chunk lengths at their extremes.
  def test_boundary_values_in_header_fields_raise_only_image_errors
    rng = Random.new(77)
    names = FormatFixtures.manifest.keys.reject { |n| n.include?("medium") || n.include?("photo") }
    names.each do |name|
      bytes = FormatFixtures.read(name)
      40.times do
        copy = bytes.dup
        rng.rand(1..2).times do
          pos = rng.rand([copy.bytesize, 140].min - 3)
          value = INTERESTING.sample(random: rng)
          case rng.rand(3)
          when 0 then copy[pos, 4] = [value].pack(rng.rand(2).zero? ? "V" : "N")
          when 1 then copy[pos, 2] = [value & 0xFFFF].pack(rng.rand(2).zero? ? "v" : "n")
          else copy.setbyte(pos, value & 0xFF)
          end
        end
        assert_image_or_image_error(copy) { |b| F.decode(b) }
        begin
          F.dimensions(copy)
        rescue QrReader::ImageError
          nil
        end
      end
    end
  end
end
