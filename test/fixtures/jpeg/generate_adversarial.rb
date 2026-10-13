#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates the adversarial JPEG fixtures (adv_*) used by
# test/formats/test_jpeg_adversarial.rb: corner cases found by differential
# fuzzing against libjpeg-turbo, encoded with libjpeg-turbo's `cjpeg` /
# `jpegtran`, ImageMagick (`magick`) and Pillow, with reference luminance
# from libjpeg via Pillow (reference.py), stored like generate.rb does
# (<name>.<scale>.gray.z). adversarial.json describes every fixture.
#
#   JPEG_REF_PYTHON=/path/to/venv/bin/python ruby test/fixtures/jpeg/generate_adversarial.rb
#
# Development tool only; nothing here runs during the tests.

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "zlib"

DIR = __dir__
PYTHON = ENV.fetch("JPEG_REF_PYTHON", "python3")

def run(*cmd)
  out, status = Open3.capture2e(*cmd)
  raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

  out
end

# Deterministic test picture: gradients, sharp module-like edges and noise.
def picture(path, width, height, gray: false, seed: 1)
  rng = Random.new(seed)
  data = String.new(capacity: width * height * 3, encoding: Encoding::BINARY)
  height.times do |y|
    width.times do |x|
      dark = ((x / 3) + (y / 4)).odd? && (x * 7 + y * 3) % 11 < 6
      base = [40 + 3 * x + y, 200 - 2 * y + x, 90 + x * y % 120].map { |v| dark ? v / 4 : v }
      base = [base.sum / 3] * 3 if gray
      base.each { |v| data << (v + rng.rand(-12..12)).clamp(0, 255) }
    end
  end
  data = data.bytes.each_slice(3).map(&:first).pack("C*") if gray
  File.binwrite(path, "#{gray ? 'P5' : 'P6'}\n#{width} #{height}\n255\n".b + data)
end

def segment(marker, payload)
  [0xFF, marker, payload.bytesize + 2].pack("CCn") + payload
end

class Generator
  attr_reader :manifest

  def initialize(tmp)
    @tmp = tmp
    @manifest = []
  end

  def path(name) = File.join(DIR, "#{name}.jpg")
  def tmp(name) = File.join(@tmp, name)

  # References at every scale libjpeg (via Pillow or djpeg) can produce.
  def reference(name, note)
    entry = { "name" => name, "file" => "#{name}.jpg", "expect" => "reference", "note" => note, "refs" => {} }
    [1, 2, 4, 8].each do |s|
      raw = tmp("#{name}.#{s}.gray")
      out, status = Open3.capture2e(PYTHON, "-I", File.join(DIR, "reference.py"), path(name), s.to_s, raw)
      next unless status.success? # tiny RGB/CMYK images: no reference below 1 pixel

      w, h, cs = out.split
      ref = "#{name}.#{s}.gray.z"
      File.binwrite(File.join(DIR, ref), Zlib::Deflate.deflate(File.binread(raw), Zlib::BEST_COMPRESSION))
      entry["refs"][s.to_s] = { "file" => ref, "width" => w.to_i, "height" => h.to_i }
      entry["colorspace"] = cs
    end
    raise "no reference for #{name}" if entry["refs"].empty?

    @manifest << entry
  end

  def cjpeg(name, src, *opts, note:)
    run("cjpeg", *opts, "-outfile", path(name), src)
    reference(name, note)
  end

  def jpegtran(name, src, *opts, note:)
    run("jpegtran", *opts, "-outfile", path(name), src)
    reference(name, note)
  end

  def magick(name, src, *opts, note:)
    run("magick", src, "-strip", *opts, path(name))
    reference(name, note)
  end

  def craft(name, bytes, note)
    File.binwrite(path(name), bytes)
    reference(name, note)
  end

  def script(name, text)
    file = tmp("#{name}.scans")
    File.write(file, text)
    file
  end
end

# Random valid progressive scripts (successive approximation up to Al = 3,
# interleaved and separate DC refinement, bands in random order), produced
# by the differential fuzzer and checked by cjpeg.
SCRIPT_COLOUR = <<~SCANS
  0,1,2: 0 0 0 3;
  1: 22 63 0 3;
  0,1,2: 0 0 3 2;
  2: 1 3 0 0;
  2: 4 11 0 3;
  1: 22 63 3 2;
  0: 1 24 0 3;
  0: 25 50 0 1;
  0,1,2: 0 0 2 1;
  2: 4 11 3 2;
  1: 20 21 0 1;
  0,1,2: 0 0 1 0;
  0: 51 63 0 3;
  1: 20 21 1 0;
  0: 51 63 3 2;
  0: 1 24 3 2;
  2: 12 63 0 3;
  1: 22 63 2 1;
  1: 22 63 1 0;
  2: 4 11 2 1;
  2: 4 11 1 0;
  1: 3 19 0 3;
  0: 51 63 2 1;
  1: 3 19 3 2;
  0: 25 50 1 0;
  1: 1 2 0 1;
  0: 1 24 2 1;
  0: 1 24 1 0;
  1: 1 2 1 0;
  2: 12 63 3 2;
  2: 12 63 2 1;
  2: 12 63 1 0;
  1: 3 19 2 1;
  1: 3 19 1 0;
  0: 51 63 1 0;
SCANS
SCRIPT_GRAY = <<~SCANS
  0: 0 0 0 3;
  0: 1 59 0 1;
  0: 1 59 1 0;
  0: 60 63 0 3;
  0: 0 0 3 2;
  0: 60 63 3 2;
  0: 0 0 2 1;
  0: 60 63 2 1;
  0: 60 63 1 0;
  0: 0 0 1 0;
SCANS
SCRIPT_BANDS = <<~SCANS
  0,1,2: 0 0 0 0;
  2: 56 63 0 0;
  1: 1 9 0 1;
  2: 1 12 0 2;
  1: 10 50 0 3;
  1: 57 63 0 3;
  2: 1 12 2 1;
  0: 43 63 0 3;
  1: 57 63 3 2;
  2: 1 12 1 0;
  2: 13 55 0 2;
  2: 13 55 2 1;
  2: 13 55 1 0;
  1: 1 9 1 0;
  0: 43 63 3 2;
  0: 32 42 0 0;
  0: 1 4 0 3;
  1: 57 63 2 1;
  0: 1 4 3 2;
  0: 1 4 2 1;
  1: 57 63 1 0;
  0: 1 4 1 0;
  0: 43 63 2 1;
  0: 43 63 1 0;
  1: 51 56 0 3;
  0: 5 31 0 3;
  0: 5 31 3 2;
  0: 5 31 2 1;
  1: 10 50 3 2;
  0: 5 31 1 0;
  1: 51 56 3 2;
  1: 51 56 2 1;
  1: 10 50 2 1;
  1: 51 56 1 0;
  1: 10 50 1 0;
SCANS

Dir.mktmpdir do |dir|
  FileUtils.rm_f(Dir[File.join(DIR, "adv_*")])
  g = Generator.new(dir)
  src = ->(name) { File.join(dir, name) }
  picture(src["p.ppm"], 61, 47, seed: 1)
  picture(src["p.pgm"], 61, 47, gray: true, seed: 2)
  { "1x23" => 3, "3x17" => 4, "5x9" => 5, "6x5" => 6 }.each do |size, seed|
    w, h = size.split("x").map(&:to_i)
    picture(src["s#{size}.ppm"], w, h, seed: seed)
  end

  # Subsampled components of RGB / CMYK / YCCK images are part of the
  # luminance: libjpeg decodes them with larger IDCTs at reduced scales and
  # upsamples with its fancy filters only for DCT sizes > 1 and widths > 2.
  g.cjpeg("adv_rgb_420", src["p.ppm"], "-rgb", "-quality", "90", "-sample", "2x2,1x1,1x1",
          note: "RGB, G and B subsampled 2x2")
  g.cjpeg("adv_rgb_h1v2_prog", src["p.ppm"], "-rgb", "-quality", "85", "-sample", "1x2,1x1,1x1", "-progressive",
          note: "RGB, G and B subsampled vertically (h1v2), progressive")
  g.cjpeg("adv_rgb_w1", src["s1x23.ppm"], "-rgb", "-quality", "95", "-sample", "2x2,1x1,1x1",
          note: "1 pixel wide: subsampled width 1, plain replication")
  g.cjpeg("adv_rgb_w3", src["s3x17.ppm"], "-rgb", "-quality", "95", "-sample", "2x2,1x1,1x1",
          note: "3 pixels wide: subsampled width 2, plain replication")
  g.cjpeg("adv_rgb_w5", src["s5x9.ppm"], "-rgb", "-quality", "95", "-sample", "2x1,1x1,1x1",
          note: "5 pixels wide: subsampled width 3, fancy h2v1")
  g.cjpeg("adv_rgb_w6_v2", src["s6x5.ppm"], "-rgb", "-quality", "95", "-sample", "1x2,1x1,1x1",
          note: "h1v2 is fancy at any width")
  g.magick("adv_ycck_420", src["p.ppm"], "-quality", "85", "-colorspace", "CMYK", "-sampling-factor", "2x2",
           note: "YCCK with K subsampled 2x2")
  g.magick("adv_ycck_422_prog", src["p.ppm"], "-quality", "80", "-colorspace", "CMYK", "-sampling-factor", "2x1",
           "-interlace", "JPEG", note: "progressive YCCK, 2x1")
  g.magick("adv_ycck_420_prog", src["p.ppm"], "-quality", "80", "-colorspace", "CMYK", "-sampling-factor", "2x2",
           "-interlace", "JPEG", note: "progressive YCCK, K subsampled 2x2: 2x2 IDCT with AC scans at scale 8")
  g.cjpeg("adv_rgb_420_prog_restart", src["p.ppm"], "-rgb", "-quality", "80", "-sample", "2x2,1x1,1x1",
          "-progressive", "-restart", "3B", note: "progressive RGB, G and B subsampled, restart intervals")

  # Subsampled luma (Y smaller than the chroma): exact at every scale.
  g.cjpeg("adv_luma_sub_2x2", src["p.ppm"], "-quality", "90", "-sample", "1x1,2x2,2x2",
          note: "Y 1x1, chroma 2x2")
  g.cjpeg("adv_luma_sub_4x1", src["p.ppm"], "-quality", "90", "-sample", "1x1,4x1,4x1",
          note: "Y 1x1, chroma 4x1 (ratio 4)")
  g.cjpeg("adv_luma_sub_1x4_prog", src["p.ppm"], "-quality", "90", "-sample", "1x1,1x4,1x4", "-progressive",
          note: "Y 1x1, chroma 1x4, progressive")

  # Progressive scripts: successive approximation in every order.
  g.cjpeg("adv_prog_script_420", src["p.ppm"], "-quality", "60", "-sample", "2x2,1x1,1x1",
          "-scans", g.script("colour", SCRIPT_COLOUR), note: "35 scans, Al up to 3, interleaved DC refinement")
  g.cjpeg("adv_prog_script_gray", src["p.pgm"], "-quality", "80", "-grayscale",
          "-scans", g.script("gray", SCRIPT_GRAY), note: "gray, bands refined out of order")
  g.cjpeg("adv_prog_script_16bit", src["p.ppm"], "-quality", "4", "-sample", "1x1,1x1,1x1",
          "-scans", g.script("bands", SCRIPT_BANDS), note: "16-bit quantisation tables, spectral bands")
  g.jpegtran("adv_prog_script_restart", g.path("adv_prog_script_420"), "-restart", "2B",
             note: "the 35-scan script with restart intervals of 2 blocks")

  # Sequential oddities.
  g.cjpeg("adv_restart_7b", src["p.ppm"], "-quality", "75", "-sample", "2x2,1x1,1x1", "-restart", "7B",
          note: "restart interval that does not divide the MCU rows")
  g.cjpeg("adv_two_of_three", src["p.ppm"], "-quality", "75", "-sample", "2x2,1x1,1x1",
          "-scans", g.script("two", "0,1: 0 63 0 0;\n2: 0 63 0 0;\n"), note: "interleaved Y+Cb scan, then Cr")

  # Marker-level crafting, decoded by libjpeg for the reference.
  rgb = File.binread(g.path("adv_rgb_420"))
  jfif = segment(0xE0, "JFIF\0\x01\x01\x00\x00\x01\x00\x01\x00\x00".b)
  g.craft("adv_jfif_rgb", rgb.byteslice(0, 2) + jfif + rgb.byteslice(2..),
          "RGB data with Adobe transform 0 and a JFIF marker: libjpeg says YCbCr")
  base = File.binread(g.path("adv_restart_7b"))
  sof = base.index("\xFF\xC0".b)
  sos = base.index("\xFF\xDA".b)
  dup = base.dup
  [sof + 10, sof + 13, sof + 16].each { |p| dup.setbyte(p, 1) }
  [sos + 5, sos + 7, sos + 9].each { |p| dup.setbyte(p, 1) }
  g.craft("adv_dup_ids", dup, "all three component ids are 1 (in SOF and SOS)")

  File.write(File.join(DIR, "adversarial.json"), "#{JSON.pretty_generate(g.manifest)}\n")
  total = Dir[File.join(DIR, "adv_*")].sum { |f| File.size(f) }
  puts "#{g.manifest.size} fixtures, #{total / 1024} KiB"
end
