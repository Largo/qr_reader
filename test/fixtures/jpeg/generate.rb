#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates the JPEG decoder fixtures in this directory: JPEG files built
# with ImageMagick (`magick`) and libjpeg-turbo's `cjpeg` / `jpegtran`, a few
# hand-crafted variants, and reference luminance from libjpeg via Pillow
# (reference.py), stored as deflated raw 8-bit dumps (<name>.<scale>.gray.z).
# manifest.json describes every fixture for test/formats/test_jpeg.rb.
#
#   JPEG_REF_PYTHON=/path/to/venv/bin/python ruby test/fixtures/jpeg/generate.rb
#
# Development tool only; nothing here runs during the tests.

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "zlib"

DIR = __dir__
CORPUS = File.expand_path("../../corpus/zxing", DIR)
PYTHON = ENV.fetch("JPEG_REF_PYTHON", "python3")

def run(*cmd)
  out, status = Open3.capture2e(*cmd)
  raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

  out
end

# Header segments (marker, full bytes) before the first SOS, and the rest.
def split_header(jpeg)
  segments = []
  pos = 2
  loop do
    marker = jpeg.getbyte(pos + 1)
    break if marker == 0xDA

    len = jpeg.byteslice(pos + 2, 2).unpack1("n")
    segments << [marker, jpeg.byteslice(pos, len + 2)]
    pos += len + 2
  end
  [segments, jpeg.byteslice(pos..)]
end

def join_header(segments, rest)
  "\xFF\xD8".b + segments.map(&:last).join.b + rest
end

def segment(marker, payload)
  [0xFF, marker, payload.bytesize + 2].pack("CCn") + payload
end

# Splits DQT/DHT segments into one segment per table.
def split_tables(seg)
  marker = seg.getbyte(1)
  body = seg.byteslice(4..)
  tables = []
  pos = 0
  while pos < body.bytesize
    len = if marker == 0xDB
            (body.getbyte(pos) >> 4).zero? ? 65 : 129
          else
            17 + body.byteslice(pos + 1, 16).bytes.sum
          end
    tables << segment(marker, body.byteslice(pos, len))
    pos += len
  end
  tables
end

class Generator
  def initialize(tmp)
    @tmp = tmp
    @manifest = []
  end

  attr_reader :manifest

  def path(name) = File.join(DIR, "#{name}.jpg")
  def tmp(name) = File.join(@tmp, name)

  # Writes the reference dumps for fixture +name+ and records it.
  def reference(name, scales: [1, 2, 4, 8], tolerance: 0, note: nil)
    entry = { "name" => name, "file" => "#{name}.jpg", "expect" => "reference", "tolerance" => tolerance, "refs" => {} }
    entry["note"] = note if note
    scales.each do |s|
      raw = tmp("#{name}.#{s}.gray")
      w, h, cs = run(PYTHON, "-I", File.join(DIR, "reference.py"), path(name), s.to_s, raw).split
      ref = "#{name}.#{s}.gray.z"
      File.binwrite(File.join(DIR, ref), Zlib::Deflate.deflate(File.binread(raw), Zlib::BEST_COMPRESSION))
      entry["refs"][s.to_s] = { "file" => ref, "width" => w.to_i, "height" => h.to_i }
      entry["colorspace"] = cs
    end
    @manifest << entry
  end

  def same_as(name, original, note)
    @manifest << { "name" => name, "file" => "#{name}.jpg", "expect" => "same_as", "same_as" => original, "note" => note }
  end

  def unsupported(name, note)
    @manifest << { "name" => name, "file" => "#{name}.jpg", "expect" => "unsupported", "note" => note }
  end

  def decodes(name, width, height, note)
    @manifest << { "name" => name, "file" => "#{name}.jpg", "expect" => "decodes", "width" => width,
                   "height" => height, "note" => note }
  end

  def magick(name, src, *opts, **ref)
    run("magick", src, "-strip", *opts, path(name))
    reference(name, **ref)
  end

  def cjpeg(name, src, *opts, **ref)
    run("cjpeg", *opts, "-outfile", path(name), src)
    reference(name, **ref)
  end

  def jpegtran(name, src, *opts, **ref)
    run("jpegtran", *opts, "-outfile", path(name), src)
    reference(name, **ref)
  end

  def scans(name, script)
    file = tmp("#{name}.scans")
    File.write(file, script)
    file
  end

  def craft(name, bytes)
    File.binwrite(path(name), bytes)
  end
end

Dir.mktmpdir do |dir|
  FileUtils.rm_f(Dir[File.join(DIR, "*.{jpg,gray.z}")])
  g = Generator.new(dir)
  src = ->(name) { File.join(dir, name) }

  # Sources: photo-like colour plasma with noise, a few odd sizes, gray
  # versions and photos of QR codes from the ZXing corpus.
  run("magick", "-size", "96x72", "-seed", "11", "plasma:fractal", "-attenuate", "0.3", "+noise", "Gaussian",
      src["photo.ppm"])
  run("magick", "-size", "99x75", "-seed", "5", "plasma:fractal", "-blur", "0x1", src["odd.ppm"])
  run("magick", src["photo.ppm"], "-colorspace", "Gray", src["photo.pgm"])
  { "1x1" => 1, "7x13" => 2, "17x9" => 3, "33x65" => 4, "1001x3" => 5 }.each do |size, seed|
    run("magick", "-size", size, "-seed", seed.to_s, "plasma:fractal", src["s#{size}.ppm"])
  end
  run("magick", File.join(CORPUS, "qrcode-3/01.png"), "-alpha", "off", src["qr1.ppm"])
  run("magick", File.join(CORPUS, "qrcode-4/01.png"), "-alpha", "off", src["qr2.ppm"])
  run("magick", File.join(CORPUS, "qrcode-1/1.png"), "-alpha", "off", "-resize", "50%", src["qr3.ppm"])
  run("magick", File.join(CORPUS, "qrcode-2/1.png"), "-alpha", "off", "-colorspace", "Gray", src["qr4.pgm"])

  # Baseline quality sweep (4:2:0, optimised Huffman tables).
  [5, 10, 25, 50, 75, 85, 95, 100].each do |q|
    g.magick("q#{q}", src["photo.ppm"], "-quality", q.to_s, "-sampling-factor", "2x2")
  end
  g.magick("std_tables", src["photo.ppm"], "-quality", "80", "-define", "jpeg:optimize-coding=false")
  g.magick("optimized", src["photo.ppm"], "-quality", "80", "-define", "jpeg:optimize-coding=true")

  # Sampling factors (luma HxV, chroma 1x1) on an odd-sized image.
  %w[1x1 2x1 2x2 4x1 1x2 1x4 4x2 2x4 3x1 1x3 3x2].each do |s|
    g.cjpeg("sample_#{s}", src["odd.ppm"], "-quality", "85", "-sample", s)
  end
  # Subsampled luma: libjpeg upsamples Y with its "fancy" filters (scale 1).
  { "1x1,2x2,2x2" => "h2v2", "1x1,2x1,2x1" => "h2v1", "1x1,1x2,1x2" => "h1v2", "1x1,2x2,1x1" => "h2v2b",
    "1x1,3x1,3x1" => "h3v1", "1x1,2x4,1x1" => "h2v4" }.each do |s, name|
    g.cjpeg("luma_#{name}", src["odd.ppm"], "-quality", "90", "-sample", s, scales: [1])
  end
  fractional = File.binread(g.path("sample_3x1"))
  sof = fractional.index("\xFF\xC0".b)
  fractional.setbyte(sof + 11, 0x21) # Y 2x1
  fractional.setbyte(sof + 14, 0x31) # Cb 3x1 (entropy data no longer matches the layout)
  g.craft("luma_fractional", fractional)
  g.decodes("luma_fractional", 99, 75, "Y 2x1, Cb 3x1: fractional upsampling (libjpeg rejects it)")

  # Progressive.
  g.magick("prog_420", src["photo.ppm"], "-quality", "85", "-interlace", "JPEG", "-sampling-factor", "2x2")
  g.magick("prog_444", src["odd.ppm"], "-quality", "85", "-interlace", "JPEG", "-sampling-factor", "1x1")
  g.magick("prog_gray", src["photo.pgm"], "-quality", "85", "-interlace", "JPEG")
  g.cjpeg("prog_411", src["odd.ppm"], "-quality", "75", "-progressive", "-sample", "4x1")
  g.jpegtran("prog_spectral", g.path("q85"), "-scans",
             g.scans("spectral", "0,1,2: 0 0 0 0;\n0: 1 5 0 0;\n0: 6 63 0 0;\n1: 1 63 0 0;\n2: 1 63 0 0;\n"))
  g.jpegtran("prog_successive", g.path("q95"), "-scans",
             g.scans("successive", <<~SCANS))
               0,1,2: 0 0 0 2;
               0: 1 63 0 3;
               2: 1 63 0 1;
               0: 1 63 3 2;
               1: 1 63 0 1;
               0: 1 63 2 1;
               0: 1 63 1 0;
               0,1,2: 0 0 2 1;
               1: 1 63 1 0;
               2: 1 63 1 0;
               0,1,2: 0 0 1 0;
             SCANS
  g.jpegtran("prog_separate_dc", g.path("sample_2x2"), "-scans",
             g.scans("separate", "0: 0 0 0 1;\n1: 0 0 0 0;\n2: 0 0 0 0;\n0: 1 9 0 0;\n0: 0 0 1 0;\n" \
                                 "0: 10 63 0 1;\n0: 10 63 1 0;\n1: 1 63 0 0;\n2: 1 63 0 0;\n"))
  g.jpegtran("prog_gray_successive", g.path("prog_gray"), "-scans",
             g.scans("gray", "0: 0 0 0 3;\n0: 1 2 0 4;\n0: 3 63 0 4;\n0: 1 63 4 3;\n0: 0 0 3 2;\n" \
                             "0: 1 63 3 2;\n0: 0 0 2 1;\n0: 1 63 2 1;\n0: 0 0 1 0;\n0: 1 63 1 0;\n"))
  g.jpegtran("prog_restart", g.path("q75"), "-progressive", "-restart", "1B")
  g.jpegtran("prog_restart_rows", g.path("sample_2x2"), "-progressive", "-restart", "1")

  # Sequential JPEG with one non-interleaved scan per component (the 2x2 luma
  # scan covers fewer blocks than the MCU grid).
  g.jpegtran("sequential_scans", g.path("sample_2x2"), "-scans",
             g.scans("sequential", "0: 0 63 0 0;\n1: 0 63 0 0;\n2: 0 63 0 0;\n"))
  g.jpegtran("sequential_scans_restart", g.path("sample_2x2"), "-restart", "2B", "-scans",
             g.scans("sequential2", "2: 0 63 0 0;\n0: 0 63 0 0;\n1: 0 63 0 0;\n"))

  # Restart intervals.
  g.magick("restart_1", src["photo.ppm"], "-quality", "85", "-define", "jpeg:restart-interval=1")
  g.cjpeg("restart_row", src["odd.ppm"], "-quality", "85", "-restart", "1")
  g.cjpeg("restart_3b_444", src["odd.ppm"], "-quality", "85", "-restart", "3B", "-sample", "1x1")
  g.cjpeg("restart_gray", src["photo.ppm"], "-quality", "85", "-grayscale", "-restart", "5B")

  # Grayscale.
  g.magick("gray", src["photo.pgm"], "-quality", "75")
  g.magick("gray_odd", src["s33x65.ppm"], "-quality", "70", "-colorspace", "Gray")
  g.cjpeg("gray_sample_4x4", src["odd.ppm"], "-quality", "80", "-grayscale", "-sample", "4x4")

  # Colour spaces: RGB (Adobe transform 0), RGB by component ids only,
  # CMYK -> YCCK (ImageMagick's default for CMYK), plain Adobe CMYK.
  g.cjpeg("rgb", src["odd.ppm"], "-quality", "90", "-rgb")
  g.jpegtran("rgb_progressive", g.path("rgb"), "-progressive")
  header, rest = split_header(File.binread(g.path("rgb")))
  g.craft("rgb_ids", join_header(header.reject { |m, _| m == 0xEE }, rest))
  g.reference("rgb_ids", note: "RGB detected from component ids 'R','G','B' (no Adobe marker)")
  g.magick("ycck", src["photo.ppm"], "-quality", "90", "-colorspace", "CMYK", note: "Adobe YCCK (transform 2)")
  g.jpegtran("ycck_progressive", g.path("ycck"), "-progressive")
  run(PYTHON, "-I", "-c", <<~PY, src["photo.ppm"], g.path("cmyk"))
    import sys
    from PIL import Image
    Image.open(sys.argv[1]).convert("CMYK").save(sys.argv[2], quality=90)
  PY
  g.reference("cmyk", note: "Adobe CMYK (transform 0), inverted")

  # 16-bit quantisation tables (non-baseline quality 1 => SOF1).
  g.cjpeg("q1_16bit", src["photo.ppm"], "-quality", "1")
  g.cjpeg("q3_16bit_prog", src["photo.ppm"], "-quality", "3", "-progressive")

  # Odd sizes.
  %w[1x1 7x13 17x9 33x65 1001x3].each do |s|
    g.magick("size_#{s}", src["s#{s}.ppm"], "-quality", "85", "-sampling-factor", "2x2")
  end
  g.magick("size_1x1_prog", src["s1x1.ppm"], "-quality", "85", "-interlace", "JPEG")
  g.magick("size_7x13_prog", src["s7x13.ppm"], "-quality", "85", "-interlace", "JPEG")
  g.magick("size_17x9_444", src["s17x9.ppm"], "-quality", "85", "-sampling-factor", "1x1")
  g.magick("size_1001x3_gray", src["s1001x3.ppm"], "-quality", "85", "-colorspace", "Gray")

  # Photos of QR codes.
  g.magick("qr_photo1", src["qr1.ppm"], "-quality", "75", "-sampling-factor", "2x2")
  g.magick("qr_photo2", src["qr2.ppm"], "-quality", "85", "-sampling-factor", "2x1", "-interlace", "JPEG")
  g.magick("qr_photo3", src["qr3.ppm"], "-quality", "80", "-sampling-factor", "2x2")
  g.magick("qr_synthetic", src["qr4.pgm"], "-quality", "40")

  # Hand-crafted variants that must decode exactly like their source.
  base = File.binread(g.path("std_tables"))
  header, rest = split_header(base)
  g.craft("no_huffman_tables", join_header(header.reject { |m, _| m == 0xC4 }, rest))
  g.same_as("no_huffman_tables", "std_tables", "Motion-JPEG style: DHT omitted, standard tables implied")

  sof = header.index { |m, _| m == 0xC0 }
  height = header[sof][1].byteslice(5, 2)
  dnl_header = header.dup
  dnl_header[sof] = [0xC0, header[sof][1].dup.tap { |s| s[5, 2] = "\0\0".b }]
  eoi = rest.rindex("\xFF\xD9".b)
  g.craft("dnl", join_header(dnl_header, rest.byteslice(0, eoi) + "\xFF\xDC\x00\x04".b + height + "\xFF\xD9".b))
  g.same_as("dnl", "std_tables", "height 0 in SOF, given by a DNL marker after the scan")

  dqt = header.select { |m, _| m == 0xDB }.flat_map { |_, s| split_tables(s) }
  dht = header.select { |m, _| m == 0xC4 }.flat_map { |_, s| split_tables(s) }
  others = header.reject { |m, _| [0xDB, 0xC4, 0xC0].include?(m) }.map(&:last)
  com = segment(0xFE, "tables everywhere".b)
  shuffled = [*others, dht[0], com, header[sof][1], dqt.reverse, com, *dht[1..].reverse, segment(0xE5, "APP5".b)]
  g.craft("tables_anywhere", "\xFF\xD8".b + shuffled.flatten.join.b + rest)
  g.same_as("tables_anywhere", "std_tables", "one table per DHT/DQT segment, in odd places")

  r1 = File.binread(g.path("restart_row"))
  header, rest = split_header(r1)
  scan_start = rest.index("\xFF\xD0".b)
  rest = rest.byteslice(0, scan_start) + rest.byteslice(scan_start..).gsub(/\xFF([\xD0-\xD7])/n, "\xFF\xFF\xFF\\1".b)
  rest = rest.sub(/\xFF\xD9\z/n, "\xFF\xFF\xFF\xD9".b)
  g.craft("fill_bytes", join_header(header, rest).sub("\xFF\xDB".b, "\x00\x13\x37\xFF\xDB".b))
  g.same_as("fill_bytes", "restart_row", "0xFF fill bytes before RST/EOI markers, junk before a marker")

  # Unsupported variants.
  run("jpegtran", "-arithmetic", "-outfile", g.path("arithmetic"), g.path("q75"))
  g.unsupported("arithmetic", "arithmetic coding (SOF9)")
  run("jpegtran", "-arithmetic", "-progressive", "-outfile", g.path("arithmetic_progressive"), g.path("q75"))
  g.unsupported("arithmetic_progressive", "arithmetic coding (SOF10)")
  q75 = File.binread(g.path("q75"))
  g.craft("lossless", q75.sub("\xFF\xC0".b, "\xFF\xC3".b))
  g.unsupported("lossless", "SOF3 marker")
  g.craft("hierarchical", q75.sub("\xFF\xC0".b, "\xFF\xC5".b))
  g.unsupported("hierarchical", "SOF5 marker")
  twelve = q75.sub("\xFF\xC0".b, "\xFF\xC1".b)
  twelve.setbyte(twelve.index("\xFF\xC1".b) + 4, 12)
  g.craft("precision12", twelve)
  g.unsupported("precision12", "12-bit samples")

  File.write(File.join(DIR, "manifest.json"), "#{JSON.pretty_generate(g.manifest)}\n")
  total = Dir[File.join(DIR, "*")].sum { |f| File.size(f) }
  puts "#{g.manifest.size} fixtures, #{total / 1024} KiB"
end
