# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/pdf/pdf_writer"

# PDF image extraction on documents built object by object with PdfWriter:
# colour spaces, bit depths, Decode arrays, filters, inline images, forms,
# page trees and damaged structure. Expected pixels are computed here from
# the PDF specification (the semantics were cross-checked by rendering the
# same documents with Ghostscript).
class TestPdfSynthetic < Minitest::Test
  PDF = QrReader::Formats::PDF
  W = 37
  H = 23

  def rng
    @rng ||= Random.new(42)
  end

  def random_bytes(n)
    Array.new(n) { rng.rand(256) }.pack("C*")
  end

  # Packs sample values (rows of +per_row+ samples) at +bpc+ bits, rows
  # padded to whole bytes.
  def pack(samples, bpc, per_row)
    samples.each_slice(per_row).map do |row|
      bits = row.map { |s| s.to_s(2).rjust(bpc, "0") }.join
      [bits + ("0" * (-bits.size % 8))].pack("B*")
    end.join
  end

  def image_pdf(dict, data, width: W, height: H, resources: {}, **options)
    w = PdfWriter.new
    img = w.add({ Type: :XObject, Subtype: :Image, Width: width, Height: height }.merge(dict), stream: data)
    w.document([["q #{width} 0 0 #{height} 0 0 cm /Im0 Do Q", { XObject: { Im0: img } }.merge(resources)]], **options)
  end

  def inline_pdf(dict, data, resources: nil)
    content = "q 10 0 0 10 0 0 cm\nBI #{dict} ID ".b + data.b + "\nEI\nQ".b
    PdfWriter.new.document([[content, resources]])
  end

  def single_image(pdf)
    images = PDF.images(pdf)
    assert_equal 1, images.size
    images.first
  end

  # The one image of a document showing +data+ as an image XObject.
  def extract(data, space = :DeviceGray, bpc: 8, resources: {}, **dict)
    single_image(image_pdf({ ColorSpace: space, BitsPerComponent: bpc }.merge(dict), data, resources: resources))
  end

  def assert_image(expected_values, image, message = nil, width: W, height: H, tolerance: 0)
    assert_equal [width, height], [image.width, image.height], message
    if tolerance.zero?
      assert_equal expected_values, image.data.bytes, message
    else
      worst = expected_values.zip(image.data.bytes).map { |a, b| (a - b).abs }.max
      assert_operator worst, :<=, tolerance, message
    end
  end

  def luma(r, g, b) = QrReader::Image.luma(r, g, b)

  # --- samples, colour spaces and Decode arrays ------------------------

  def test_gray_bit_depths
    { 1 => 255, 2 => 85, 4 => 17 }.each do |bpc, step|
      samples = Array.new(W * H) { rng.rand(1 << bpc) }
      image = single_image(image_pdf({ ColorSpace: :DeviceGray, BitsPerComponent: bpc }, pack(samples, bpc, W)))
      assert_image samples.map { |s| s * step }, image
    end
    gray = random_bytes(W * H)
    assert_image gray.bytes, single_image(image_pdf({ ColorSpace: :DeviceGray, BitsPerComponent: 8 }, gray))
    wide = Array.new(W * H) { rng.rand(65_536) }
    image = single_image(image_pdf({ ColorSpace: :DeviceGray, BitsPerComponent: 16 }, wide.pack("n*")))
    assert_image wide.map { |v| v >> 8 }, image
  end

  def test_decode_arrays
    gray = random_bytes(W * H)
    image = single_image(image_pdf({ ColorSpace: :DeviceGray, BitsPerComponent: 8, Decode: [1, 0] }, gray))
    assert_image gray.bytes.map { |v| 255 - v }, image
    image = single_image(image_pdf({ ColorSpace: :DeviceGray, BitsPerComponent: 8, Decode: [0.2, 0.7] }, gray))
    assert_image gray.bytes.map { |v| ((0.2 + v / 255.0 * 0.5) * 255).round }, image, tolerance: 1
    bits = Array.new(W * H) { rng.rand(2) }
    image = single_image(image_pdf({ ColorSpace: :DeviceGray, BitsPerComponent: 1, Decode: [1, 0] }, pack(bits, 1, W)))
    assert_image bits.map { |b| b.zero? ? 255 : 0 }, image
  end

  # ISO 32000-1 8.9.6.2: with the default Decode [0 1] a 0 bit paints
  # (black), a 1 bit leaves the page unchanged (white); [1 0] reverses.
  def test_stencil_masks
    bits = Array.new(W * H) { rng.rand(2) }
    data = pack(bits, 1, W)
    image = single_image(image_pdf({ ImageMask: true }, data))
    assert_image bits.map { |b| b.zero? ? 0 : 255 }, image
    image = single_image(image_pdf({ ImageMask: true, BitsPerComponent: 1, Decode: [1, 0] }, data))
    assert_image bits.map { |b| b.zero? ? 255 : 0 }, image
  end

  # CMYK and YCCK JPEGs: PDFs read the decoded values as ink amounts unless
  # /Decode inverts them (as Adobe applications write CMYK JPEGs).
  def test_cmyk_jpeg_with_and_without_inverting_decode
    jpeg_dir = File.expand_path("../fixtures/jpeg", __dir__)
    %w[cmyk ycck].each do |name|
      jpeg = File.binread(File.join(jpeg_dir, "#{name}.jpg"))
      plain = QrReader::Formats::JPEG.decode(jpeg, cmyk: :plain)
      inverted = QrReader::Formats::JPEG.decode(jpeg)
      [[nil, plain], [[1, 0, 1, 0, 1, 0, 1, 0], inverted]].each do |decode, expected|
        dict = { ColorSpace: :DeviceCMYK, BitsPerComponent: 8, Filter: :DCTDecode }
        dict[:Decode] = decode if decode
        pdf = image_pdf(dict, jpeg, width: plain.width, height: plain.height)
        assert_equal expected.data, single_image(pdf).data, "#{name} #{decode.inspect}"
        # The reader's raw-JPEG path decodes it the same way.
        image, info = PDF.each_image(pdf, raw_jpeg: true).first
        image = QrReader::Formats::JPEG.decode(image) if info[:format] == :jpeg
        assert_equal expected.data, image.data, "#{name} #{decode.inspect} raw_jpeg"
      end
    end
  end

  def test_rgb_cmyk_and_their_decode_arrays
    rgb = random_bytes(W * H * 3)
    image = single_image(image_pdf({ ColorSpace: :DeviceRGB, BitsPerComponent: 8 }, rgb))
    assert_image rgb.bytes.each_slice(3).map { |r, g, b| luma(r, g, b) }, image
    image = extract(rgb, :DeviceRGB, Decode: [1, 0, 0, 1, 0, 1])
    assert_image rgb.bytes.each_slice(3).map { |r, g, b| luma(255 - r, g, b) }, image

    cmyk = random_bytes(W * H * 4)
    image = single_image(image_pdf({ ColorSpace: :DeviceCMYK, BitsPerComponent: 8 }, cmyk))
    expected = cmyk.bytes.each_slice(4).map do |c, m, y, k|
      ink = ->(v) { ((255 - v) * (255 - k) + 127) / 255 }
      luma(ink[c], ink[m], ink[y])
    end
    assert_image expected, image

    samples = Array.new(W * H * 3) { rng.rand(16) }
    image = single_image(image_pdf({ ColorSpace: :DeviceRGB, BitsPerComponent: 4 }, pack(samples, 4, W * 3)))
    assert_image samples.each_slice(3).map { |r, g, b| luma(r * 17, g * 17, b * 17) }, image
  end

  def test_cie_and_icc_colour_spaces
    gray = random_bytes(W * H)
    rgb = random_bytes(W * H * 3)
    rgb_luma = rgb.bytes.each_slice(3).map { |r, g, b| luma(r, g, b) }
    assert_image gray.bytes, extract(gray, [:CalGray, { WhitePoint: [1, 1, 1] }])
    assert_image rgb_luma, extract(rgb, [:CalRGB, { WhitePoint: [1, 1, 1] }])

    w = PdfWriter.new
    icc1 = w.add({ N: 1 }, stream: "fake profile")
    icc3 = w.add({ N: 3, Alternate: :DeviceRGB }, stream: "fake profile")
    i1 = w.image(width: W, height: H, data: gray, color_space: [:ICCBased, icc1])
    i3 = w.image(width: W, height: H, data: rgb, color_space: [:ICCBased, icc3])
    images = PDF.images(w.document([["/A Do /B Do", { XObject: { A: i1, B: i3 } }]]))
    assert_equal [gray.bytes, rgb_luma], images.map { |i| i.data.bytes }

    lab = Array.new(W * H) { [rng.rand(256), rng.rand(256), rng.rand(256)] }
    image = extract(lab.flatten.pack("C*"), [:Lab, { WhitePoint: [0.95, 1, 1.09] }])
    assert_image lab.map(&:first), image
  end

  def test_separation_and_device_n_tints_are_darkness
    tints = random_bytes(W * H)
    function = { FunctionType: 2, Domain: [0, 1], C0: [1], C1: [0], N: 1 }
    image = extract(tints, [:Separation, :Spot, :DeviceGray, function])
    assert_image tints.bytes.map { |t| 255 - t }, image
    image = extract(tints, [:Separation, :None, :DeviceGray, function])
    assert_image [255] * (W * H), image

    two = random_bytes(W * H * 2)
    space = [:DeviceN, %i[Cyan Spot], :DeviceCMYK, function]
    image = single_image(image_pdf({ ColorSpace: space, BitsPerComponent: 8 }, two))
    assert_image two.bytes.each_slice(2).map { |a, b| 255 - [a, b].max }, image
  end

  def test_indexed_colour_spaces
    palette = random_bytes(256 * 3)
    lumas = palette.bytes.each_slice(3).map { |r, g, b| luma(r, g, b) }
    indices = random_bytes(W * H)
    image = extract(indices, [:Indexed, :DeviceRGB, 255, PdfWriter::Hex.new(palette)])
    assert_image indices.bytes.map { |i| lumas[i] }, image

    # Literal string lookup (escapes, parentheses, CR/LF) and indices above hival.
    gray_palette = (0..99).map { |i| (i * 7 + 3) % 256 }.pack("C*") + "()\\\r\n".b
    space = [:Indexed, :DeviceGray, gray_palette.bytesize - 1, gray_palette]
    image = single_image(image_pdf({ ColorSpace: space, BitsPerComponent: 8 }, indices))
    assert_image indices.bytes.map { |i| gray_palette.getbyte([i, gray_palette.bytesize - 1].min) }, image

    w = PdfWriter.new
    table = "\x10\x20\x30\x40\x50\x60\x70\x80\x90\xA0\xB0\xC0".b
    lookup = w.add({ Filter: :FlateDecode }, stream: Zlib::Deflate.deflate(table))
    samples = Array.new(W * H) { rng.rand(4) }
    img = w.add({ Type: :XObject, Subtype: :Image, Width: W, Height: H, ColorSpace: [:Indexed, :DeviceRGB, 3, lookup],
                  BitsPerComponent: 2 }, stream: pack(samples, 2, W))
    image = single_image(w.document([["/Im0 Do", { XObject: { Im0: img } }]]))
    entry = ->(i) { luma(0x10 + 0x30 * i, 0x20 + 0x30 * i, 0x30 + 0x30 * i) }
    assert_image samples.map { |s| entry[s] }, image

    samples = Array.new(W * H) { rng.rand(16) }
    space = [:Indexed, :DeviceGray, 15, (0..15).map { |i| i * 16 }.pack("C*")]
    image = extract(pack(samples, 4, W), space, bpc: 4, Decode: [15, 0])
    assert_image samples.map { |s| (15 - s) * 16 }, image
  end

  def test_named_colour_spaces_from_resources
    gray = random_bytes(W * H)
    resources = { ColorSpace: { CS0: :CS1, CS1: [:Indexed, :DeviceGray, 255, (0..255).to_a.reverse.pack("C*")] } }
    image = extract(gray, :CS0, resources: resources)
    assert_image gray.bytes.map { |v| 255 - v }, image

    looping = { ColorSpace: { CS0: :CS1, CS1: :CS0 } }
    assert_raises(QrReader::UnsupportedImageError) { extract(gray, :CS0, resources: looping) }
  end

  # --- filters -------------------------------------------------------------

  def test_flate_with_png_and_tiff_predictors
    gray = random_bytes(W * H)
    rows = PdfWriter.png_predict(gray, W, 1, [0, 1, 2, 3, 4, 2, 4])
    image = extract(Zlib::Deflate.deflate(rows), Filter: :FlateDecode, DecodeParms: { Predictor: 15, Columns: W })
    assert_image gray.bytes, image

    rgb = random_bytes(W * H * 3)
    expected = rgb.bytes.each_slice(3).map { |r, g, b| luma(r, g, b) }
    rows = PdfWriter.png_predict(rgb, W * 3, 3, [4, 3, 2, 1, 0])
    dict = { ColorSpace: :DeviceRGB, BitsPerComponent: 8, Filter: :FlateDecode,
             DecodeParms: { Predictor: 12, Colors: 3, Columns: W } }
    assert_image expected, single_image(image_pdf(dict, Zlib::Deflate.deflate(rows)))
    dict[:DecodeParms] = { Predictor: 2, Colors: 3, Columns: W }
    assert_image expected, single_image(image_pdf(dict, Zlib::Deflate.deflate(PdfWriter.tiff_predict(rgb, W * 3, 3))))
  end

  def test_tiff_predictor_on_bilevel_rows
    bits = Array.new(W * H) { rng.rand(2) }
    rows = bits.each_slice(W).map do |row|
      [0] + row.each_cons(2).map { |a, b| a ^ b } # horizontal differencing mod 2
    end
    dict = { ColorSpace: :DeviceGray, BitsPerComponent: 1, Filter: :FlateDecode,
             DecodeParms: { Predictor: 2, Columns: W, BitsPerComponent: 1 } }
    differenced = rows.map.with_index { |r, i| [bits[i * W]] + r.drop(1) }.flatten
    image = single_image(image_pdf(dict, Zlib::Deflate.deflate(pack(differenced, 1, W))))
    assert_image bits.map { |b| b * 255 }, image
  end

  def test_lzw_run_length_ascii_filters_and_chains
    gray = random_bytes(W * H)
    gray_dict = { ColorSpace: :DeviceGray, BitsPerComponent: 8 }
    {
      PdfWriter.lzw(gray) => { Filter: :LZWDecode },
      PdfWriter.lzw(gray, early_change: 0) => { Filter: :LZWDecode, DecodeParms: { EarlyChange: 0 } },
      PdfWriter.run_length(gray) => { Filter: :RunLengthDecode },
      PdfWriter.ascii_hex(gray) => { Filter: :ASCIIHexDecode },
      PdfWriter.ascii85(gray) => { Filter: :ASCII85Decode },
      PdfWriter.ascii85(Zlib::Deflate.deflate(gray)) => { Filter: %i[ASCII85Decode FlateDecode],
                                                          DecodeParms: [nil, nil] },
      PdfWriter.ascii_hex(PdfWriter.lzw(gray)) => { Filter: %i[ASCIIHexDecode LZWDecode] }
    }.each do |data, filter|
      assert_image gray.bytes, single_image(image_pdf(gray_dict.merge(filter), data)), filter.inspect
    end
    zeros = "\0".b * (W * H)
    assert_image [0] * (W * H), extract(PdfWriter.ascii85(zeros), Filter: :ASCII85Decode)
  end

  def test_lzw_across_table_resets
    big = random_bytes(200) * 400 + random_bytes(30_000)
    height = big.bytesize / 100
    image = single_image(image_pdf({ ColorSpace: :DeviceGray, BitsPerComponent: 8, Filter: :LZWDecode },
                                   PdfWriter.lzw(big), width: 100, height: height))
    assert_equal big.byteslice(0, 100 * height), image.data
  end

  def test_truncated_and_headerless_flate_data
    gray = random_bytes(W * H)
    dict = { ColorSpace: :DeviceGray, BitsPerComponent: 8, Filter: :FlateDecode }
    compressed = Zlib::Deflate.deflate(gray)
    image = single_image(image_pdf(dict, compressed.byteslice(0, compressed.bytesize / 2)))
    rows = image.data.bytes.each_slice(W).to_a
    assert_equal gray.bytes.each_slice(W).first(3), rows.first(3)
    assert_equal [255] * W, rows.last, "missing rows are white"
    raw = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
    raw_data = raw.deflate(gray, Zlib::FINISH)
    assert_image gray.bytes, single_image(image_pdf(dict, raw_data))
  end

  # --- inline images ---------------------------------------------------------

  def test_inline_images_with_abbreviations_and_filters
    gray = random_bytes(W * H)
    {
      "/W #{W} /H #{H} /BPC 8 /CS /G" => gray,
      "/W #{W} /H #{H} /BPC 8 /CS /G /F /AHx" => PdfWriter.ascii_hex(gray),
      "/W #{W} /H #{H} /BPC 8 /CS /G /F [/A85 /Fl]" => PdfWriter.ascii85(Zlib::Deflate.deflate(gray)),
      "/W #{W} /H #{H} /BPC 8 /CS /G /F /Fl" => Zlib::Deflate.deflate(gray),
      "/W #{W} /H #{H} /BPC 8 /CS /G /F /RL" => PdfWriter.run_length(gray),
      "/W #{W} /H #{H} /BPC 8 /CS /G /F /LZW /DP << /EarlyChange 1 >>" => PdfWriter.lzw(gray),
      "/Width #{W} /Height #{H} /BitsPerComponent 8 /ColorSpace /DeviceGray /L #{W * H}" => gray
    }.each do |dict, data|
      assert_image gray.bytes, single_image(inline_pdf(dict, data)), dict
    end
  end

  def test_inline_image_colour_spaces_and_masks
    palette = random_bytes(4 * 3)
    samples = Array.new(W * H) { rng.rand(4) }
    dict = "/W #{W} /H #{H} /BPC 2 /CS [/I /RGB 3 <#{palette.unpack1('H*')}>]"
    image = single_image(inline_pdf(dict, pack(samples, 2, W)))
    lumas = palette.bytes.each_slice(3).map { |r, g, b| luma(r, g, b) }
    assert_image samples.map { |s| lumas[s] }, image

    bits = Array.new(W * H) { rng.rand(2) }
    image = single_image(inline_pdf("/W #{W} /H #{H} /IM true /D [1 0]", pack(bits, 1, W)))
    assert_image bits.map { |b| b.zero? ? 255 : 0 }, image

    gray = random_bytes(W * H)
    resources = { ColorSpace: { Mine: :DeviceGray } }
    image = single_image(inline_pdf("/W #{W} /H #{H} /BPC 8 /CS /Mine", gray, resources: resources))
    assert_image gray.bytes, image
  end

  def test_inline_image_data_containing_ei
    data = ("x EI y BI z " * 100).b.byteslice(0, W * H)
    content = "BI /W #{W} /H #{H} /BPC 8 /CS /G ID ".b + data + "\nEI\nBI /W 2 /H 1 /BPC 8 /CS /G /F /AHx ID 00ff> EI".b
    images = PDF.images(PdfWriter.new.document([[content, nil]]))
    assert_equal [data.bytes, [0, 255]], images.map { |i| i.data.bytes }

    flate = Zlib::Deflate.deflate(data)
    content = "BI /W #{W} /H #{H} /BPC 8 /CS /G /F /Fl ID ".b + flate + "\nEI Q\n".b
    assert_image data.bytes, single_image(PdfWriter.new.document([[content, nil]]))
  end

  # --- content streams, forms and pages -----------------------------------

  def test_images_in_drawing_order_through_forms
    w = PdfWriter.new
    a = w.image(width: 2, height: 1, data: "\x01\x02".b)
    b = w.image(width: 2, height: 1, data: "\x03\x04".b)
    c = w.image(width: 2, height: 1, data: "\x05\x06".b)
    inner = w.add({ Type: :XObject, Subtype: :Form, BBox: [0, 0, 1, 1], Resources: { XObject: { C: c } } },
                  stream: "q /C Do Q BI /W 1 /H 1 /BPC 8 /CS /G ID \x07 EI")
    outer = w.add({ Type: :XObject, Subtype: :Form, BBox: [0, 0, 1, 1], Matrix: [1, 0, 0, 1, 5, 5] },
                  stream: "/B Do /Inner Do") # no /Resources: uses the page's
    content = ["q 1 0 0 1 0 0 cm /Outer Do Q", "% comment /A Do\n(string /A Do) Tj /A Do /A Do"]
    resources = { XObject: { A: a, B: b, Outer: outer, Inner: inner } }
    pairs = PDF.each_image(w.document([[content, resources]])).to_a
    assert_equal [[3, 4], [5, 6], [7], [1, 2]], pairs.map { |image, _| image.data.bytes }
    assert_equal ["B", "C", nil, "A"], pairs.map { |_, info| info[:name] }
  end

  def test_bands_of_one_picture_are_joined
    picture = random_bytes(50 * 30)
    w = PdfWriter.new
    strips = (0..2).map do |i|
      w.image(width: 50, height: 10, data: picture.byteslice(i * 500, 500), filter: i == 1 ? :flate : nil)
    end
    resources = { XObject: { S0: strips[0], S1: strips[1], S2: strips[2] } }
    top_down = "q 100 0 0 10 0 20 cm /S0 Do Q q 100 0 0 10 0 10 cm /S1 Do Q q 100 0 0 10 0 0 cm /S2 Do Q"
    bottom_up = "q 2 0 0 2 0 0 cm q 50 0 0 5 0 0 cm /S2 Do Q q 50 0 0 5 0 5 cm /S1 Do Q q 50 0 0 5 0 10 cm /S0 Do Q Q"
    [top_down, bottom_up].each do |content|
      pairs = PDF.each_image(w.document([[content, resources]])).to_a
      info = { page: 0, name: content == top_down ? "S0" : "S2", width: 50, height: 30, pixel_aspect: 2.0,
               dpi: [36.0, 72.0] }
      assert_equal [[picture.bytes, info]],
                   pairs.map { |image, info| [image.data.bytes, info] }
    end
    inline = "q 100 0 0 10 0 20 cm /S0 Do Q q 100 0 0 10 0 10 cm BI /W 50 /H 10 /BPC 8 /CS /G ID ".b +
             picture.byteslice(500, 500) + " EI Q".b
    images = PDF.images(w.document([[inline, resources]]))
    assert_equal [picture.byteslice(0, 1000).bytes], images.map { |i| i.data.bytes }
  end

  # Printer drivers draw strips that overlap by a row so that no gap shows:
  # the repeated row is dropped (here the strips repeat picture rows 9 and 19).
  def test_overlapping_bands_are_joined
    picture = random_bytes(50 * 30)
    w = PdfWriter.new
    strips = [[0, 10], [9, 11], [19, 11]].map do |first, rows|
      w.image(width: 50, height: rows, data: picture.byteslice(first * 50, rows * 50))
    end
    resources = { XObject: { S0: strips[0], S1: strips[1], S2: strips[2] } }
    top_down = "q 100 0 0 10 0 20 cm /S0 Do Q q 100 0 0 11 0 10 cm /S1 Do Q q 100 0 0 11 0 0 cm /S2 Do Q"
    bottom_up = "q 100 0 0 11 0 0 cm /S2 Do Q q 100 0 0 11 0 10 cm /S1 Do Q q 100 0 0 10 0 20 cm /S0 Do Q"
    [top_down, bottom_up].each do |content|
      pairs = PDF.each_image(w.document([[content, resources]])).to_a
      assert_equal [[picture.bytes, [36.0, 72.0]]], pairs.map { |image, info| [image.data.bytes, info[:dpi]] }, content
    end
    # Overlapping by more than MAX_OVERLAP_ROWS: separate images.
    content = "q 100 0 0 10 0 20 cm /S0 Do Q q 100 0 0 11 0 12 cm /S1 Do Q"
    assert_equal 2, PDF.images(w.document([[content, resources]])).size
  end

  def test_images_that_are_not_bands_stay_separate
    w = PdfWriter.new
    a = w.image(width: 50, height: 10, data: "\x01".b * 500)
    b = w.image(width: 50, height: 10, data: "\x02".b * 500)
    c = w.image(width: 40, height: 10, data: "\x03".b * 400)
    resources = { XObject: { A: a, B: b, C: c } }
    [
      "q 100 0 0 10 0 20 cm /A Do Q q 100 0 0 10 0 5 cm /B Do Q",    # gap
      "q 100 0 0 10 0 20 cm /A Do Q q 100 0 0 10 3 10 cm /B Do Q",   # shifted sideways
      "q 100 0 0 10 0 20 cm /A Do Q q 100 0 0 20 0 0 cm /B Do Q",    # other row height
      "q 100 0 0 10 0 20 cm /A Do Q q 80 0 0 10 0 10 cm /C Do Q",    # other width
      "q 100 0 0 10 0 20 cm /A Do Q q 0 10 -100 0 100 0 cm /B Do Q", # rotated
      "/A Do /B Do"                                                  # same place
    ].each do |content|
      assert_equal 2, PDF.images(w.document([[content, resources]])).size, content
    end
  end

  def test_recursive_forms_terminate
    w = PdfWriter.new
    img = w.image(width: 1, height: 1, data: "\x09".b)
    form_a = w.reserve
    form_b = w.add({ Type: :XObject, Subtype: :Form, Resources: { XObject: { A: form_a, I: img } } },
                   stream: "/A Do /I Do /B Do")
    w.set(form_a, { Type: :XObject, Subtype: :Form, Resources: { XObject: { B: form_b } } }, stream: "/B Do /B Do")
    assert_equal [[9]], PDF.images(w.document([["/A Do", { XObject: { A: form_a } }]])).map { |i| i.data.bytes }
  end

  def test_page_tree_inheritance_order_and_cycles
    w = PdfWriter.new
    images = (1..3).map { |v| w.image(width: 1, height: 1, data: v.chr) }
    root = w.reserve
    middle = w.reserve
    p1 = w.add({ Type: :Page, Parent: middle, Contents: w.add({}, stream: "/X Do") })
    draw = w.add({}, stream: "/X Do")
    p2 = w.add({ Type: :Page, Parent: middle, Contents: draw, Resources: { XObject: { X: images[1] } } })
    p3 = w.add({ Parent: root, Contents: draw, Resources: { XObject: { X: images[2] } } }) # no /Type
    w.set(middle, { Type: :Pages, Parent: root, Kids: [p1, p2, root], Resources: { XObject: { X: images[0] } } })
    w.set(root, { Type: :Pages, Kids: [middle, p3, p1], Count: 3 })
    catalog = w.add({ Type: :Catalog, Pages: root })
    pairs = PDF.each_image(w.render(root: catalog)).to_a
    assert_equal [[1], [2], [3]], pairs.map { |image, _| image.data.bytes }
    assert_equal [0, 1, 2], pairs.map { |_, info| info[:page] }
  end

  def test_same_image_once_per_page
    w = PdfWriter.new
    img = w.image(width: 1, height: 1, data: "\x05".b)
    pdf = w.document([["/I Do /J Do /I Do", { XObject: { I: img, J: img } }], ["/I Do", { XObject: { I: img } }]])
    assert_equal [0, 1], PDF.each_image(pdf).map { |_, info| info[:page] }
  end

  def test_undecodable_content_falls_back_to_page_resources
    w = PdfWriter.new
    img = w.image(width: 1, height: 1, data: "\x05".b)
    contents = w.add({ Filter: :FlateDecode }, stream: "not deflate data")
    page_tree = w.reserve
    page = w.add({ Type: :Page, Parent: page_tree, Contents: contents, Resources: { XObject: { I: img } } })
    w.set(page_tree, { Type: :Pages, Kids: [page], Count: 1 })
    assert_equal [[5]], PDF.images(w.render(root: w.add({ Type: :Catalog, Pages: page_tree }))).map { |i| i.data.bytes }
  end

  def test_images_that_cannot_be_decoded_are_skipped
    w = PdfWriter.new
    good = w.image(width: 1, height: 1, data: "\x05".b)
    jpx = w.image(width: 8, height: 8, data: "jpx".b, extra: { Filter: :JPXDecode })
    bad = w.image(width: 8, height: 8, data: "garbage".b, extra: { Filter: :DCTDecode })
    huge = w.image(width: 100_000, height: 100_000, data: "x".b)
    pdf = w.document([["/J Do /B Do /H Do /G Do", { XObject: { J: jpx, B: bad, H: huge, G: good } }]])
    assert_equal [[5]], PDF.images(pdf).map { |i| i.data.bytes }

    error = assert_raises(QrReader::ImageError) do
      PDF.images(w.document([["/J Do", { XObject: { J: jpx } }]]))
    end
    assert_match(/JPEG 2000/, error.message)
    assert_raises(QrReader::ImageError) { PDF.images(w.document([["/B Do", { XObject: { B: bad } }]])) }
  end

  # A text-only page has no images and no codes; that is not an error. Only
  # asking for "the" image of such a PDF fails.
  def test_documents_without_images
    pdf = PdfWriter.new.document([["0 0 m 100 100 l S BT /F1 12 Tf (Do) Tj ET", nil]])
    assert_empty PDF.images(pdf)
    assert_empty PDF.each_image(pdf, vector: true).to_a
    assert_empty QrReader.decode_all(StringIO.new(pdf))
    assert_nil QrReader.decode(StringIO.new(pdf))
    assert_raises(QrReader::NotFoundError) { QrReader.decode!(StringIO.new(pdf)) }
    error = assert_raises(QrReader::UnsupportedImageError) { QrReader::Formats.decode(pdf) }
    assert_match(/no raster image/, error.message)
  end

  # Garbage behind a %PDF- header has no page tree: a corrupt PDF, not an
  # empty one.
  def test_documents_without_pages
    ["%PDF-1.4 garbage", "%PDF-1.4\n%%EOF\n", "%PDF-#{"\xFF\x00" * 50}"].each do |bytes|
      error = assert_raises(QrReader::ImageError, bytes[0, 12]) { QrReader.decode_all(StringIO.new(bytes.b)) }
      refute_kind_of QrReader::UnsupportedImageError, error
      assert_match(/corrupt PDF/, error.message)
    end
  end

  # --- document structure ----------------------------------------------------

  def simple_document(value = 7, **options)
    w = PdfWriter.new
    img = w.image(width: 2, height: 1, data: [value, 255 - value].pack("C2"), filter: :flate)
    w.document([["q /Im0 Do Q", { XObject: { Im0: img } }]], **options)
  end

  def assert_simple(pdf, value = 7, message = nil)
    assert_equal [[value, 255 - value]], PDF.images(pdf).map { |i| i.data.bytes }, message
  end

  def test_cross_reference_variants
    assert_simple simple_document(xref: :table)
    assert_simple simple_document(xref: :stream)
    assert_simple simple_document(xref: :none), 7, "no xref"
    assert_simple simple_document(xref: :wrong), 7, "bogus offsets"
    assert_simple simple_document(header: "garbage before the header\n"), 7, "offsets relative to the file"
    junk = "junk\n"
    pdf = simple_document
    shifted = junk + pdf # offsets now relative to the header
    assert_simple shifted, 7, "offsets relative to the header"
    assert_simple pdf.sub(/startxref\s+\d+/, "startxref\n999999"), 7, "bad startxref"
    assert_simple pdf.sub(/xref\n0 (\d+)\n/) { "xref\n1 #{::Regexp.last_match(1)}\n" }, 7, "table starting at 1"
  end

  def test_incremental_update_replaces_objects
    w = PdfWriter.new
    img = w.image(width: 2, height: 1, data: "\x01\x02".b)
    pdf = w.document([["/Im0 Do", { XObject: { Im0: img } }]])
    root = PdfWriter::Ref.new(pdf[/Root (\d+) 0 R/, 1].to_i, 0)
    size = pdf[%r{/Size (\d+)}, 1].to_i
    image = { Type: :XObject, Subtype: :Image, Width: 2, Height: 1, ColorSpace: :DeviceGray, BitsPerComponent: 8 }
    updated = PdfWriter.update(pdf, { img => [image, "\x03\x04".b] }, root: root, size: size)
    assert_equal [[3, 4]], PDF.images(updated).map { |i| i.data.bytes }
    again = PdfWriter.update(updated, { img => [image, "\x05\x06".b] }, root: root, size: size)
    assert_equal [[5, 6]], PDF.images(again).map { |i| i.data.bytes }
  end

  def test_stream_lengths
    w = PdfWriter.new
    length = w.add(4)
    img = w.add({ Type: :XObject, Subtype: :Image, Width: 4, Height: 1, ColorSpace: :DeviceGray, BitsPerComponent: 8,
                  Length: length }, stream: "\x01\x02\x03\x04".b)
    assert_equal [[1, 2, 3, 4]], PDF.images(w.document([["/I Do", { XObject: { I: img } }]])).map { |i| i.data.bytes }

    [0, 2, 9, 1 << 40, -3, PdfWriter::Raw.new("99 0 R")].each do |bogus|
      w = PdfWriter.new
      img = w.add({ Type: :XObject, Subtype: :Image, Width: 4, Height: 1, ColorSpace: :DeviceGray, BitsPerComponent: 8,
                    Length: bogus }, stream: "\x01\x02\x03\x04".b)
      images = PDF.images(w.document([["/I Do", { XObject: { I: img } }]]))
      assert_equal [[1, 2, 3, 4]], images.map { |i| i.data.bytes }, bogus.inspect
    end
  end

  def test_truncated_document
    w = PdfWriter.new
    img = w.image(width: 4, height: 1, data: "\x01\x02\x03\x04".b)
    pdf = w.document([["/I Do", { XObject: { I: img } }]])
    cut = pdf.byteslice(0, pdf.index("xref"))
    assert_equal [[1, 2, 3, 4]], PDF.images(cut).map { |i| i.data.bytes }
  end

  def test_document_without_page_tree_yields_its_images
    w = PdfWriter.new
    w.image(width: 2, height: 1, data: "\x01\x02".b)
    w.image(width: 2, height: 1, data: "\x03\x04".b)
    pdf = w.render(root: w.add({ Type: :Catalog }))
    assert_equal [[[1, 2], 0], [[3, 4], 1]], PDF.each_image(pdf).map { |i, info| [i.data.bytes, info[:page]] }
  end

  def test_object_syntax
    w = PdfWriter.new
    # Names with #xx escapes, comments, odd whitespace, hex strings with spaces and an odd digit count.
    img = w.add_raw("<</Type/XObject/Sub#74ype /Image%comment\n/Width 3/Height 1/BitsPerComponent 8" \
                    "/ColorSpace[/Indexed/DeviceGray 2<00 7F f>]/Length 3>>stream\n\x00\x01\x02\nendstream")
    pdf = w.document([["/I#6d Do", { XObject: { Im: img } }]])
    assert_equal [[0, 127, 240]], PDF.images(pdf).map { |i| i.data.bytes }
  end

  # Literal strings: escapes, balanced parentheses, and unescaped end-of-line
  # markers (CR, CRLF), which read as a single LF.
  def test_literal_string_syntax
    lookup = "(\\101\\0\\12\\n\\r\\t\\b\\f\\(\\)\\\\\\q(x)\r\n\r\\\r\n\\\n)"
    expected = "A\x00\n\n\r\t\b\f()\\q(x)\n\n".b
    w = PdfWriter.new
    img = w.add({ Type: :XObject, Subtype: :Image, Width: expected.bytesize, Height: 1, BitsPerComponent: 8,
                  ColorSpace: [:Indexed, :DeviceGray, expected.bytesize - 1, PdfWriter::Raw.new(lookup)] },
                stream: (0...expected.bytesize).to_a.pack("C*"))
    assert_equal expected.bytes, PDF.images(w.document([["/I Do", { XObject: { I: img } }]])).first.data.bytes
  end

  # --- hostile input -----------------------------------------------------------

  def test_reference_loops_and_deep_nesting
    w = PdfWriter.new
    loop_a = w.reserve
    loop_b = w.add(loop_a)
    w.set(loop_a, loop_b)
    self_length = w.reserve
    w.set(self_length, { Type: :XObject, Subtype: :Image, Width: 1, Height: 1, ColorSpace: :DeviceGray,
                         BitsPerComponent: 8, Length: self_length }, stream: "\x05".b)
    deep = w.add_raw("[" * 10_000 + "]" * 10_000)
    resources = { XObject: { L: loop_a, S: self_length, D: deep }, ColorSpace: loop_b }
    pdf = w.document([["/L Do /D Do /S Do", resources]])
    assert_equal [[5]], PDF.images(pdf).map { |i| i.data.bytes }
  end

  def test_decompression_bombs_are_capped
    bomb = Zlib::Deflate.deflate("\0".b * 50_000_000, Zlib::BEST_COMPRESSION)
    w = PdfWriter.new
    img = w.image(width: 10, height: 10, data: bomb, extra: { Filter: :FlateDecode })
    content = w.add({ Filter: :FlateDecode }, stream: bomb)
    page_tree = w.reserve
    page = w.add({ Type: :Page, Parent: page_tree, Contents: [content, w.add({}, stream: "/I Do")],
                   Resources: { XObject: { I: img } } })
    w.set(page_tree, { Type: :Pages, Kids: [page], Count: 1 })
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    images = PDF.images(w.render(root: w.add({ Type: :Catalog, Pages: page_tree })))
    assert_equal [[0] * 100], images.map { |i| i.data.bytes }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, QrTestHelper.time_limit(5)
  end
end
