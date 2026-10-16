# frozen_string_literal: true

require "test_helper"
require "json"
require "timeout"
require "zlib"
require "qr_reader/formats/jpeg"

# Adversarial tests for the JPEG decoder: corner cases found by differential
# fuzzing against libjpeg-turbo (fixtures with libjpeg references, see
# test/fixtures/jpeg/generate_adversarial.rb), streams built by an
# independent minimal encoder (exact expected output), and malformed input.
class TestJPEGAdversarial < Minitest::Test
  JPEG = QrReader::Formats::JPEG
  FIXTURES = File.expand_path("../fixtures/jpeg", __dir__)
  ADVERSARIAL = JSON.parse(File.read(File.join(FIXTURES, "adversarial.json"))).to_h { |e| [e["name"], e] }.freeze
  MANIFEST = JSON.parse(File.read(File.join(FIXTURES, "manifest.json"))).to_h { |e| [e["name"], e] }.freeze

  # Minimal baseline JPEG writer for DC-only blocks, written from ITU T.81
  # without reference to the decoder: canonical Huffman codes from code
  # lengths, byte stuffing, 1-bit padding, restart intervals. All
  # components are 1x1 and use quantiser 8 for the DC, so a block decodes
  # to 128 + its DC value (clamped) at every scale.
  module MiniJPEG
    # T.81 table K.3 (luminance DC) code lengths per category.
    STD_DC = { 0 => 2, 1 => 3, 2 => 3, 3 => 3, 4 => 3, 5 => 3, 6 => 4, 7 => 5, 8 => 6, 9 => 7, 10 => 8,
               11 => 9 }.freeze
    SHORT_AC = { 0x00 => 1, 0x01 => 2, 0x11 => 3 }.freeze
    # Codes longer than any lookahead table: category 11 and EOB take 16 bits.
    LONG_DC = (0..10).to_h { |c| [c, c + 1] }.merge(11 => 16).freeze
    LONG_AC = { 0x01 => 1, 0x02 => 2, 0x03 => 3, 0x00 => 16 }.freeze

    # Collects bits MSB first, stuffing a zero after every 0xFF byte.
    class BitWriter
      def initialize
        @bytes = "".b
        @acc = 0
        @n = 0
      end

      def put(value, len)
        @acc = (@acc << len) | (value & ((1 << len) - 1))
        @n += len
        while @n >= 8
          @n -= 8
          byte = (@acc >> @n) & 0xFF
          @bytes << byte
          @bytes << 0 if byte == 0xFF
        end
        @acc &= (1 << @n) - 1
      end

      # Pads the last byte with 1-bits.
      def finish
        put((1 << (8 - @n)) - 1, 8 - @n) if @n.positive?
        @bytes
      end
    end

    module_function

    def segment(marker, payload)
      [0xFF, marker, payload.bytesize + 2].pack("CCn") + payload
    end

    # {symbol => [code, length]} for the canonical code of +lengths+.
    def codes(lengths)
      table = {}
      code = 0
      (1..16).each do |len|
        lengths.select { |_, l| l == len }.keys.sort.each do |sym|
          table[sym] = [code, len]
          code += 1
        end
        code <<= 1
      end
      table
    end

    def dht(klass, id, lengths)
      counts = (1..16).map { |len| lengths.count { |_, l| l == len } }
      symbols = lengths.sort_by { |s, l| [l, s] }.map(&:first)
      segment(0xC4, [(klass << 4) | id, *counts, *symbols].pack("C*"))
    end

    # Returns [header (through SOS), entropy-coded restart intervals, EOI].
    # +dc+ gives the DC value of component c's block (bx, by).
    def encode(width, height, dc:, components: 1, ids: nil, restart: 0, dc_lengths: STD_DC, ac_lengths: SHORT_AC,
               sof_height: height)
      ids ||= (1..components).to_a
      dc_codes = codes(dc_lengths)
      eob = codes(ac_lengths).fetch(0x00)
      header = "\xFF\xD8".b
      header << segment(0xDB, [0, 8, *Array.new(63, 1)].pack("C*"))
      frame = [8, sof_height, width, components].pack("CnnC") + ids.map { |i| [i, 0x11, 0].pack("C3") }.join
      header << segment(0xC0, frame)
      header << dht(0, 0, dc_lengths) << dht(1, 0, ac_lengths)
      header << segment(0xDD, [restart].pack("n")) if restart.positive?
      header << segment(0xDA, [components, *ids.flat_map { |i| [i, 0] }, 0, 63, 0].pack("C*"))
      bw = (width + 7) / 8
      intervals = []
      writer = nil
      preds = nil
      (bw * ((height + 7) / 8)).times do |m|
        if m.zero? || (restart.positive? && (m % restart).zero?)
          intervals << writer.finish if writer
          writer = BitWriter.new
          preds = Array.new(components, 0)
        end
        components.times do |c|
          value = dc.call(c, m % bw, m / bw)
          diff = value - preds[c]
          preds[c] = value
          size = diff.zero? ? 0 : diff.abs.bit_length
          writer.put(*dc_codes.fetch(size))
          writer.put(diff.negative? ? diff + (1 << size) - 1 : diff, size) if size.positive?
          writer.put(*eob)
        end
      end
      intervals << writer.finish
      [header, intervals, "\xFF\xD9".b]
    end

    # Joins the intervals with RST markers numbered 0, 1, ... 7, 0, ...
    def assemble(header, intervals, trailer)
      out = header.dup
      intervals.each_with_index do |data, i|
        out << [0xFF, 0xD0 + ((i - 1) & 7)].pack("C2") if i.positive?
        out << data
      end
      out << trailer
    end

    # Expected luminance at +scale+; +gray+ lists the MCU indices (one block
    # each) that must come out mid-gray.
    def expected(width, height, scale, gray: [], &dc)
      bw = (width + 7) / 8
      size = 8 / scale
      ow = (width + scale - 1) / scale
      oh = (height + scale - 1) / scale
      out = String.new(capacity: ow * oh, encoding: Encoding::BINARY)
      oh.times do |y|
        ow.times do |x|
          bx = x / size
          by = y / size
          out << (gray.include?(by * bw + bx) ? 128 : sample(dc.call(bx, by), scale))
        end
      end
      out
    end

    # libjpeg-turbo's sample for a DC-only block (quantiser 8): saturated,
    # except by the C 1x1 IDCT used at scale 8, whose range-limit table
    # (jdmaster.c) wraps samples more than 384 out of range around.
    def sample(dc, scale)
      return (128 + dc).clamp(0, 255) unless scale == 8

      x = dc & 1023
      if x < 128 then x + 128
      elsif x < 512 then 255
      elsif x < 896 then 0
      else x - 896
      end
    end
  end

  def fixture(name)
    File.binread(File.join(FIXTURES, "#{name}.jpg"))
  end

  def decode(bytes, scale: 1, limit: 10)
    Timeout.timeout(limit) { JPEG.decode(bytes, scale: scale) }
  end

  def assert_image(expected, image, message = nil)
    actual = image.data
    first = (0...expected.bytesize).find { |i| expected.getbyte(i) != actual.getbyte(i) }
    assert expected.bytesize == actual.bytesize && expected == actual, "#{message}: pixels differ at #{first}"
  end

  # --- libjpeg references ------------------------------------------------------

  ADVERSARIAL.each_value do |entry|
    define_method("test_reference_#{entry['name']}") do
      bytes = File.binread(File.join(FIXTURES, entry["file"]))
      entry["refs"].each do |s, ref|
        expected = Zlib::Inflate.inflate(File.binread(File.join(FIXTURES, ref["file"])))
        image = decode(bytes, scale: s.to_i)
        assert_equal [ref["width"], ref["height"]], [image.width, image.height], "#{entry['name']} scale #{s}"
        assert_image expected, image, "#{entry['name']} (#{entry['note']}) at scale #{s}"
      end
    end
  end

  # Subsampled luma fixtures of the main set only have scale 1 references;
  # at reduced scales they must still match the full decode closely.
  def test_subsampled_luma_reduced_scales_follow_the_full_decode
    %w[luma_h2v2 luma_h2v1 luma_h1v2 luma_h2v2b luma_h3v1 luma_h2v4].each do |name|
      bytes = fixture(name)
      full = decode(bytes)
      [2, 4].each do |s|
        image = decode(bytes, scale: s)
        reduced = full.downscale(s)
        diffs = (0...reduced.height).flat_map do |y|
          (0...reduced.width).map { |x| (image[x, y] - reduced[x, y]).abs }
        end
        assert_operator diffs.sum.fdiv(diffs.size), :<, 12, "#{name} at scale #{s}"
      end
    end
  end

  # --- Streams from the independent encoder -----------------------------------

  PATTERN = ->(bx, by) { ((bx * 37 + by * 91) % 251) - 125 }

  def mini(width, height, **opts, &dc)
    dc ||= PATTERN
    MiniJPEG.encode(width, height, dc: ->(c, bx, by) { c.zero? ? dc.call(bx, by) : (c * 50) - 75 }, **opts)
  end

  def test_mini_encoder_streams_decode_exactly
    [[37, 21, 0], [64, 16, 0], [9, 50, 3], [80, 8, 7]].each do |w, h, restart|
      header, intervals, trailer = mini(w, h, restart: restart)
      bytes = MiniJPEG.assemble(header, intervals, trailer)
      [1, 2, 4, 8].each do |s|
        assert_image MiniJPEG.expected(w, h, s, &PATTERN), decode(bytes, scale: s), "#{w}x#{h}/#{restart} scale #{s}"
      end
    end
  end

  def test_sixteen_bit_huffman_codes
    dc = ->(bx, by) { [0, 1023, -1024, 1, -1, 700, -700, 2, 0, 3][(bx + by) % 10] } # categories 0..11
    header, intervals, trailer = mini(80, 24, restart: 4, dc_lengths: MiniJPEG::LONG_DC,
                                              ac_lengths: MiniJPEG::LONG_AC, &dc)
    bytes = MiniJPEG.assemble(header, intervals, trailer)
    [1, 4, 8].each { |s| assert_image MiniJPEG.expected(80, 24, s, &dc), decode(bytes, scale: s), "scale #{s}" }
  end

  def test_three_components_with_duplicate_ids
    header, intervals, trailer = mini(40, 24, components: 3, ids: [1, 1, 1], restart: 5)
    bytes = MiniJPEG.assemble(header, intervals, trailer)
    assert_image MiniJPEG.expected(40, 24, 1, &PATTERN), decode(bytes), "Y must not be overwritten by Cb/Cr blocks"
  end

  def test_height_from_dnl_with_restart_intervals
    header, intervals, = mini(24, 40, restart: 2, sof_height: 0)
    bytes = MiniJPEG.assemble(header, intervals, "\xFF\xDC\x00\x04\x00\x28\xFF\xD9".b)
    assert_equal [24, 40], JPEG.dimensions(bytes)
    assert_image MiniJPEG.expected(24, 40, 1, &PATTERN), decode(bytes)
  end

  # Restart-marker stream with one MCU (one 8x8 block) per interval.
  def restart_stream(width = 48, height = 32)
    header, intervals, trailer = mini(width, height, restart: 1)
    [header, intervals, trailer]
  end

  # Joins intervals with explicit [marker number or nil, data] pairs.
  def join(header, parts, trailer)
    header + parts.map { |m, data| (m ? [0xFF, 0xD0 + (m & 7)].pack("C2") : "".b) + data }.join + trailer
  end

  def numbered(intervals)
    intervals.each_with_index.map { |data, i| [i.zero? ? nil : i - 1, data] }
  end

  def test_lost_restart_intervals_leave_gray_holes
    header, intervals, trailer = restart_stream
    [[5], [9, 10, 11], [17, 18, 19, 20, 21], [23]].each do |lost|
      parts = numbered(intervals).reject.with_index { |_, i| lost.include?(i) }
      bytes = join(header, parts, trailer)
      assert_image MiniJPEG.expected(48, 32, 1, gray: lost, &PATTERN), decode(bytes), "intervals #{lost} lost"
    end
  end

  def test_stale_repeated_interval_is_dropped
    header, intervals, trailer = restart_stream
    parts = numbered(intervals)
    parts.insert(8, [6, intervals[7]]) # interval 7 (after RST6) sent again after interval 7
    assert_image MiniJPEG.expected(48, 32, 1, &PATTERN), decode(join(header, parts, trailer))
  end

  def test_corrupt_restart_marker_number_is_ignored
    header, intervals, trailer = restart_stream
    [1, 2, 5].each do |wrong|
      parts = numbered(intervals)
      parts[10] = [9 + wrong, parts[10][1]] # RST1 damaged to RST(1 + wrong)
      assert_image MiniJPEG.expected(48, 32, 1, &PATTERN), decode(join(header, parts, trailer)), "RST off by #{wrong}"
    end
  end

  def test_reserved_marker_in_scan_data_only_loses_its_interval
    header, intervals, trailer = restart_stream
    parts = numbered(intervals)
    parts[6] = [parts[6][0], "\xFF\x13".b + parts[6][1]]
    assert_image MiniJPEG.expected(48, 32, 1, gray: [6], &PATTERN), decode(join(header, parts, trailer))
  end

  def test_fill_bytes_and_marker_wraparound
    header, intervals, trailer = restart_stream(96, 40) # 60 intervals: RST numbers wrap seven times
    bytes = header + intervals.each_with_index.map do |data, i|
      (i.zero? ? "".b : ("\xFF" * (i % 4)).b + [0xFF, 0xD0 + ((i - 1) & 7)].pack("C2")) + data
    end.join + trailer
    assert_image MiniJPEG.expected(96, 40, 1, &PATTERN), decode(bytes)
  end

  def test_restart_markers_without_restart_interval_end_the_data
    header, intervals, trailer = restart_stream
    header = header.sub("\xFF\xDD\x00\x04\x00\x01".b, "".b)
    image = decode(MiniJPEG.assemble(header, intervals, trailer))
    assert_image MiniJPEG.expected(48, 32, 1, gray: (1...24).to_a, &PATTERN), image
  end

  def test_truncation_keeps_complete_intervals
    header, intervals, trailer = restart_stream(40, 24)
    bytes = MiniJPEG.assemble(header, intervals, trailer)
    full = MiniJPEG.expected(40, 24, 1, &PATTERN)
    blocks = 15
    (header.bytesize..bytes.bytesize).each do |len|
      image = decode(bytes.byteslice(0, len))
      decoded = (0...blocks).map { |m| image[(m % 5) * 8, (m / 5) * 8] }
      exact = (0...blocks).map { |m| full.getbyte((m / 5) * 8 * 40 + (m % 5) * 8) }
      states = decoded.zip(exact).map { |d, e| d == e ? :ok : (d == 128 ? :gray : :bad) }
      refute_includes states, :bad, "cut at #{len}"
      first_gray = states.index(:gray) || blocks
      assert states[first_gray..].all?(:gray), "cut at #{len}: decoded block after a gray one" if first_gray < blocks
    end
  end

  # Samples far out of range saturate like libjpeg-turbo's SIMD IDCTs, except
  # at scale 8, where its C 1x1 IDCT wraps them (both checked with Pillow).
  def test_far_out_of_range_samples
    dc = ->(bx, _) { bx.even? ? 1000 : -1000 }
    header, intervals, trailer = mini(32, 8, &dc)
    bytes = MiniJPEG.assemble(header, intervals, trailer)
    [1, 2, 4].each do |s|
      image = decode(bytes, scale: s)
      assert_equal [255, 0, 255, 0], [0, 8, 16, 24].map { |x| image[x * image.width / 32, 0] }, "scale #{s}"
    end
    assert_equal [104, 152, 104, 152], decode(bytes, scale: 8).data.bytes
  end

  # --- Robustness ---------------------------------------------------------------

  def test_progressive_coefficient_memory_is_bounded
    bytes = fixture("ycck_progressive").dup # four needed components
    sof = bytes.index("\xFF\xC2".b)
    bytes[sof + 5, 4] = [8192, 8192].pack("nn")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(QrReader::UnsupportedImageError) { decode(bytes) }
    assert_match(/scale/, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, QrTestHelper.time_limit(1)
    image = decode(bytes, scale: 8)
    assert_equal [1024, 1024], [image.width, image.height]
  end

  # A small file declaring a large image whose (empty) sequential scan is
  # repeated: only the first scan of a component may be decoded.
  def test_repeated_sequential_scans_are_ignored
    header, = mini(16, 16, restart: 1)
    header = header.dup
    sof = header.index("\xFF\xC0".b)
    header[sof + 5, 4] = [4096, 8192].pack("nn")
    header[header.index("\xFF\xDD".b) + 4, 2] = [32_768].pack("n")
    sos = header.byteslice(header.index("\xFF\xDA".b)..)
    empty_intervals = (0...16).map { |i| [0xFF, 0xD0 + (i & 7)].pack("C2") }.join
    bytes = header + empty_intervals + ((sos + empty_intervals) * 300) + "\xFF\xD9".b
    image = decode(bytes, limit: 20)
    assert_equal [8192, 4096], [image.width, image.height]
    assert_equal 0, image.data.count("^\x80".b), "no data: all gray"
  end

  # Progressive refinement scans made of end-of-band runs cost almost no
  # data but visit every block: their number is limited.
  def test_end_of_band_run_scan_bomb
    width = height = 2048
    blocks = (width / 8) * (height / 8)
    bytes = "\xFF\xD8".b + MiniJPEG.segment(0xDB, [0, *Array.new(64, 1)].pack("C*"))
    bytes << MiniJPEG.segment(0xC2, [8, height, width, 1, 1, 0x11, 0].pack("CnnCCCC"))
    bytes << MiniJPEG.segment(0xC4, [0x00, 1, *Array.new(15, 0), 0x00].pack("C*")) # DC: category 0 = "0"
    bytes << MiniJPEG.segment(0xC4, [0x10, 1, *Array.new(15, 0), 0xE0].pack("C*")) # AC: EOB14 = "0"
    bytes << MiniJPEG.segment(0xDA, [1, 1, 0, 0, 0, 0].pack("C*")) << ("\0".b * (blocks / 8))
    bits = "0#{'1' * 14}" * ((blocks + 32_766) / 32_767) # runs of 32767 blocks
    bits += "1" * (-bits.size % 8)
    refine = MiniJPEG.segment(0xDA, [1, 1, 0, 1, 63, 0x10].pack("C*")) # AC 1..63 refinement, Ah 1, Al 0
    refine += [bits].pack("B*").gsub("\xFF".b, "\xFF\x00".b)
    bytes << (refine * 250) << "\xFF\xD9".b
    image = decode(bytes, limit: 30)
    assert_equal "\x80".b * (width * height), image.data
  end

  def test_jpeg_ls_is_unsupported
    bytes = fixture("gray").sub("\xFF\xC0".b, "\xFF\xF7".b)
    assert_raises(QrReader::UnsupportedImageError) { decode(bytes) }
    assert_equal [96, 72], JPEG.dimensions(bytes)
  end

  def test_errors_are_plain_image_errors
    q75 = fixture("q75") # SOF at 158, SOS at 318
    calls = [40, 165, 300, 325].map { |len| -> { JPEG.decode(q75.byteslice(0, len)) } }
    calls += [40, 165].map { |len| -> { JPEG.dimensions(q75.byteslice(0, len)) } }
    calls << -> { JPEG.dimensions("\xFF\xD8\xFF\xC0\x00".b) }
    calls.each do |call|
      error = assert_raises(QrReader::ImageError) { call.call }
      assert_equal QrReader::ImageError, error.class, "the internal Truncated class leaked"
    end
  end

  def test_scale_values
    bytes = fixture("q75")
    assert_equal JPEG.decode(bytes, scale: 2).data, JPEG.decode(bytes, scale: 2.0).data
    [0, 3, -2, 2.5, "2", nil, 16].each do |scale|
      assert_raises(ArgumentError, scale.inspect) { JPEG.decode(bytes, scale: scale) }
    end
  end

  def test_markers_inside_segments_and_after_the_image_are_ignored
    q75 = fixture("q75")
    expected = decode(q75).data
    thumb = fixture("gray")
    exif = MiniJPEG.segment(0xE1, "Exif\0\0".b + thumb) # a complete JPEG inside APP1
    com = MiniJPEG.segment(0xFE, "\xFF\xD9\xFF\xD8\xFF\xC0\xFF\xDA".b)
    variants = {
      "EXIF thumbnail" => q75.byteslice(0, 2) + exif + q75.byteslice(2..),
      "COM with markers" => q75.byteslice(0, 2) + com + q75.byteslice(2..),
      "trailing JPEG" => q75 + thumb,
      "trailing garbage" => q75 + Random.new(5).bytes(300)
    }
    variants.each { |what, bytes| assert expected == decode(bytes).data, what }
  end

  def test_truncated_and_corrupted_adversarial_fixtures
    rng = Random.new(99)
    ADVERSARIAL.each_key do |name|
      original = fixture(name)
      step = [original.bytesize / 25, 1].max
      inputs = (0...original.bytesize).step(step).map { |len| original.byteslice(0, len) }
      12.times do
        bytes = original.dup
        (1 + rng.rand(4)).times { bytes.setbyte(rng.rand(bytes.bytesize), rng.rand(256)) }
        inputs << bytes
      end
      inputs.each do |bytes|
        scale = [1, 2, 4, 8].sample(random: rng)
        image = decode(bytes, scale: scale, limit: 5)
        assert_kind_of QrReader::Image, image
      rescue QrReader::UnsupportedImageError => e
        flunk "#{name}: unexpected #{e.message}" unless e.message.match?(/bit|arithmetic|lossless|hierarch|LS|large/)
      rescue QrReader::ImageError => e
        refute_match(/internal/, e.message, name)
      end
    end
  end

  def test_restart_stream_survives_every_single_byte_change
    header, intervals, trailer = restart_stream(24, 16)
    bytes = MiniJPEG.assemble(header, intervals, trailer)
    (header.bytesize...bytes.bytesize).each do |pos|
      [0x00, 0xFF, 0xD3, 0x13, bytes.getbyte(pos) ^ 0x10].each do |value|
        mutated = bytes.dup
        mutated.setbyte(pos, value)
        image = decode(mutated, limit: 2)
        assert_equal [24, 16], [image.width, image.height]
      rescue QrReader::ImageError => e
        refute_match(/internal/, e.message, "byte #{pos} = #{value}")
      end
    end
  end
end
