#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates the PDF fixtures in this directory:
#
#   bundle exec ruby test/fixtures/pdf/generate.rb
#
# Needs ImageMagick 7 (magick), Ghostscript (gs) and qpdf. Source images are
# synthetic and deterministic; the PDFs are written by the tools the way
# scanners and scan software write them (JPEG, CCITT G3/G4, Flate, LZW,
# RunLength, multi-page, PDF 1.5 object streams, linearized, encrypted,
# banded images). The writer-made fixtures (JPEG passthrough, string
# palettes for encryption, JBIG2) use pdf_writer.rb and jbig2_writer.rb.

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../support", __dir__)
require "open3"
require "tmpdir"
require "fileutils"
require "qr_reader"
require "qr_test_helper"
require_relative "pdf_writer"
require_relative "jbig2_writer"

DIR = __dir__
TMP = Dir.mktmpdir("qr_reader_pdf_fixtures")
at_exit { FileUtils.rm_rf(TMP) }

def path(name) = File.join(DIR, name)

def run(*cmd)
  out, status = Open3.capture2e(*cmd.map(&:to_s))
  raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?
end

def magick(*args) = run("magick", *args)

# Image -> PNG fixture (8-bit gray).
def write_gray(image, name)
  File.binwrite(path(name), QrTestHelper.png_bytes(image))
end

def qr_image(text, module_size:, quiet: 4, level: :m)
  QrTestHelper.render(QrTestHelper.rqr_matrix(text, level: level), module_size: module_size, quiet: quiet)
end

# Places +src+ onto a white canvas at (x, y).
def place(src, width, height, x, y, background: 255)
  data = background.chr.b * (width * height)
  src.height.times { |r| data[(y + r) * width + x, src.width] = src.row(r) }
  QrReader::Image.new(width, height, data)
end

# --- sources -------------------------------------------------------------

# 8-bit gray with gradients in both module colours (lossless checks need
# many distinct levels).
qr = qr_image("PDF gray fixture", module_size: 4)
gray = place(qr, 150, 140, 9, 4)
data = gray.data.dup
data.bytesize.times do |i|
  x = i % 150
  y = i / 150
  v = data.getbyte(i)
  data.setbyte(i, v < 128 ? (x + y) % 61 : 180 + ((x * 3 + y) % 76))
end
gray = QrReader::Image.new(150, 140, data)
write_gray(gray, "src_gray.png")

# Bilevel, width not a multiple of 8.
bilevel = place(qr_image("PDF bilevel fixture", module_size: 3, level: :q), 203, 190, 50, 40)
write_gray(bilevel, "src_bilevel.png")
magick path("src_bilevel.png"), "-type", "bilevel", path("src_bilevel.png")

# Colour: dark blue modules on light yellow, with a red stripe.
qr = place(qr_image("PDF rgb fixture", module_size: 4), 150, 140, 12, 4)
rgb = String.new(encoding: Encoding::BINARY)
qr.data.each_byte.with_index do |v, i|
  x = i % 150
  rgb << (if x < 6 then [220, 30, 40]
          elsif v < 128 then [20 + x % 16, 30, 110]
          else [250, 240 - x % 32, 170]
          end).pack("C3")
end
File.binwrite(File.join(TMP, "rgb.ppm"), "P6\n150 140\n255\n".b + rgb)
magick File.join(TMP, "rgb.ppm"), path("src_rgb.png")

# A4 page scanned at 100 dpi, bilevel, with "text" lines and a QR code.
rng = Random.new(7)
page = QrReader::Image.new(827, 1169, "\xFF".b * (827 * 1169))
pdata = page.data
(80..700).step(22).each do |y|
  x = 70
  while x < 750
    w = rng.rand(12..60)
    h = rng.rand(7..11)
    h.times { |dy| pdata[(y + dy) * 827 + x, w] = "\0".b * w }
    x += w + rng.rand(6..12)
  end
end
code = qr_image("Scanned page fixture", module_size: 4)
code.height.times { |r| pdata[(850 + r) * 827 + 560, code.width] = code.row(r) }
write_gray(QrReader::Image.new(827, 1169, pdata), "src_page.png")
magick path("src_page.png"), "-type", "bilevel", path("src_page.png")

# A gray photo-like scan stored as JPEG.
scan = place(qr_image("JPEG scan fixture", module_size: 5), 320, 300, 70, 60)
scan = QrTestHelper.add_noise(QrTestHelper.blur(scan, 1), 12, seed: 3)
File.binwrite(File.join(TMP, "scan.png"), QrTestHelper.png_bytes(scan))
magick File.join(TMP, "scan.png"), "-quality", "80", "-sampling-factor", "1x1", path("src_scan.jpg")

# --- ImageMagick PDFs ----------------------------------------------------

%w[Zip LZW RLE None JPEG].each do |compress|
  magick path("src_gray.png"), "-compress", compress, path("magick_gray_#{compress.downcase}.pdf")
end
%w[Group4 Fax Zip].each do |compress|
  magick path("src_bilevel.png"), "-compress", compress, path("magick_bilevel_#{compress.downcase}.pdf")
end
magick path("src_rgb.png"), "-compress", "Zip", path("magick_rgb_zip.pdf")
magick path("src_rgb.png"), "-compress", "JPEG", "-quality", "90", path("magick_rgb_jpeg.pdf")
magick path("src_rgb.png"), "-colorspace", "CMYK", "-compress", "Zip", path("magick_cmyk_zip.pdf")
magick path("src_rgb.png"), "-colorspace", "CMYK", "-compress", "JPEG", "-quality", "90",
       path("magick_cmyk_jpeg.pdf")
magick path("src_rgb.png"), "-colors", "16", "-type", "Palette", "-compress", "Zip", path("magick_palette_zip.pdf")
magick path("src_page.png"), "-compress", "Group4", "-units", "PixelsPerInch", "-density", "100",
       path("magick_page_group4.pdf")
magick path("src_gray.png"), "(", path("src_bilevel.png"), "-compress", "Group4", ")",
       "(", path("src_rgb.png"), ")", "-compress", "Zip", path("magick_multipage.pdf")

# --- Ghostscript: PDF 1.5 with object streams and a cross-reference stream

run "gs", "-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5",
    "-dAutoFilterGrayImages=false", "-dGrayImageFilter=/FlateEncode", "-dDownsampleGrayImages=false",
    "-dAutoFilterColorImages=false", "-dColorImageFilter=/FlateEncode", "-dDownsampleColorImages=false",
    "-dDownsampleMonoImages=false", "-dEncodeMonoImages=true", "-dMonoImageFilter=/CCITTFaxEncode",
    "-sOutputFile=#{path('gs_multipage.pdf')}", path("magick_multipage.pdf")

# --- Ghostscript: an image printed in bands (as PostScript printer drivers do)

ps = +"%!PS-Adobe-3.0\n<< /PageSize [300 300] >> setpagedevice\n"
y = 0
while y < gray.height
  rows = [37, gray.height - y].min
  hex = gray.data.byteslice(y * gray.width, rows * gray.width).unpack1("H*")
  ps << "gsave 20 #{20 + (gray.height - y - rows) * 1.5} translate #{gray.width * 1.5} #{rows * 1.5} scale\n"
  ps << "#{gray.width} #{rows} 8 [#{gray.width} 0 0 -#{rows} 0 #{rows}] {<#{hex}>} image grestore\n"
  y += rows
end
File.write(File.join(TMP, "bands.ps"), ps << "showpage\n")
run "gs", "-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite", "-dAutoFilterGrayImages=false",
    "-dGrayImageFilter=/FlateEncode", "-sOutputFile=#{path('gs_bands.pdf')}", File.join(TMP, "bands.ps")

# --- qpdf: object streams, linearization, encryption -----------------------

base = path("magick_multipage.pdf")
run "qpdf", "--object-streams=generate", base, path("qpdf_objstm.pdf")
run "qpdf", "--linearize", base, path("qpdf_linearized.pdf")
run "qpdf", "--allow-weak-crypto", "--encrypt", "", "owner", "40", "--", base, path("qpdf_rc4_40.pdf")
run "qpdf", "--allow-weak-crypto", "--encrypt", "", "owner", "128", "--use-aes=n", "--", base,
    path("qpdf_rc4_128.pdf")
run "qpdf", "--encrypt", "", "owner", "128", "--use-aes=y", "--", "--object-streams=generate", base,
    path("qpdf_aes_128.pdf")
run "qpdf", "--encrypt", "", "owner", "256", "--", "--object-streams=generate", base, path("qpdf_aes_256.pdf")
run "qpdf", "--encrypt", "", "owner", "256", "--force-R5", "--", base, path("qpdf_aes_256_r5.pdf")
run "qpdf", "--encrypt", "secret", "owner", "256", "--", base, path("qpdf_user_password.pdf")

# --- Writer-made: a JPEG scan embedded verbatim -----------------------------

w = PdfWriter.new
jpeg = File.binread(path("src_scan.jpg"))
width, height = QrReader::Formats::JPEG.dimensions(jpeg)
img = w.image(width: width, height: height, data: jpeg, extra: { Filter: :DCTDecode })
File.binwrite(path("writer_jpeg.pdf"),
              w.document([["q #{width} 0 0 #{height} 0 0 cm /Im0 Do Q", { XObject: { Im0: img } }]]))

# --- Writer-made: an Indexed image whose palette is a string, encrypted -----
# (strings are encrypted separately from streams)

w = PdfWriter.new
palette = (0..255).map { |i| (i * 37 + 11) % 256 }.pack("C*") # contains ( ) \ CR LF
indices = (0...(64 * 48)).map { |i| (i * 7 + i / 64) % 256 }.pack("C*")
img = w.image(width: 64, height: 48, data: indices, filter: :flate,
              color_space: [:Indexed, :DeviceGray, 255, palette])
File.binwrite(path("writer_indexed.pdf"), w.document([["q 64 0 0 48 0 0 cm /Im0 Do Q", { XObject: { Im0: img } }]]))
run "qpdf", "--allow-weak-crypto", "--encrypt", "", "owner", "128", "--use-aes=n", "--", path("writer_indexed.pdf"),
    path("qpdf_indexed_rc4.pdf")
run "qpdf", "--encrypt", "", "owner", "128", "--use-aes=y", "--", path("writer_indexed.pdf"),
    path("qpdf_indexed_aes128.pdf")
run "qpdf", "--encrypt", "", "owner", "256", "--", path("writer_indexed.pdf"), path("qpdf_indexed_aes256.pdf")

# --- Writer-made: JBIG2 (no JBIG2 encoder tool is available; jbig2_writer.rb
# was checked against Ghostscript's jbig2dec) --------------------------------

def jbig2_pdf(stream, width, height, image_mask: false)
  w = PdfWriter.new
  extra = { Filter: :JBIG2Decode }
  extra = extra.merge(ImageMask: true) if image_mask
  img = w.image(width: width, height: height, data: stream, bpc: 1, color_space: image_mask ? nil : :DeviceGray,
                extra: extra)
  w.document([["q #{width} 0 0 #{height} 0 0 cm /Im0 Do Q", { XObject: { Im0: img } }]])
end

page_image = QrReader::Formats::PNG.decode(File.binread(path("src_page.png")))
page_bits = page_image.data.bytes.map { |v| v < 128 ? 1 : 0 }
File.binwrite(path("writer_jbig2_page.pdf"),
              jbig2_pdf(Jbig2Writer.stream(page_bits, page_image.width, page_image.height, typical: true),
                        page_image.width, page_image.height, image_mask: true))
# The G4 data of the bilevel fixture (ImageMagick writes the image as object 8).
g4, = Open3.capture2("qpdf", "--show-object=8", "--raw-stream-data", path("magick_bilevel_group4.pdf"),
                     binmode: true)
mmr = Jbig2Writer.segment(0, 48, Jbig2Writer.page_information(203, 190)) +
      Jbig2Writer.segment(1, 38, Jbig2Writer.generic_region(203, 190, mmr_data: g4))
File.binwrite(path("writer_jbig2_mmr.pdf"), jbig2_pdf(mmr, 203, 190))

total = Dir[path("*")].sum { |f| File.size(f) }
puts "fixtures: #{Dir[path('*.pdf')].size} PDFs, #{total / 1024} KB in total"
