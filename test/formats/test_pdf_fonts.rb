# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/pdf/pdf_writer"

# QR codes set as text in a barcode font: the "QR blocks" test font (glyphs
# p0..p15 on A..P are 2x2 module patterns, advance 1000; see
# test/fixtures/pdf/fonts/generate.py) embedded in every font format.
class TestPdfFonts < Minitest::Test
  FONTS = File.expand_path("../fixtures/pdf/fonts", __dir__)
  TEXT = "barcode font"

  def font_file(name)
    File.binread(File.join(FONTS, name))
  end

  def matrix(text)
    QrTestHelper.rqr_matrix(text)
  end

  # Pattern number (0..15) of every 2x2 cell of +m+, row pairs top down.
  def cells(m)
    dark = ->(x, y) { x < m.width && y < m.height && m.dark?(x, y) }
    (0...m.height).step(2).map do |y|
      (0...m.width).step(2).map do |x|
        (dark.(x, y) ? 1 : 0) | (dark.(x + 1, y) ? 2 : 0) | (dark.(x, y + 1) ? 4 : 0) | (dark.(x + 1, y + 1) ? 8 : 0)
      end
    end
  end

  # Content showing +lines+ (already encoded strings) one under the other.
  def text_content(lines, size: 6, font: "/F1", x: 100, y: 600)
    "BT #{font} #{size} Tf #{size} TL 1 0 0 1 #{x} #{y} Tm\n#{lines.map { |l| "#{l} Tj T*" }.join("\n")}\nET"
  end

  # Single-byte lines: pattern n is the character "A" + n.
  def byte_lines(m)
    cells(m).map { |row| PdfWriter.serialize(row.map { |n| (0x41 + n).chr }.join) }
  end

  # Two-byte lines (Identity-H): the code is the glyph index n + 1.
  def cid_lines(m)
    cells(m).map { |row| "<#{row.map { |n| format('%04X', n + 1) }.join}>" }
  end

  def descriptor(w, key, stream_dict, data, flags: 4)
    file = w.add(stream_dict, stream: data)
    { Type: :FontDescriptor, FontName: :QRBlocks, Flags: flags, FontBBox: [0, 0, 1000, 1000], ItalicAngle: 0,
      Ascent: 1000, Descent: 0, CapHeight: 1000, StemV: 80, key => file }
  end

  def simple_font(w, subtype, descriptor, encoding)
    font = { Type: :Font, Subtype: subtype, BaseFont: :QRBlocks, FirstChar: 65, LastChar: 80,
             Widths: [1000] * 16, FontDescriptor: w.add(descriptor) }
    font[:Encoding] = encoding if encoding
    w.add(font)
  end

  def differences
    { Type: :Encoding, Differences: [65, *(0..15).map { |n| :"p#{n}" }] }
  end

  def read(w, font, content)
    QrReader.decode(w.document([[content, { Font: { F1: font } }]]))
  end

  # Nothing to read: the page draws no image and no code-like vector group.
  def assert_nothing_drawn(w, font, content, message = nil)
    assert_nil read(w, font, content), message
  end

  def test_truetype
    w = PdfWriter.new
    ttf = font_file("qrblocks.ttf")
    fd = descriptor(w, :FontFile2, { Length1: ttf.bytesize }, ttf, flags: 32)
    font = simple_font(w, :TrueType, fd, :WinAnsiEncoding)
    assert_equal TEXT, read(w, font, text_content(byte_lines(matrix(TEXT))))
  end

  def test_symbolic_truetype_through_the_mac_cmap
    w = PdfWriter.new
    ttf = font_file("qrblocks.ttf")
    font = simple_font(w, :TrueType, descriptor(w, :FontFile2, { Length1: ttf.bytesize }, ttf), nil)
    assert_equal TEXT, read(w, font, text_content(byte_lines(matrix(TEXT))))
  end

  def test_type1c_with_differences
    w = PdfWriter.new
    fd = descriptor(w, :FontFile3, { Subtype: :Type1C }, font_file("qrblocks.cff"))
    font = simple_font(w, :Type1, fd, differences)
    assert_equal TEXT, read(w, font, text_content(byte_lines(matrix(TEXT))))
  end

  def test_opentype_cff
    w = PdfWriter.new
    fd = descriptor(w, :FontFile3, { Subtype: :OpenType }, font_file("qrblocks.otf"))
    font = simple_font(w, :Type1, fd, differences)
    assert_equal TEXT, read(w, font, text_content(byte_lines(matrix(TEXT))))
  end

  def test_type1_with_its_own_encoding
    w = PdfWriter.new
    pfa = font_file("qrblocks.pfa")
    clear = pfa.index("eexec") + "eexec\n".size
    fd = descriptor(w, :FontFile, { Length1: clear, Length2: pfa.bytesize - clear, Length3: 0 }, pfa)
    font = simple_font(w, :Type1, fd, nil)
    assert_equal TEXT, read(w, font, text_content(byte_lines(matrix(TEXT))))
  end

  def type0(w, subtype, key, stream_dict, data)
    cid = { Type: :Font, Subtype: subtype, BaseFont: :QRBlocks,
            CIDSystemInfo: { Registry: "Adobe", Ordering: "Identity", Supplement: 0 },
            FontDescriptor: w.add(descriptor(w, key, stream_dict, data)), DW: 1000 }
    cid[:CIDToGIDMap] = :Identity if subtype == :CIDFontType2
    w.add({ Type: :Font, Subtype: :Type0, BaseFont: :QRBlocks, Encoding: :"Identity-H",
            DescendantFonts: [w.add(cid)] })
  end

  def test_type0_truetype_and_cff
    w = PdfWriter.new
    ttf = font_file("qrblocks.ttf")
    font = type0(w, :CIDFontType2, :FontFile2, { Length1: ttf.bytesize }, ttf)
    assert_equal TEXT, read(w, font, text_content(cid_lines(matrix(TEXT))))
    w = PdfWriter.new
    font = type0(w, :CIDFontType0, :FontFile3, { Subtype: :CIDFontType0C }, font_file("qrblocks.cff"))
    assert_equal TEXT, read(w, font, text_content(cid_lines(matrix(TEXT))))
  end

  # Glyph procedures with rectangles, a FontMatrix and glyph-space widths.
  def test_type3
    w = PdfWriter.new
    procs = (0..15).to_h do |n|
      squares = [[0, 1], [1, 1], [0, 0], [1, 0]].each_with_index.filter_map do |(col, row), bit|
        "#{col * 50} #{row * 50} 50 50 re" if n[bit] == 1
      end
      [:"p#{n}", w.add({}, stream: "100 0 0 0 100 100 d1 #{squares.join(' ')} f")]
    end
    font = w.add({ Type: :Font, Subtype: :Type3, FontBBox: [0, 0, 100, 100], FontMatrix: [0.01, 0, 0, 0.01, 0, 0],
                   CharProcs: procs, Encoding: differences, FirstChar: 65, LastChar: 80, Widths: [100] * 16 })
    assert_equal TEXT, read(w, font, text_content(byte_lines(matrix(TEXT))))
  end

  # Positioning: TJ with kerning, character spacing and horizontal scaling
  # (here cancelling out), a rotated text matrix.
  def test_text_positioning
    w = PdfWriter.new
    fd = descriptor(w, :FontFile3, { Subtype: :Type1C }, font_file("qrblocks.cff"))
    font = simple_font(w, :Type1, fd, differences)
    lines = cells(matrix(TEXT)).map do |row|
      parts = row.map { |n| PdfWriter.serialize((0x41 + n).chr) }
      "[#{parts.join(' 100 ')}] TJ T*" # each kern of 100 cancels 1 Tc
    end
    content = "BT /F1 6 Tf 6 TL 0.6 Tc 0 1 -1 0 300 200 Tm\n#{lines.join("\n")}\nET"
    assert_equal TEXT, read(w, font, content)
    # Invisible text (render mode 3, e.g. an OCR layer) draws nothing.
    content = "BT 3 Tr /F1 6 Tf 6 TL 1 0 0 1 100 600 Tm\n#{byte_lines(matrix(TEXT)).map { |l| "#{l} Tj T*" }.join("\n")}\nET"
    assert_nothing_drawn(w, font, content)
  end

  # Ordinary text (curved glyphs) is not drawn; fonts that are not embedded
  # are skipped.
  def test_ordinary_text_is_not_rendered
    w = PdfWriter.new
    ttf = font_file("qrblocks.ttf")
    font = simple_font(w, :TrueType, descriptor(w, :FontFile2, { Length1: ttf.bytesize }, ttf, flags: 32),
                       :WinAnsiEncoding)
    lines = Array.new(30) { PdfWriter.serialize("o" * 40) }
    pdf = w.document([[text_content(lines), { Font: { F1: font } }]])
    assert_empty QrReader::Formats::PDF.each_image(pdf, vector: true).to_a
    helvetica = w.add({ Type: :Font, Subtype: :Type1, BaseFont: :Helvetica })
    assert_nothing_drawn(w, helvetica, text_content(byte_lines(matrix(TEXT))))
  end

  # Broken font programs and text operators neither raise nor stop the
  # page's other drawing.
  def test_broken_fonts
    w = PdfWriter.new
    rects = "0 g 100 100 30 30 re f"
    [{ FontFile2: "garbage" }, { FontFile3: "\x01\x00\x04\x01junk" }, { FontFile: "%!PS eexec \x00\x01" }].each do |file|
      key, data = file.first
      fd = descriptor(w, key, key == :FontFile3 ? { Subtype: :Type1C } : {}, data.b)
      font = simple_font(w, :Type1, fd, nil)
      content = "#{text_content(byte_lines(matrix(TEXT)))} BT /F1 Tf (x) Tj [(a) /x 3] TJ ' \" ET #{rects}"
      assert_nothing_drawn(w, font, content, key.to_s)
    end
  end
end
