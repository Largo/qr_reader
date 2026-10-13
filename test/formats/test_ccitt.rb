# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/tiff/tiff_fixtures"

# CCITT Group 3 / Group 4 decoding with PDF CCITTFaxDecode parameters. The
# streams come from the test-side encoder in tiff_fixtures.rb, which
# generate.rb checks against libtiff; the TIFF tests add real-encoder files.
class TestCCITT < Minitest::Test
  CCITT = QrReader::Formats::CCITT
  Enc = TiffFixtures::CcittEncoder

  def expected(rows, black_is_1: false)
    image = TiffFixtures.bilevel_image(rows)
    black_is_1 ? image.invert : image
  end

  def assert_decodes(rows, data, message = nil, **params)
    image = CCITT.decode(data, columns: rows[0].size, **params)
    exp = expected(rows, black_is_1: params[:black_is_1])
    assert_equal [exp.width, exp.height], [image.width, image.height], message
    return if exp.data == image.data

    i = (0...exp.data.bytesize).find { |j| exp.data.getbyte(j) != image.data.getbyte(j) }
    flunk "#{message}: pixel (#{i % exp.width}, #{i / exp.width}) differs"
  end

  SIZES = [[1, 1], [1, 9], [7, 5], [8, 8], [9, 13], [203, 37], [1728, 12], [2600, 7]].freeze

  def test_group4_round_trips
    SIZES.each_with_index do |(w, h), i|
      rows = TiffFixtures.random_bilevel(w, h, seed: i)
      assert_decodes rows, Enc.encode(rows, k: -1), "G4 #{w}x#{h}"
      assert_decodes rows, Enc.encode(rows, k: -1), "G4 #{w}x#{h} rows", rows: h
      assert_decodes rows, Enc.encode(rows, k: -1, rtc: false), "G4 #{w}x#{h} without EOFB", rows: h
      assert_decodes rows, Enc.encode(rows, k: -1, fill_order: 2), "G4 #{w}x#{h} LSB", fill_order: 2
      assert_decodes rows, Enc.encode(rows, k: -1), "G4 #{w}x#{h} BlackIs1", black_is_1: true
    end
  end

  def test_group3_one_dimensional_round_trips
    SIZES.each_with_index do |(w, h), i|
      rows = TiffFixtures.random_bilevel(w, h, seed: 100 + i)
      assert_decodes rows, Enc.encode(rows, k: 0), "G3 1-D #{w}x#{h}", k: 0
      assert_decodes rows, Enc.encode(rows, k: 0), "G3 1-D #{w}x#{h} EndOfLine", k: 0, end_of_line: true
      assert_decodes rows, Enc.encode(rows, k: 0, eol: false, rtc: false), "G3 1-D #{w}x#{h} no EOL", k: 0, rows: h
      assert_decodes rows, Enc.encode(rows, k: 0, byte_align: :eol), "G3 1-D #{w}x#{h} aligned EOL",
                     k: 0, encoded_byte_align: true, end_of_line: true
      assert_decodes rows, Enc.encode(rows, k: 0, byte_align: :eol_start), "G3 1-D #{w}x#{h} EOL at byte",
                     k: 0, encoded_byte_align: true, end_of_line: true
      # TIFF compression 2: byte-aligned rows, no EOLs, no RTC.
      assert_decodes rows, Enc.encode(rows, k: 0, eol: false, byte_align: :row, rtc: false), "MH #{w}x#{h}",
                     k: 0, encoded_byte_align: true, rows: h
    end
  end

  def test_group3_two_dimensional_round_trips
    SIZES.each_with_index do |(w, h), i|
      rows = TiffFixtures.random_bilevel(w, h, seed: 200 + i)
      [1, 2, 4].each do |k|
        assert_decodes rows, Enc.encode(rows, k: k), "G3 2-D K=#{k} #{w}x#{h}", k: k
        assert_decodes rows, Enc.encode(rows, k: k, byte_align: :eol), "G3 2-D K=#{k} #{w}x#{h} aligned",
                       k: k, encoded_byte_align: true, end_of_line: true
        assert_decodes rows, Enc.encode(rows, k: k, fill_order: 2), "G3 2-D K=#{k} #{w}x#{h} LSB",
                       k: k, fill_order: 2, rows: h
      end
    end
  end

  def test_byte_aligned_group4_rows
    rows = TiffFixtures.random_bilevel(37, 20, seed: 7)
    data = Enc.encode(rows, k: -1, byte_align: :row)
    assert_decodes rows, data, "EncodedByteAlign", encoded_byte_align: true
    assert_decodes rows, data, "EncodedByteAlign", encoded_byte_align: true, rows: 20
  end

  def test_runs_longer_than_the_largest_make_up_code
    w = 12_000
    rows = [[0] * 5000 + [1] * 6000 + [0] * 1000, [1] * w, [0] * w, [1] * 2560 + [0] * (w - 2560),
            [0] * 2559 + [1] * (w - 2559)]
    [-1, 0, 1].each do |k|
      assert_decodes rows, Enc.encode(rows, k: k), "K=#{k}", k: k
    end
  end

  def test_rows_parameter_pads_or_truncates
    rows = TiffFixtures.random_bilevel(40, 10, seed: 3)
    data = Enc.encode(rows, k: -1)
    image = CCITT.decode(data, columns: 40, rows: 14)
    assert_equal 14, image.height
    assert_equal expected(rows).data, image.data.byteslice(0, 400)
    assert_equal "\xFF".b * 160, image.data.byteslice(400, 160)

    image = CCITT.decode(data, columns: 40, rows: 4)
    assert_equal expected(rows).data.byteslice(0, 160), image.data
    assert_equal 10, CCITT.decode(data, columns: 40, rows: 0).height # 0 = until EOFB
  end

  def test_pdf_parameters_are_accepted
    rows = TiffFixtures.random_bilevel(30, 6, seed: 4)
    assert_decodes rows, Enc.encode(rows, k: 0), "PDF",
                   k: 0, end_of_line: true, end_of_block: false, damaged_rows_before_error: 3, rows: 6
  end

  # Group 3 rows are delimited by EOLs: a damaged row repeats the row above
  # and decoding resumes at the next EOL.
  def test_damaged_group3_row_is_replaced_by_the_row_above
    rows = TiffFixtures.random_bilevel(64, 12, seed: 5)
    [[0, 5], [2, 5]].each do |k, damaged|
      bits = rows.each_with_index.map do |row, y|
        code = +""
        if k.positive? && !(y % k).zero?
          Enc.encode_2d(code, Enc.changes(row), Enc.changes(rows[y - 1]), 64)
        else
          Enc.encode_1d(code, row)
        end
        code = "0000000011111111" if y == damaged
        tag = if k.zero? then ""
              elsif (y % k).zero? then "1"
              else "0"
              end
        Enc::EOL + tag + code
      end.join
      data = [bits + "0" * (-bits.size % 8)].pack("B*")
      want = rows.dup
      want[damaged] = rows[damaged - 1]
      assert_decodes want, data, "K=#{k}", k: k
    end
  end

  def test_damaged_group4_data_keeps_the_rows_before_the_damage
    rows = TiffFixtures.random_bilevel(50, 30, seed: 6)
    data = Enc.encode(rows, k: -1)
    cut = data.bytesize / 2
    damaged = data.byteslice(0, cut) + "\x00\x00\x00\x00".b + data.byteslice(cut + 4..)
    image = CCITT.decode(damaged, columns: 50, rows: 30)
    assert_equal 30, image.height
    good = (0...30).count { |y| image.row(y) == expected(rows).row(y) }
    assert_operator good, :>=, 5
    assert_equal "\xFF".b * 50, image.row(29)
  end

  def test_truncated_data_fills_the_rest_white
    rows = TiffFixtures.random_bilevel(80, 40, seed: 8)
    [-1, 0, 1].each do |k|
      data = Enc.encode(rows, k: k)
      image = CCITT.decode(data.byteslice(0, data.bytesize / 3), columns: 80, rows: 40, k: k)
      assert_equal expected(rows).row(0), image.row(0), "K=#{k}"
      assert_equal "\xFF".b * 80, image.row(39), "K=#{k}"
      assert_operator CCITT.decode(data.byteslice(0, data.bytesize / 3), columns: 80, k: k).height, :<, 40
    end
  end

  def test_uncompressed_mode_extension_counts_as_damage
    rows = [[0] * 16, [1] * 16]
    bits = +""
    Enc.encode_2d(bits, Enc.changes(rows[0]), [], 16)
    bits << "0000001111" << "0" * 30 # extension code (uncompressed mode)
    image = CCITT.decode([bits + "0" * (-bits.size % 8)].pack("B*"), columns: 16, rows: 2)
    assert_equal "\xFF".b * 32, image.data
    assert_raises(QrReader::ImageError) { CCITT.decode("\x02\xFF\xFF".b, columns: 16) }
  end

  def test_invalid_input_raises_image_error
    assert_raises(QrReader::ImageError) { CCITT.decode("".b, columns: 8) }
    assert_raises(QrReader::ImageError) { CCITT.decode("\x00\x00".b, columns: 8, k: 0) }
    assert_raises(QrReader::ImageError) { CCITT.decode("\x00\x01".b, columns: 0) }
    assert_raises(QrReader::ImageError) { CCITT.decode("\x00\x01".b, columns: 8, rows: -1) }
    assert_raises(QrReader::ImageError) { CCITT.decode(nil, columns: 8) }
    assert_raises(QrReader::UnsupportedImageError) { CCITT.decode("\x80".b, columns: 1 << 20, rows: 1 << 20) }
  end

  def test_garbage_never_raises_anything_else
    rng = Random.new(9)
    300.times do |i|
      data = Array.new(rng.rand(1..200)) { rng.rand(256) }.pack("C*")
      params = { columns: [1, 7, 64, 1728][i % 4], k: [-1, 0, 1, 3][i / 4 % 4], rows: [nil, 5][i % 2],
                 encoded_byte_align: i.odd?, end_of_line: (i % 3).zero?, black_is_1: (i % 5).zero? }
      begin
        image = CCITT.decode(data, **params)
        assert_equal image.width * image.height, image.data.bytesize
      rescue QrReader::ImageError
        # expected for garbage
      end
    end
  end

  def test_mutated_streams_decode_or_raise_image_error_quickly
    rows = TiffFixtures.random_bilevel(120, 60, seed: 10)
    rng = Random.new(11)
    [-1, 0, 2].each do |k|
      data = Enc.encode(rows, k: k)
      60.times do
        copy = data.dup
        3.times { copy.setbyte(rng.rand(copy.bytesize), rng.rand(256)) }
        copy = copy.byteslice(0, rng.rand(copy.bytesize)) if rng.rand(3).zero?
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          CCITT.decode(copy, columns: 120, k: k)
        rescue QrReader::ImageError
          # fine
        end
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
      end
    end
  end

  def test_a4_page_decodes_quickly
    bytes = TiffFixtures.read("scan_a4_g4.tif")
    tags = TiffFixtures.first_directory(bytes)
    data = bytes.byteslice(tags[273][0], tags[279][0])
    CCITT.decode(data, columns: 2480, rows: 3508) # warm-up (YJIT compiles per method)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    image = CCITT.decode(data, columns: 2480, rows: 3508)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal TiffFixtures.expected_digest("scan_a4_g4.tif"), Digest::SHA256.hexdigest(image.data)
    assert_operator elapsed, :<, 1.5, "A4 Group 4 page took #{elapsed.round(3)} s"
  end
end
