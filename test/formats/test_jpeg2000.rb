# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "timeout"
require "qr_reader/formats/jpeg2000"

# JPEG 2000 decoder tests. The fixtures and their expected luminance come
# from test/fixtures/jpeg2000/generate.py (OpenJPEG via Pillow and the
# opj_compress / opj_decompress tools): lossless files must decode exactly
# to the source image, lossy ones within a small tolerance of OpenJPEG.
class TestJPEG2000 < Minitest::Test
  J2K = QrReader::Formats::JPEG2000
  FIXTURES = File.expand_path("../fixtures/jpeg2000", __dir__)
  MANIFEST = JSON.parse(File.read(File.join(FIXTURES, "manifest.json"))).to_h { |e| [e["name"], e] }.freeze

  def fixture(name)
    File.binread(File.join(FIXTURES, MANIFEST.fetch(name)["file"]))
  end

  def decode(bytes, reduce: 0, limit: 30)
    Timeout.timeout(limit) { J2K.decode(bytes, reduce: reduce) }
  end

  def read_pgm(file)
    data = File.binread(File.join(FIXTURES, file))
    m = data.match(/\AP5\s+(\d+)\s+(\d+)\s+(\d+)\s/n)
    data.byteslice(m.end(0), m[1].to_i * m[2].to_i)
  end

  def diff_stats(a, b)
    max = 0
    sum = 0
    a.bytes.zip(b.bytes) do |x, y|
      d = (x - y).abs
      sum += d
      max = d if d > max
    end
    [max, sum.fdiv(a.bytesize)]
  end

  # --- Reference comparisons (one test per fixture) -------------------------

  MANIFEST.each_value do |entry|
    name = entry["name"]
    define_method("test_fixture_#{name}") do
      bytes = fixture(name)
      image = decode(bytes, reduce: entry.fetch("reduce", 0))
      assert_equal [entry["width"], entry["height"]], [image.width, image.height], "#{name}: size"
      if entry["luma"]
        actual = Digest::SHA256.hexdigest(image.data)
        assert_equal entry["luma"], actual, "#{name}: luminance differs from the source image"
      elsif entry["reference"]
        max, mean = diff_stats(image.data, read_pgm(entry["reference"]))
        assert_operator max, :<=, entry["tolerance"], "#{name}: max abs diff #{max} (mean #{mean.round(4)})"
        assert_operator mean, :<, 0.5, "#{name}: mean abs diff #{mean}"
      elsif entry["top_rows"]
        top = image.data.byteslice(0, entry["top_rows"] * image.width)
        assert_equal entry["top_luma"], Digest::SHA256.hexdigest(top), "#{name}: complete tiles differ"
      end
    end

    next unless entry["components"] || entry["color"]

    define_method("test_components_#{name}") do
      comps = Timeout.timeout(30) { J2K.decode_components(fixture(name), reduce: entry.fetch("reduce", 0)) }
      assert_equal [entry["width"], entry["height"]], [comps.width, comps.height]
      assert_equal entry["color"]&.to_sym, comps.color
      assert_equal entry.fetch("palette_applied", false), comps.palette_applied
      entry.fetch("components", []).each_with_index do |digest, i|
        assert_equal digest, Digest::SHA256.hexdigest(comps.components[i]), "#{name}: component #{i}"
      end
    end
  end

  # --- API ------------------------------------------------------------------

  def test_dimensions
    assert_equal [129, 67], J2K.dimensions(fixture("gray_53"))
    assert_equal [64, 48], J2K.dimensions(fixture("gray_raw"))
    assert_equal [100, 70], J2K.dimensions(fixture("rgb_tiles_offset"))
  end

  def test_jp2c_box_lengths
    original = fixture("gray_53")
    expected = decode(original).data
    at = original.index("jp2c") - 4
    to_end = original.dup
    to_end[at, 4] = "\0\0\0\0".b # length 0: up to the end of the file
    assert_equal expected, decode(to_end).data
    length = original.bytesize - at
    xl = original.byteslice(0, at) + [1].pack("N") + "jp2c" + [length + 8].pack("Q>") + original.byteslice(at + 8..)
    assert_equal expected, decode(xl).data
    truncated_box = original.byteslice(0, original.bytesize - 1) # jp2c box runs past the end
    assert_kind_of QrReader::Image, decode(truncated_box)
  end

  def test_decode_components_structure
    comps = J2K.decode_components(fixture("rgba"))
    assert_equal 4, comps.components.size
    assert_equal [3], comps.alpha
    assert(comps.components.all? { |c| c.bytesize == 64 * 48 && c.encoding == Encoding::BINARY })
    assert_equal :rgb, comps.color
    refute comps.palette_applied
  end

  def test_luminance_same_via_components
    %w[rgb_97_ict rgba gray_alpha cmyk palette ycc420_offset].each do |name|
      comps = J2K.decode_components(fixture(name))
      assert_equal decode(fixture(name)).data, J2K.luminance(comps), name
    end
  end

  def test_reduce_is_limited_by_the_levels
    bytes = fixture("res1") # no decomposition levels
    assert_equal [64, 48], [decode(bytes, reduce: 3).width, decode(bytes, reduce: 3).height]
    image = decode(fixture("gray_53"), reduce: 9) # 4 levels
    assert_equal [9, 5], [image.width, image.height]
  end

  def test_reduce_argument_validation
    assert_raises(ArgumentError) { J2K.decode(fixture("gray_raw"), reduce: -1) }
    assert_raises(ArgumentError) { J2K.decode(fixture("gray_raw"), reduce: "1") }
  end

  def test_reduce_skips_tier1_of_discarded_resolutions
    calls = 0
    tier1 = J2K::Tier1
    counter = Module.new do
      define_method(:decode) do |*args|
        calls += 1
        super(*args)
      end
    end
    tier1.prepend(counter)
    full = calls
    decode(fixture("cblk_4x4"))
    full = calls - full
    reduced = calls
    decode(fixture("cblk_4x4"), reduce: 2)
    reduced = calls - reduced
    assert_operator reduced, :<, full / 4, "reduce: 2 decoded #{reduced} of #{full} code-blocks"
  end

  # --- Errors and hostile input ------------------------------------------------

  def test_not_jpeg2000
    assert_raises(QrReader::ImageError) { J2K.decode("".b) }
    assert_raises(QrReader::ImageError) { J2K.decode("GIF89a....".b) }
    assert_raises(QrReader::ImageError) { J2K.decode(nil) }
    assert_raises(QrReader::ImageError) { J2K.dimensions("\xFF\x4F\xFF\x51".b) }
  end

  def test_part2_and_htj2k_are_unsupported
    bytes = fixture("gray_raw").dup
    siz = bytes.index("\xFF\x51".b)
    bytes.setbyte(siz + 4, 0x80) # Rsiz: Part 2 extensions
    assert_raises(QrReader::UnsupportedImageError) { J2K.decode(bytes) }
    bytes.setbyte(siz + 4, 0x40) # Rsiz: HTJ2K
    assert_raises(QrReader::UnsupportedImageError) { J2K.decode(bytes) }
  end

  def test_huge_declared_size_is_rejected_before_allocation
    bytes = fixture("gray_raw").dup
    siz = bytes.index("\xFF\x51".b)
    bytes[siz + 6, 8] = [100_000, 100_000].pack("N2")
    error = assert_raises(QrReader::ImageError) { Timeout.timeout(5) { J2K.decode(bytes) } }
    assert_kind_of QrReader::ImageError, error
  end

  def test_tile_without_packet_data_is_the_dc_value
    { "gray_raw" => 128, "bilevel1" => 255, "rgb_97_ict" => 128, "signed8" => 128 }.each do |name, value|
      bytes = fixture(name)
      sod = bytes.index("\xFF\x93".b)
      image = decode(bytes.byteslice(0, sod + 2))
      assert_equal [value], image.data.bytes.uniq, name
    end
  end

  def test_oversized_tile_needs_reduce
    bytes = fixture("gray_raw").dup
    siz = bytes.index("\xFF\x51".b)
    bytes[siz + 6, 8] = [16_384, 8192].pack("N2")
    bytes[siz + 22, 8] = [16_384, 8192].pack("N2") # one 134M-sample tile
    # malloc_increase_bytes is MRI's; JRuby and TruffleRuby have no such key.
    malloc_stat = GC.stat.key?(:malloc_increase_bytes)
    allocated = GC.stat(:malloc_increase_bytes) if malloc_stat
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(QrReader::UnsupportedImageError) { J2K.decode(bytes) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_operator GC.stat(:malloc_increase_bytes) - allocated, :<, 64 << 20 if malloc_stat
    image = decode(bytes, reduce: 3)
    assert_equal [2048, 1024], [image.width, image.height]
  end

  def test_tiny_precincts_and_codeblocks_on_a_large_image_are_bounded
    # A 16384 x 8192 image with 4x4 code-blocks and minimal precincts but
    # almost no data: decoding must neither allocate per code-block up front
    # nor take long.
    bytes = fixture("gray_raw").dup
    siz = bytes.index("\xFF\x51".b)
    bytes[siz + 6, 8] = [16_384, 8192].pack("N2")
    bytes[siz + 22, 8] = [16_384, 8192].pack("N2") # one tile
    result = Timeout.timeout(60) do
      J2K.decode(bytes, reduce: 3)
    rescue QrReader::ImageError => e
      e
    end
    assert(result.is_a?(QrReader::Image) || result.is_a?(QrReader::ImageError))
  end

  def test_truncations_and_bit_flips_raise_image_error_or_decode
    rnd = Random.new(2024)
    %w[gray_53 prog_rpcl mode63 ppm rgb_97_ict palette ycc420].each do |name|
      original = fixture(name)
      cases = [original.byteslice(0, original.bytesize / 3), original.byteslice(0, 60), original.byteslice(0, 2)]
      12.times do
        corrupt = original.dup
        (1 + rnd.rand(4)).times do
          pos = rnd.rand(corrupt.bytesize)
          corrupt.setbyte(pos, corrupt.getbyte(pos) ^ (1 << rnd.rand(8)))
        end
        cases << corrupt
      end
      cases.each_with_index do |bytes, i|
        result = Timeout.timeout(20) do
          J2K.decode(bytes)
        rescue QrReader::ImageError => e
          e
        end
        assert(result.is_a?(QrReader::Image) || result.is_a?(QrReader::ImageError),
               "#{name} case #{i}: #{result.class}")
      end
    end
  end

  def test_random_header_bytes
    rnd = Random.new(7)
    original = fixture("tiles_odd_offset")
    header_end = original.index("\xFF\x90".b)
    40.times do
      bytes = original.dup
      pos = rnd.rand(2...header_end)
      bytes.setbyte(pos, rnd.rand(256))
      result = Timeout.timeout(20) do
        J2K.decode(bytes)
      rescue QrReader::ImageError => e
        e
      end
      assert(result.is_a?(QrReader::Image) || result.is_a?(QrReader::ImageError), result.class.to_s)
    end
  end
end
