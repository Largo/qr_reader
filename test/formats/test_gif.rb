# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/images/format_fixtures"

class TestGIF < Minitest::Test
  include FormatFixtures::Assertions

  GIF = QrReader::Formats::GIF
  W = FormatFixtures::GifWriter

  def decode(bytes)
    GIF.decode(bytes)
  end

  def palette(n, seed: 1)
    rng = Random.new(seed)
    Array.new(n) { [rng.rand(256), rng.rand(256), rng.rand(256)] }
  end

  def indices(width, height, colors, seed: 1)
    rng = Random.new(seed)
    Array.new(height) { Array.new(width) { rng.rand(colors) } }
  end

  # Expected luminance of a frame drawn on a white canvas.
  def expected(indices, pal, canvas: nil, offset: [0, 0], transparent: nil)
    width, height = canvas || [indices[0].size, indices.size]
    rows = Array.new(height) { Array.new(width) { [255, 255, 255, 255] } }
    indices.each_with_index do |row, y|
      row.each_with_index do |index, x|
        rgb = pal[index] || [0, 0, 0]
        rows[y + offset[1]][x + offset[0]] = index == transparent ? [0, 0, 0, 0] : rgb + [255]
      end
    end
    FormatFixtures.image_from_rgba(rows)
  end

  FormatFixtures.names("gif_").each do |name|
    define_method("test_fixture_#{name.delete_suffix('.gif')}") do
      bytes = FormatFixtures.read(name)
      assert_same_image FormatFixtures.expected(name), decode(bytes), name
      entry = FormatFixtures.manifest[name]
      assert_equal [entry["width"], entry["height"]], GIF.dimensions(bytes)
    end
  end

  def test_palette_sizes_and_code_sizes
    [2, 3, 4, 16, 17, 100, 256].each do |colors|
      pal = palette(colors, seed: colors)
      idx = indices(19, 7, colors, seed: colors)
      assert_same_image expected(idx, pal), decode(W.encode(idx, palette: pal)), "#{colors} colours"
    end
  end

  def test_minimum_code_sizes_from_one_to_eight
    (1..8).each do |min|
      colors = 1 << min
      pal = palette(colors, seed: min)
      idx = indices(13, 5, colors, seed: min)
      assert_same_image expected(idx, pal), decode(W.encode(idx, palette: pal, min_code_size: min)), "min #{min}"
    end
  end

  def test_full_dictionary_with_and_without_clear_codes
    pal = palette(256)
    # Noise fills the 4096-entry dictionary several times over.
    idx = indices(200, 150, 256, seed: 4)
    [true, false].each do |clear|
      gif = W.encode(idx, palette: pal, clear_when_full: clear)
      assert_same_image expected(idx, pal), decode(gif), "clear #{clear}"
    end
    # Long runs exercise the code == next-free-code (KwKwK) case.
    runs = Array.new(60) { |y| Array.new(150) { |x| (x / 37 + y / 11) % 3 } }
    assert_same_image expected(runs, pal), decode(W.encode(runs, palette: pal))
  end

  def test_interlaced_frames_of_every_height
    pal = palette(8)
    (1..17).each do |height|
      idx = indices(5, height, 8, seed: height)
      assert_same_image expected(idx, pal), decode(W.encode(idx, palette: pal, interlace: true)), "height #{height}"
    end
  end

  def test_local_palette_takes_precedence
    global = [[0, 0, 0]] * 4
    local = palette(4, seed: 9)
    idx = indices(6, 6, 4)
    assert_same_image expected(idx, local), decode(W.encode(idx, palette: global, local_palette: local))
    assert_same_image expected(idx, local), decode(W.encode(idx, local_palette: local))
  end

  def test_transparency_from_the_last_graphic_control_extension
    pal = palette(4)
    idx = indices(7, 5, 4)
    assert_same_image expected(idx, pal, transparent: 2), decode(W.encode(idx, palette: pal, transparent: 2))
    assert_same_image expected(idx, pal, transparent: 1), decode(W.encode(idx, palette: pal, gces: [3, 1]))
    assert_same_image expected(idx, pal), decode(W.encode(idx, palette: pal, gces: [3, nil]))
    # A transparent index beyond the palette is fine.
    assert_same_image expected(idx, pal), decode(W.encode(idx, palette: pal, transparent: 200))
  end

  def test_frame_offset_on_white_canvas
    pal = palette(4)
    idx = indices(5, 3, 4)
    gif = W.encode(idx, palette: pal, screen: [12, 9], offset: [4, 6], transparent: 0)
    assert_same_image expected(idx, pal, canvas: [12, 9], offset: [4, 6], transparent: 0), decode(gif)
    assert_equal [12, 9], GIF.dimensions(gif)
  end

  def test_canvas_grows_to_fit_the_frame
    pal = palette(4)
    idx = indices(5, 3, 4)
    [[0, 0], [3, 2]].each do |screen|
      gif = W.encode(idx, palette: pal, screen: screen, offset: [2, 1])
      assert_same_image expected(idx, pal, canvas: [7, 4], offset: [2, 1]), decode(gif)
      assert_equal [7, 4], GIF.dimensions(gif)
    end
  end

  def test_out_of_range_indices_are_black_and_missing_palette_is_a_gray_ramp
    pal = palette(3)
    idx = [[0, 1, 2, 3, 7]]
    assert_same_image expected(idx, pal), decode(W.encode(idx, palette: pal, min_code_size: 3))
    assert_equal [0, 1, 2, 3, 7], decode(W.encode(idx, min_code_size: 3)).data.bytes
  end

  def test_extensions_trailer_and_following_frames
    pal = palette(4)
    idx = indices(6, 4, 4)
    app = "\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00".b
    second = W.encode(indices(6, 4, 4, seed: 7), palette: pal).byteslice(13 + 12..)
    gif = W.encode(idx, palette: pal, before: [app, W.comment("hello" * 100)], after: [second.byteslice(0, 20)],
                        trailer: false)
    assert_same_image expected(idx, pal), decode(gif)
  end

  def test_early_end_code_leaves_the_rest_white
    pal = palette(4)
    row = indices(6, 1, 4)
    gif = W.encode(row, palette: pal, screen: [6, 4])
    gif[13 + 12 + 7, 2] = [4].pack("v") # the frame claims 4 rows, the data ends after one
    image = decode(gif)
    assert_equal [6, 4], [image.width, image.height]
    assert_equal expected(row, pal).data + ("\xFF".b * 18), image.data
  end

  def test_missing_end_code_with_complete_pixels
    pal = palette(4)
    idx = indices(9, 9, 4)
    assert_same_image expected(idx, pal), decode(W.encode(idx, palette: pal, end_code: false))
  end

  def test_empty_frame_gives_white_canvas
    gif = W.encode([[]], palette: palette(2), screen: [3, 2])
    assert_equal "\xFF".b * 6, decode(gif).data
  end

  def test_errors
    pal = palette(4)
    good = W.encode(indices(8, 8, 4), palette: pal)
    assert_raises(QrReader::ImageError) { decode("GIF89a".b) }
    assert_raises(QrReader::ImageError) { decode("GIF89a\x01\x00\x01\x00\x00\x00\x00;".b) }
    assert_raises(QrReader::ImageError) { decode("GIF89a\x01\x00\x01\x00\x00\x00\x00".b) }
    assert_raises(QrReader::ImageError) { decode("GIF89a\x01\x00\x01\x00\x00\x00\x00\x99".b) }
    assert_raises(QrReader::ImageError) { decode("PNG") }
    assert_raises(QrReader::ImageError) { decode(good.byteslice(0, good.bytesize - 12)) } # truncated pixels
    bad_min = good.dup
    bad_min.setbyte(13 + 12 + 10, 12)
    assert_raises(QrReader::ImageError) { decode(bad_min) }
    # A code beyond the next free one.
    bogus = good.byteslice(0, 13 + 12 + 10) + "\x02\x02\xFF\xFF\x00;".b
    assert_raises(QrReader::ImageError) { decode(bogus) }
    huge = "GIF89a\xFF\xFF\xFF\xFF\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00;".b
    assert_raises(QrReader::UnsupportedImageError) { decode(huge) }
  end

  def test_fuzzed_fixtures_raise_only_image_errors
    names = FormatFixtures.names("gif_").reject { |n| n.include?("medium") }
    names.each_with_index do |name, i|
      FormatFixtures.mutations(FormatFixtures.read(name), seed: i, truncations: 40, flips: 80).each do |bytes|
        assert_image_or_image_error(bytes) { |b| decode(b) }
      end
    end
  end
end
