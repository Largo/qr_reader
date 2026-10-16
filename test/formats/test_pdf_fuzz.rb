# frozen_string_literal: true

require "test_helper"
require_relative "../fixtures/pdf/pdf_writer"
require_relative "../fixtures/pdf/jbig2_writer"

# Damaged and hostile PDFs: extraction either yields images or raises a
# QrReader::Error, never anything else, and never takes long.
class TestPdfFuzz < Minitest::Test
  DIR = File.expand_path("../fixtures/pdf", __dir__)
  PDF = QrReader::Formats::PDF
  FIXTURES = %w[magick_multipage gs_multipage qpdf_objstm qpdf_aes_256 qpdf_rc4_40 magick_gray_lzw
                magick_bilevel_fax writer_jpeg writer_jbig2_mmr qpdf_indexed_aes128].freeze

  def survive(data, label)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      PDF.each_image(data) { |image, _info| assert_equal image.width * image.height, image.data.bytesize }
    rescue QrReader::Error
      nil
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, QrTestHelper.time_limit(3), "#{label} took #{elapsed.round(2)}s"
  end

  def test_truncated_documents
    FIXTURES.each do |name|
      data = File.binread(File.join(DIR, "#{name}.pdf"))
      (1..23).each { |i| survive(data.byteslice(0, data.bytesize * i / 24), "#{name} cut #{i}/24") }
    end
  end

  def test_mutated_documents
    rng = Random.new(2024)
    FIXTURES.each do |name|
      original = File.binread(File.join(DIR, "#{name}.pdf"))
      25.times do |i|
        data = original.dup
        case i % 3
        when 0 then (1 + rng.rand(16)).times { data.setbyte(rng.rand(data.bytesize), rng.rand(256)) }
        when 1
          at = rng.rand(data.bytesize)
          data = data.byteslice(0, at) + data.byteslice(at + rng.rand(1..64), data.bytesize).to_s
        else
          at = rng.rand(data.bytesize)
          data = data.byteslice(0, at) + rng.bytes(rng.rand(1..32)) + data.byteslice(at, data.bytesize)
        end
        survive(data, "#{name} mutation #{i}")
      end
    end
  end

  def test_mutated_jbig2_streams
    rng = Random.new(77)
    bits = Array.new(120 * 90) { |i| (i % 120 / 6 + i / 720).even? && rng.rand < 0.7 ? 1 : 0 }
    stream = Jbig2Writer.stream(bits, 120, 90, typical: true)
    60.times do |i|
      data = stream.dup
      (1 + rng.rand(4)).times { data.setbyte(rng.rand(data.bytesize), rng.rand(256)) }
      data = data.byteslice(0, rng.rand(data.bytesize)) if i.odd?
      w = PdfWriter.new
      img = w.image(width: 120, height: 90, data: data, bpc: 1, extra: { Filter: :JBIG2Decode })
      survive(w.document([["/I Do", { XObject: { I: img } }]]), "jbig2 mutation #{i}")
    end
  end

  def test_hostile_syntax
    head = "%PDF-1.7\n"
    [
      head + ("[" * 200_000),
      head + ("(" * 200_000),
      head + ("<<" * 100_000),
      head + ("1 0 obj <<" * 20_000),
      head + "1 0 obj << /Length 99999999999999999999999 >> stream\nabc",
      head + "1 0 obj << /Type /Catalog /Pages 1 0 R >> endobj trailer << /Root 1 0 R >>",
      head + "xref\n0 999999999\n0000000000 65535 f \ntrailer << /Root 1 0 R /Prev 9 >>\nstartxref\n9\n%%EOF",
      head + "startxref\n-5\n%%EOF",
      head + ("1 0 R " * 50_000),
      head + ("trailer << /Root " * 10_000),
      head + "1 0 obj << /Type /ObjStm /N 999999999 /First 999999 /Length 3 >> stream\n1 0\nendstream endobj",
      head + ("1 0 obj\n" * 30_000) + "stream\n" + ("x" * 1000) + "\nendstream\n",
      head + ("%" * 100_000) + "\n"
    ].each_with_index { |data, i| survive(data.b, "hostile #{i}") }
  end

  def test_hostile_content_streams
    [
      "q " * 100_000,
      "BI " * 50_000,
      "BI /W 1 /H 1 /CS /G /BPC 8 /F /Fl ID " + ("x EI y " * 20_000),
      "/Im0 Do " * 20_000,
      "[" * 50_000,
      "1 2 3 4 5 6 cm " * 20_000 + "/Im0 Do",
      "BI /W 99999 /H 99999 /CS /G /BPC 8 ID \x00\x01 EI /Im0 Do"
    ].each_with_index do |content, i|
      w = PdfWriter.new
      img = w.image(width: 1, height: 1, data: "\x01".b)
      survive(w.document([[content.b, { XObject: { Im0: img } }]]), "content #{i}")
    end
  end

  def test_xref_prev_loop_and_self_referencing_object_stream
    w = PdfWriter.new
    img = w.image(width: 1, height: 1, data: "\x02".b)
    pdf = w.document([["/I Do", { XObject: { I: img } }]])
    start = pdf[/startxref\s+(\d+)/, 1]
    looped = pdf.sub(%r{/Root}, "/Prev #{start} /Root")
    assert_equal [[2]], PDF.images(looped).map { |i| i.data.bytes }

    w = PdfWriter.new
    stm = w.reserve
    w.set(stm, { Type: :ObjStm, N: 1, First: 4 }, stream: "#{stm.num} 0 <<>>")
    survive(w.render(root: stm), "object stream containing itself")
  end
end
