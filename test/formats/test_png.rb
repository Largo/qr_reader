# frozen_string_literal: true

require "test_helper"
require "digest"
require_relative "../fixtures/images/format_fixtures"

class TestPNG < Minitest::Test
  include FormatFixtures::Assertions

  PNG = QrReader::Formats::PNG
  W = FormatFixtures::PngWriter

  def decode(bytes)
    PNG.decode(bytes)
  end

  # Deterministic random pixels for a colour type and depth.
  def random_pixels(width, height, color_type, depth, seed: 1, palette_size: nil)
    rng = Random.new(seed)
    channels = W::CHANNELS[color_type]
    max = color_type == 3 ? (palette_size || (1 << depth)) - 1 : (1 << depth) - 1
    Array.new(height) { Array.new(width) { Array.new(channels) { rng.rand(max + 1) } } }
  end

  def random_palette(n, seed: 2)
    rng = Random.new(seed)
    Array.new(n) { [rng.rand(256), rng.rand(256), rng.rand(256)] }
  end

  def check(pixels, message = nil, **options)
    png = W.encode(pixels, **options)
    rgba_options = options.slice(:color_type, :depth, :palette, :trns)
    expected = FormatFixtures.image_from_rgba(W.expected_rgba(pixels, **rgba_options))
    assert_same_image expected, decode(png), message || options.except(:palette).inspect
  end

  # --- real encoders -------------------------------------------------------

  FormatFixtures.names("png_").each do |name|
    define_method("test_fixture_#{name.delete_suffix('.png')}") do
      bytes = FormatFixtures.read(name)
      assert_same_image FormatFixtures.expected(name), decode(bytes), name
      assert_equal [FormatFixtures.manifest[name]["width"], FormatFixtures.manifest[name]["height"]],
                   PNG.dimensions(bytes)
    end
  end

  def test_zxing_corpus_matches_pillow
    digests = File.join(FormatFixtures::DIR, "zxing_png_luma.txt")
    skip "ZXing corpus not present (rake corpus:fetch)" unless Dir.exist?(FormatFixtures::CORPUS)

    lines = File.readlines(digests, chomp: true)
    assert_equal 179, lines.size
    lines.each do |line|
      path, size, digest = line.split
      image = decode(File.binread(File.join(FormatFixtures::CORPUS, path)))
      assert_equal size, "#{image.width}x#{image.height}", path
      assert_equal digest, Digest::SHA256.hexdigest(image.data), path
    end
  end

  # --- every colour type, depth, filter and interlacing ---------------------

  def test_all_colour_types_depths_filters_and_interlacing
    { 0 => [1, 2, 4, 8, 16], 2 => [8, 16], 3 => [1, 2, 4, 8], 4 => [8, 16], 6 => [8, 16] }.each do |ct, depths|
      depths.each do |depth|
        [false, true].each do |interlace|
          [[13, 11], [1, 1], [3, 9], [9, 2]].each_with_index do |(w, h), i|
            palette = random_palette(1 << depth, seed: depth) if ct == 3
            pixels = random_pixels(w, h, ct, depth, seed: ct * 100 + depth + i)
            check(pixels, color_type: ct, depth: depth, interlace: interlace, palette: palette,
                          filters: [0, 1, 2, 3, 4].rotate(i))
          end
        end
      end
    end
  end

  def test_each_filter_type_alone_on_wide_rows
    [[2, 8], [6, 8], [0, 8], [4, 8], [2, 16], [6, 16], [0, 2]].each do |ct, depth|
      pixels = random_pixels(37, 6, ct, depth, seed: ct + depth)
      5.times do |filter|
        check(pixels, color_type: ct, depth: depth, filters: [filter])
      end
    end
  end

  def test_smooth_image_exercises_every_paeth_branch
    pixels = Array.new(16) { |y| Array.new(40) { |x| [(x * 7 + y * 3) % 256, (x * y) % 256, (255 - x * 5) % 256] } }
    check(pixels, color_type: 2, depth: 8, filters: [4])
    check(pixels, color_type: 2, depth: 8, filters: [3])
  end

  # Mostly opaque alpha images: the decoder unfilters opaque rows without
  # their alpha lane and switches to the full path for translucent ones
  # (first, middle, last pixel; whole rows), and repeats rows whose Up
  # filter bytes are all zero. 16-bit alpha with a high byte of 255 counts
  # as opaque (only high bytes are used).
  def test_opaque_and_translucent_rows_with_every_filter
    [[4, 8], [4, 16], [6, 8], [6, 16]].each do |ct, depth|
      max = (1 << depth) - 1
      pixels = random_pixels(9, 16, ct, depth, seed: ct * 7 + depth)
      pixels.each { |row| row.each { |px| px[-1] = max } }
      pixels[2][0][-1] = max - 1
      pixels[3][2][-1] = max - 0x80 if depth == 16
      pixels[5][4][-1] = 0
      pixels[8][8][-1] = max >> 1
      pixels[9].each { |px| px[-1] = 0 }
      pixels[11] = pixels[10].map(&:dup)
      pixels[12] = pixels[10].map(&:dup)
      pixels[14] = pixels[13].map { |px| px.dup.tap { |q| q[-1] = 3 } }
      pixels[15] = pixels[14].map(&:dup)
      # one pixel per row: the first pixel's alpha is all there is
      column = random_pixels(1, 8, ct, depth, seed: depth)
      column.each_with_index { |row, y| row[0][-1] = [max, max, max - 1, max, 0, max, max, max >> 2][y] }
      [[0], [1], [2], [3], [4], [0, 1, 2, 3, 4], [4, 3, 2, 1, 2]].each do |filters|
        check(pixels, color_type: ct, depth: depth, filters: filters)
        check(pixels, color_type: ct, depth: depth, filters: filters, interlace: true)
        check(column, color_type: ct, depth: depth, filters: filters)
      end
    end
  end

  # Flat areas: repeated rows (Up filter, all-zero bytes) of every layout.
  def test_repeated_rows_of_every_layout
    { 0 => [1, 2, 4, 8, 16], 2 => [8, 16], 3 => [2, 8], 4 => [8, 16], 6 => [8, 16] }.each do |ct, depths|
      depths.each do |depth|
        palette = random_palette(1 << depth, seed: depth) if ct == 3
        base = random_pixels(21, 3, ct, depth, seed: ct + depth)
        pixels = [base[0], base[0], base[0], base[1], base[2], base[2]].map { |row| row.map(&:dup) }
        [[2], [0, 2, 2], [4, 2, 2, 3, 1, 2]].each do |filters|
          check(pixels, color_type: ct, depth: depth, palette: palette, filters: filters)
        end
      end
    end
  end

  # The decoder calls the kernel on slices of rows, threading the last row
  # through: any slicing must give the same result as one call.
  def test_kernel_slices_agree_with_one_call
    [[0, 8], [0, 16], [0, 1], [3, 4], [2, 8], [2, 16], [4, 8], [4, 16], [6, 8], [6, 16]].each do |ct, depth|
      channels = W::CHANNELS[ct]
      width = 7
      height = 40
      pixels = random_pixels(width, height, ct, depth, seed: 40 + ct + depth)
      if ct == 4 || ct == 6
        max = (1 << depth) - 1
        pixels.each_with_index { |row, y| row.each { |px| px[-1] = max } unless y % 9 == 4 }
      end
      pixels[20] = pixels[19].map(&:dup)
      raw = W.filter_rows(pixels, ct, depth, [0, 1, 2, 3, 4, 2, 2, 3])
      per = channels == 1 && depth <= 8 ? (width * depth + 7) / 8 : width
      whole = QrReaderKernels.png_rows(raw, 0, height, width, depth, channels, "".b, "".b).byteslice(0, height * per)
      rng = Random.new(depth + ct)
      3.times do
        out = +"".b
        prev = "".b
        pos = 0
        y = 0
        while y < height
          n = [1 + rng.rand(7), height - y].min
          res = QrReaderKernels.png_rows(raw, pos, n, width, depth, channels, prev, "".b)
          out << res.byteslice(0, n * per)
          prev = res.byteslice(n * per, res.bytesize - n * per)
          pos += n * (1 + (width * channels * depth + 7) / 8)
          y += n
        end
        assert_equal whole, out, "colour type #{ct}, depth #{depth}"
      end
    end
  end

  # The kernels composite over white with (x * 0x8081) >> 23 for x / 255.
  def test_over_white_multiply_shift_matches_division
    256.times do |a|
      256.times do |v|
        assert_equal (v * a + 255 * (255 - a) + 127) / 255, (((v - 255) * a + 65_152) * 0x8081) >> 23
      end
    end
  end

  def test_paeth_table_matches_definition
    table = QrReaderKernels::PNG_PAETH
    rng = Random.new(3)
    2000.times do
      a, b, c = Array.new(3) { rng.rand(256) }
      assert_equal W.paeth(a, b, c), c + table[(b - c) * 511 + (a - c) + 255 * 511 + 255], [a, b, c].inspect
    end
    [[0, 0, 0], [255, 0, 255], [0, 255, 255], [255, 255, 0], [10, 20, 15], [20, 10, 15]].each do |a, b, c|
      assert_equal W.paeth(a, b, c), c + table[(b - c) * 511 + (a - c) + 255 * 511 + 255]
    end
  end

  def test_sixteen_bit_samples_keep_the_high_byte
    pixels = [[[0x12FF, 0x0001, 0xFFFF], [0x8080, 0x7FFF, 0x00FF]]]
    image = decode(W.encode(pixels, color_type: 2, depth: 16))
    assert_equal [QrReader::Image.luma(0x12, 0x00, 0xFF), QrReader::Image.luma(0x80, 0x7F, 0x00)], image.data.bytes
  end

  # --- transparency --------------------------------------------------------

  def test_gray_trns_at_every_depth
    [1, 2, 4, 8, 16].each do |depth|
      pixels = random_pixels(11, 5, 0, depth, seed: depth)
      key = pixels[2][3][0]
      [false, true].each do |interlace|
        check(pixels, color_type: 0, depth: depth, trns: [key].pack("n"), interlace: interlace)
      end
    end
  end

  def test_rgb_trns_key_must_match_all_samples_at_pixel_boundaries
    [8, 16].each do |depth|
      max = (1 << depth) - 1
      key = [5, max, 7]
      # The key's bytes also occur misaligned across neighbouring pixels.
      pixels = [[key, [max, 7, 5], key, [5, max, 6], [7, 5, max]], [[1, 2, 3], key, key, [5, max, 7], [0, 0, 0]]]
      check(pixels, color_type: 2, depth: depth, trns: key.pack("n3"))
    end
  end

  def test_rgb8_trns_key_out_of_range_matches_nothing
    pixels = [[[1, 2, 3], [255, 255, 255]]]
    image = decode(W.encode(pixels, color_type: 2, depth: 8, trns: [256, 255, 255].pack("n3")))
    assert_equal [QrReader::Image.luma(1, 2, 3), 255], image.data.bytes
  end

  def test_palette_trns_shorter_than_palette_and_out_of_range_indices
    palette = random_palette(5)
    pixels = random_pixels(9, 4, 3, 4, palette_size: 16, seed: 9) # indices up to 15: 5..15 are black
    check(pixels, color_type: 3, depth: 4, palette: palette, trns: [0, 77, 255].pack("C*"))
  end

  def test_semi_transparent_rgba_and_gray_alpha_are_composited_over_white
    pixels = [[[0, 0, 0, 0], [0, 0, 0, 128], [100, 150, 200, 255], [255, 0, 0, 1]]]
    image = decode(W.encode(pixels, color_type: 6, depth: 8))
    over = ->(v, a) { (v * a + 255 * (255 - a) + 127) / 255 }
    assert_equal [255, over.(0, 128), QrReader::Image.luma(100, 150, 200), over.(QrReader::Image.luma(255, 0, 0), 1)],
                 image.data.bytes
    image = decode(W.encode([[[0, 0], [200, 100]]], color_type: 4, depth: 8))
    assert_equal [255, over.(200, 100)], image.data.bytes
  end

  # --- chunk structure ------------------------------------------------------

  def test_multiple_idat_chunks_and_ancillary_chunks
    pixels = random_pixels(23, 17, 2, 8, seed: 5)
    extra = [["gAMA", [45_455].pack("N")], ["tEXt", "Comment\0hello"], ["zzZz", "unknown ancillary"], ["sRGB", "\0"]]
    [[1], [7, 1, 300], [64]].each do |sizes|
      check(pixels, color_type: 2, depth: 8, idat_sizes: sizes, extra_chunks: extra)
    end
  end

  def test_missing_iend_is_tolerated
    pixels = random_pixels(5, 5, 0, 8)
    check(pixels, color_type: 0, depth: 8, iend: false)
  end

  def test_truncation_after_complete_image_data_is_tolerated
    pixels = random_pixels(9, 7, 2, 8, seed: 3)
    png = W.encode(pixels, color_type: 2, depth: 8)
    expected = decode(png)
    without_crc = png.byteslice(0, png.bytesize - 12 - 4) # no IDAT CRC, no IEND
    assert_same_image expected, decode(without_crc)
    assert_raises(QrReader::ImageError) { decode(png.byteslice(0, png.bytesize - 12 - 20)) }
  end

  def test_extra_image_data_is_ignored
    pixels = random_pixels(4, 3, 0, 8)
    png = W.encode(pixels, color_type: 0, depth: 8)
    raw = W.filter_rows(pixels, 0, 8, [0]) + ("\0".b * 1000)
    header = png.byteslice(0, png.index("IDAT") - 4) # rebuild with a longer zlib stream
    longer = header + W.chunk("IDAT", Zlib::Deflate.deflate(raw)) + W.chunk("IEND", "")
    assert_equal decode(png).data, decode(longer).data
  end

  def test_zip_bomb_is_bounded_by_the_expected_size
    raw = "\0\0".b + ("\0".b * 50_000_000) # 1x1 gray image followed by 50 MB of zeros
    png = W.encode([[[0]]], color_type: 0, depth: 8)
    idat = W.chunk("IDAT", Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION))
    bomb = png.byteslice(0, 33) + idat + W.chunk("IEND", "")
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal [1, 1], [decode(bomb).width, decode(bomb).height]
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 1.0
  end

  def test_dimensions_reads_the_header_only
    png = W.encode(random_pixels(300, 2, 0, 8), color_type: 0, depth: 8)
    assert_equal [300, 2], PNG.dimensions(png.byteslice(0, 33))
  end

  # --- errors -----------------------------------------------------------------

  def ihdr_png(width, height, depth, color_type, interlace: 0, compression: 0)
    ihdr = [width, height, depth, color_type, compression, 0, interlace].pack("NNCCCCC")
    "\x89PNG\r\n\x1A\n".b + W.chunk("IHDR", ihdr)
  end

  def test_invalid_headers_raise_image_error
    assert_raises(QrReader::ImageError) { decode("not a png") }
    assert_raises(QrReader::ImageError) { decode("\x89PNG\r\n\x1A\n".b) }
    assert_raises(QrReader::ImageError) { decode("\x89PNG\r\n\x1A\n".b + W.chunk("IDAT", "x")) }
    [[0, 1, 8, 0], [1, 0, 8, 0], [1, 1, 3, 0], [1, 1, 8, 1], [1, 1, 1, 2], [1, 1, 16, 3], [1, 1, 4, 6], [1, 1, 8, 7]]
      .each do |w, h, depth, ct|
        assert_raises(QrReader::ImageError, [w, h, depth, ct].inspect) { decode(ihdr_png(w, h, depth, ct)) }
      end
    assert_raises(QrReader::ImageError) { decode(ihdr_png(1, 1, 8, 0, interlace: 2)) }
    assert_raises(QrReader::ImageError) { decode(ihdr_png(1, 1, 8, 0, compression: 1)) }
    error = assert_raises(QrReader::ImageError) { decode(ihdr_png(1, 1, 8, 0)) }
    assert_match(/no image data/, error.message)
  end

  def test_huge_dimensions_raise_before_allocating
    error = assert_raises(QrReader::UnsupportedImageError) { decode(ihdr_png(100_000, 100_000, 8, 0)) }
    assert_match(/too large/, error.message)
    assert_raises(QrReader::ImageError) { decode(ihdr_png(0x80000000, 1, 8, 0)) }
  end

  def test_cgbi_is_unsupported
    png = "\x89PNG\r\n\x1A\n".b + W.chunk("CgBI", "\x50\x00\x20\x02".b)
    assert_raises(QrReader::UnsupportedImageError) { decode(png) }
  end

  def test_palette_image_without_plte
    png = W.encode([[[0]]], color_type: 3, depth: 8)
    assert_raises(QrReader::ImageError) { decode(png) }
  end

  def test_invalid_filter_type
    png = ihdr_png(2, 1, 8, 0) + W.chunk("IDAT", Zlib::Deflate.deflate("\x05\x01\x02".b)) + W.chunk("IEND", "")
    error = assert_raises(QrReader::ImageError) { decode(png) }
    assert_match(/filter type 5/, error.message)
  end

  def test_truncated_and_corrupt_zlib_data
    png = W.encode(random_pixels(20, 20, 2, 8), color_type: 2, depth: 8)
    idat_start = png.index("IDAT") + 4
    short = W.encode(random_pixels(20, 20, 2, 8), color_type: 2, depth: 8).byteslice(0, idat_start + 30)
    assert_raises(QrReader::ImageError) { decode(short) }
    corrupt = png.dup
    corrupt.setbyte(idat_start + 2, corrupt.getbyte(idat_start + 2) ^ 0xFF)
    assert_image_or_image_error(corrupt) { |b| decode(b) }
    garbage = png.byteslice(0, idat_start) + ("\xFF".b * 40)
    assert_raises(QrReader::ImageError) { decode(garbage) }
  end

  def test_fuzzed_fixtures_raise_only_image_errors
    names = FormatFixtures.names("png_").reject { |n| n.include?("medium") }
    names.each_with_index do |name, i|
      FormatFixtures.mutations(FormatFixtures.read(name), seed: i, truncations: 24, flips: 24).each do |bytes|
        assert_image_or_image_error(bytes) { |b| decode(b) }
      end
    end
  end

  def test_non_binary_strings_are_accepted
    png = W.encode(random_pixels(3, 3, 3, 8, palette_size: 4), color_type: 3, depth: 8, palette: random_palette(4))
    assert_equal decode(png).data, decode(png.dup.force_encoding(Encoding::UTF_8)).data
  end
end
