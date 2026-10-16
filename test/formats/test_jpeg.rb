# frozen_string_literal: true

require "test_helper"
require "json"
require "timeout"
require "qr_reader/formats/jpeg"

# JPEG decoder tests. Reference luminance comes from libjpeg-turbo (via
# Pillow); see test/fixtures/jpeg/generate.rb.
class TestJPEG < Minitest::Test
  JPEG = QrReader::Formats::JPEG
  FIXTURES = File.expand_path("../fixtures/jpeg", __dir__)
  MANIFEST = JSON.parse(File.read(File.join(FIXTURES, "manifest.json"))).to_h { |e| [e["name"], e] }.freeze

  def fixture(name)
    File.binread(File.join(FIXTURES, MANIFEST.fetch(name)["file"]))
  end

  def reference(name, scale)
    ref = MANIFEST.fetch(name)["refs"].fetch(scale.to_s)
    [ref["width"], ref["height"], Zlib::Inflate.inflate(File.binread(File.join(FIXTURES, ref["file"])))]
  end

  # Decodes with a time limit so that a hang fails instead of stalling the suite.
  def decode(bytes, scale: 1, limit: 10)
    Timeout.timeout(limit) { JPEG.decode(bytes, scale: scale) }
  end

  def max_diff(a, b)
    a.bytes.zip(b.bytes).map { |x, y| (x - y).abs }.max
  end

  # --- Reference comparisons (one test per fixture) ---------------------------

  MANIFEST.each_value do |entry|
    name = entry["name"]
    case entry["expect"]
    when "reference"
      define_method("test_reference_#{name}") do
        bytes = fixture(name)
        entry["refs"].each_key do |s|
          scale = s.to_i
          w, h, expected = reference(name, scale)
          image = decode(bytes, scale: scale)
          assert_equal [w, h], [image.width, image.height], "#{name} scale #{scale}: size"
          diff = max_diff(image.data, expected)
          assert_operator diff, :<=, entry["tolerance"], "#{name} scale #{scale}: max abs diff #{diff}"
        end
      end
    when "same_as"
      define_method("test_crafted_#{name}") do
        original = entry["same_as"]
        MANIFEST.fetch(original)["refs"].each_key do |s|
          expected = decode(fixture(original), scale: s.to_i)
          image = decode(fixture(name), scale: s.to_i)
          assert_equal [expected.width, expected.height], [image.width, image.height], entry["note"]
          assert expected.data == image.data, "#{name} (#{entry['note']}) differs from #{original} at scale #{s}"
        end
      end
    when "unsupported"
      define_method("test_unsupported_#{name}") do
        error = assert_raises(QrReader::UnsupportedImageError) { decode(fixture(name)) }
        refute_empty error.message
        assert_equal JPEG.dimensions(fixture("q75")), JPEG.dimensions(fixture(name)) unless name.start_with?("arith")
      end
    when "decodes"
      define_method("test_decodes_#{name}") do
        [1, 2, 4, 8].each do |scale|
          image = decode(fixture(name), scale: scale)
          assert_equal [(entry["width"] + scale - 1) / scale, (entry["height"] + scale - 1) / scale],
                       [image.width, image.height]
        end
      end
    end
  end

  # cmyk: :plain reads 4-component samples as ink amounts (PDFs without an
  # inverting /Decode); references from generate_plain_cmyk.rb.
  def test_plain_cmyk
    %w[cmyk ycck ycck_progressive adv_ycck_420].each do |name|
      [1, 2].each do |scale|
        expected = Zlib::Inflate.inflate(File.binread(File.join(FIXTURES, "#{name}.plain.#{scale}.gray.z")))
        jpeg = File.binread(File.join(FIXTURES, "#{name}.jpg"))
        image = JPEG.decode(jpeg, scale: scale, cmyk: :plain)
        assert_equal expected.bytes, image.data.bytes, "#{name} 1/#{scale}"
        refute_equal JPEG.decode(jpeg, scale: scale).data, image.data, name
      end
    end
    # Other components are not affected.
    assert_equal JPEG.decode(fixture("rgb")).data, JPEG.decode(fixture("rgb"), cmyk: :plain).data
    assert_raises(ArgumentError) { JPEG.decode(fixture("cmyk"), cmyk: :adobe) }
  end

  def test_manifest_covers_the_required_variants
    names = MANIFEST.keys
    %w[q5 q100 sample_4x1 sample_1x2 sample_3x1 luma_h2v2 prog_successive prog_restart restart_1 gray rgb
       ycck cmyk q1_16bit size_1x1 size_1001x3 dnl no_huffman_tables tables_anywhere arithmetic].each do |n|
      assert_includes names, n
    end
  end

  # --- Header -----------------------------------------------------------------

  def test_dimensions
    MANIFEST.each_value do |entry|
      next unless entry["refs"]

      ref = entry["refs"]["1"]
      assert_equal [ref["width"], ref["height"]], JPEG.dimensions(fixture(entry["name"])), entry["name"]
    end
    assert_equal [96, 72], JPEG.dimensions(fixture("dnl"))
    assert_equal [96, 72], JPEG.dimensions(fixture("arithmetic"))
  end

  def test_dimensions_errors
    assert_raises(QrReader::ImageError) { JPEG.dimensions("".b) }
    assert_raises(QrReader::ImageError) { JPEG.dimensions("\xFF\xD8\xFF\xD9".b) }
    assert_raises(QrReader::ImageError) { JPEG.dimensions(fixture("q75").byteslice(0, 30)) }
  end

  def test_scale_must_be_a_power_of_two_up_to_8
    assert_raises(ArgumentError) { JPEG.decode(fixture("q75"), scale: 3) }
    assert_raises(ArgumentError) { JPEG.decode(fixture("q75"), scale: 16) }
  end

  def test_accepts_non_binary_strings
    bytes = fixture("q75")
    assert_equal JPEG.decode(bytes).data, JPEG.decode(bytes.dup.force_encoding(Encoding::UTF_8)).data
  end

  def test_garbage_raises_image_error
    rng = Random.new(42)
    inputs = ["".b, "\xFF".b, "\xFF\xD8".b, "\xFF\xD8\xFF".b, "\xFF\xD8\xFF\xD9".b, "GIF89a".b,
              "\xFF\xD8\xFF\xC0\x00\x0B\x08\x00\x10\x00\x10\x01\x01\x11\x00\xFF\xD9".b,
              "\xFF\xD8".b + rng.bytes(5000), "\xFF\xD8\xFF\xDA\x00\x08\x01\x01\x00\x00\x3F\x00".b + rng.bytes(100)]
    inputs.each do |input|
      error = assert_raises(QrReader::ImageError, input.inspect[0, 40]) { decode(input) }
      refute_match(/internal/, error.message)
    end
    assert_raises(QrReader::ImageError) { JPEG.decode(nil) }
  end

  def test_huge_declared_size_is_rejected
    bytes = fixture("q75").dup
    sof = bytes.index("\xFF\xC0".b)
    bytes[sof + 5, 4] = [65_535, 65_535].pack("nn")
    assert_raises(QrReader::UnsupportedImageError) { decode(bytes) }
    # At scale 8 it is small enough to try; the data runs out at once.
    image = decode(bytes, scale: 8)
    assert_equal [8192, 8192], [image.width, image.height]
  end

  def test_huge_declared_progressive_size_is_cheap
    bytes = fixture("prog_420").dup
    sof = bytes.index("\xFF\xC2".b)
    bytes[sof + 5, 4] = [8192, 8192].pack("nn")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    image = decode(bytes, scale: 2)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal [4096, 4096], [image.width, image.height]
    assert_operator elapsed, :<, QrTestHelper.time_limit(5), "coefficient rows are only allocated where data is decoded"
  end

  def test_scan_limit_keeps_the_decoded_image
    bytes = fixture("prog_gray").dup
    last = bytes.rindex("\xFF\xDA".b)
    eoi = bytes.rindex("\xFF\xD9".b)
    scan = bytes.byteslice(last, eoi - last)
    bloated = bytes.byteslice(0, eoi) + scan * (JPEG::MAX_SCANS + 50) + "\xFF\xD9".b
    image = decode(bloated)
    assert_equal [96, 72], [image.width, image.height]
  end

  def test_dnl_lookalike_before_the_frame_is_ignored
    bytes = fixture("dnl")
    app = "\xFF\xE5\x00\x08\xFF\xDC\x00\x04\x00\x07".b
    image = decode(bytes.byteslice(0, 2) + app + bytes.byteslice(2..))
    assert_equal [96, 72], [image.width, image.height]
  end

  # --- Truncation and corruption ----------------------------------------------

  def test_truncated_baseline_keeps_the_decoded_part
    bytes = fixture("q85")
    full = decode(bytes)
    sos = bytes.index("\xFF\xDA".b)
    cut = decode(bytes.byteslice(0, sos + (bytes.bytesize - sos) / 2))
    w = full.width
    rows = (0...full.height).map { |y| full.data.byteslice(y * w, w) == cut.data.byteslice(y * w, w) }
    first_bad = rows.index(false)
    assert first_bad && first_bad >= 16, "the first MCU rows decode as before"
    assert_equal "\x80".b * w, cut.data.byteslice((full.height - 1) * w, w), "missing rows are gray"
  end

  def test_truncated_progressive_keeps_earlier_scans
    bytes = fixture("prog_420")
    full = decode(bytes)
    last_scan = bytes.rindex("\xFF\xDA".b)
    cut = decode(bytes.byteslice(0, last_scan))
    assert_equal [full.width, full.height], [cut.width, cut.height]
    assert_operator max_diff(full.data, cut.data), :<, 40, "only the last scan's detail is missing"
  end

  def test_truncation_at_many_offsets
    %w[q75 prog_successive restart_1 prog_restart gray cmyk luma_h2v2].each do |name|
      bytes = fixture(name)
      step = [bytes.bytesize / 100, 1].max
      (0...bytes.bytesize).step(step).each do |len|
        [1, 4].each do |scale|
          image = decode(bytes.byteslice(0, len), scale: scale)
          assert_kind_of QrReader::Image, image
        rescue QrReader::UnsupportedImageError => e
          flunk "#{name} cut at #{len}: unexpected #{e.class}"
        rescue QrReader::ImageError => e
          refute_match(/internal/, e.message, "#{name} cut at #{len}")
        end
      end
    end
  end

  def test_random_corruption_never_raises_anything_else
    rng = Random.new(1234)
    %w[q50 prog_successive restart_row prog_restart ycck rgb sample_4x2 luma_h2v1 tables_anywhere].each do |name|
      original = fixture(name)
      60.times do
        bytes = original.dup
        (1 + rng.rand(8)).times do
          pos = rng.rand(bytes.bytesize)
          case rng.rand(4)
          when 0 then bytes.setbyte(pos, rng.rand(256))
          when 1 then bytes.setbyte(pos, bytes.getbyte(pos) ^ (1 << rng.rand(8)))
          when 2 then bytes.insert(pos, "\xFF".b + rng.rand(256).chr)
          else bytes[pos, rng.rand(1..20)] = "".b
          end
        end
        begin
          decode(bytes, scale: [1, 2, 4, 8].sample(random: rng))
        rescue QrReader::ImageError => e
          refute_match(/internal/, e.message, name)
        end
      end
    end
  end

  def test_corrupt_headers
    q75 = fixture("q75")
    sof = q75.index("\xFF\xC0".b)
    mutations = {
      "zero width" => ->(b) { b[sof + 7, 2] = "\0\0".b },
      "bad sampling" => ->(b) { b.setbyte(sof + 11, 0x50) },
      "bad component count" => ->(b) { b.setbyte(sof + 9, 0) },
      "bad marker length" => ->(b) { b[sof + 2, 2] = "\0\1".b },
      "missing SOF" => ->(b) { b[sof, 2] = "\xFF\xE5".b },
      "bad DQT" => ->(b) { b.setbyte(b.index("\xFF\xDB".b) + 4, 0x27) },
      "bad DHT" => ->(b) { b.setbyte(b.index("\xFF\xC4".b) + 4, 0x35) },
      "bad SOS" => ->(b) { b.setbyte(b.index("\xFF\xDA".b) + 4, 9) },
      "reserved marker" => ->(b) { b[2, 0] = "\xFF\x05".b }
    }
    mutations.each do |what, mutate|
      bytes = q75.dup
      mutate.call(bytes)
      error = assert_raises(QrReader::ImageError, what) { decode(bytes) }
      refute_match(/internal/, error.message, what)
    end
  end

  def test_progressive_scan_parameters_are_validated
    bytes = fixture("prog_420").dup
    sos = bytes.index("\xFF\xDA".b)
    len = bytes.byteslice(sos + 2, 2).unpack1("n")
    bytes.setbyte(sos + 2 + len - 2, 5) # first scan: DC with Se = 5
    assert_raises(QrReader::ImageError) { decode(bytes) }
  end
end
