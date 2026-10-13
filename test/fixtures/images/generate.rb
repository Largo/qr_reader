#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates the image-format fixtures in this directory (development only):
#
#   PILLOW_PYTHON=/path/to/venv/bin/python bundle exec ruby test/fixtures/images/generate.rb
#
# Needs ImageMagick 7 (`magick`), Python with Pillow (PILLOW_PYTHON, default
# `python3`, always run with -I) and the rqrcode_core dev dependency.
#
# Every fixture is written by a real encoder (ImageMagick or Pillow), or
# crafted from one where no encoder writes the variant (RLE4, top-down rows,
# odd BMP masks, comments in PNM headers, ...). Reference pixels are
# ImageMagick's decoding of the fixture as 8-bit RGBA (GIFs flattened onto a
# white canvas), stored zlib-compressed and deduplicated as ref_<digest>.rgba.z;
# manifest.json maps each fixture to its size and reference. Pillow decodes
# every fixture too, and any disagreement in luminance is reported.
#
# zxing_png_luma.txt holds, for every PNG of the ZXing corpus, the SHA-256 of
# its expected luminance (Pillow's RGBA decoding through Image.from_pixels).

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "zlib"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "qr_reader" # Image.from_pixels only: the luminance semantics under test
require "rqrcode_core"

module FixtureGenerator
  DIR = __dir__
  CORPUS = File.expand_path("../../corpus/zxing", __dir__)
  PYTHON = ENV.fetch("PILLOW_PYTHON", "python3")

  # Pillow helper: decodes each file to RGBA (GIF frame 0 composited on a
  # white canvas; 16-bit gray scaled to 8 bits) into OUT/<index>.rgba.
  PILLOW_DECODE = <<~PY
    import sys
    from PIL import Image
    out = sys.argv[1]
    for i, path in enumerate(sys.argv[2:]):
        try:
            im = Image.open(path)
            im.seek(0)
            if im.format == "GIF":
                rgba = im.convert("RGBA")
                canvas = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
                canvas.alpha_composite(rgba)
                rgba = canvas
            elif im.mode.startswith("I"):
                rgba = im.convert("I").point(lambda v: v * (1 / 257) + 0.5).convert("L").convert("RGBA")
            else:
                rgba = im.convert("RGBA")
            with open(f"{out}/{i}.rgba", "wb") as f:
                f.write(rgba.tobytes())
            print(i, rgba.size[0], rgba.size[1], flush=True)
        except Exception as e:
            print(i, "error", repr(e).replace("\\n", " "), flush=True)
  PY

  module_function

  def run
    Dir.mktmpdir do |tmp|
      @tmp = tmp
      write_sources
      clean
      fixtures = build_fixtures
      manifest = write_references(fixtures)
      File.write(File.join(DIR, "manifest.json"), "#{JSON.pretty_generate(manifest)}\n")
      cross_check(manifest)
      write_corpus_digests if Dir.exist?(CORPUS)
      total = Dir[File.join(DIR, "*")].sum { |f| File.size(f) }
      puts "#{manifest.size} fixtures, #{total / 1024} KiB in #{DIR}"
    end
  end

  def clean
    Dir[File.join(DIR, "*")].each { |f| File.delete(f) unless f.end_with?(".rb") }
  end

  def tmp(name) = File.join(@tmp, name)
  def out(name) = File.join(DIR, name)

  # Runs ImageMagick; PNG timestamps are left out so output is reproducible.
  def magick(input, *args)
    system("magick", input, "-define", "png:exclude-chunk=date,time,tIME", *args, exception: true)
  end

  def pillow(code, *args)
    output, status = Open3.capture2(PYTHON, "-I", "-c", code, *args)
    raise "Pillow failed: #{code}" unless status.success?

    output
  end

  # --- source images ----------------------------------------------------------

  # 41x29 RGBA test pattern (odd sizes exercise row padding): gradients,
  # pseudo-random blue, an alpha ramp on the left and a transparent corner.
  # Plus a 160x120 smooth "photo" and a QR code.
  def write_sources
    w = 41
    h = 29
    rgba = String.new(encoding: Encoding::BINARY)
    seed = 12_345
    h.times do |y|
      w.times do |x|
        seed = (seed * 1_103_515_245 + 12_345) & 0x7fffffff
        alpha = if x < 10 then x * 28
                elsif x > 30 && y > 18 then 0
                else 255
                end
        rgba << [x * 255 / (w - 1), y * 255 / (h - 1), ((x ^ y) * 37 + (seed >> 16)) & 255, alpha].pack("C4")
      end
    end
    write_pam(tmp("src_rgba.pam"), w, h, rgba)
    magick(tmp("src_rgba.pam"), "PNG32:#{tmp('src_rgba.png')}")
    magick(tmp("src_rgba.pam"), "-alpha", "off", "PNG24:#{tmp('src_rgb.png')}")
    # 8-bit gray versions, so that 16-bit fixtures hold exact multiples of 257.
    magick(tmp("src_rgb.png"), "-colorspace", "gray", "-depth", "8", "-define", "png:color-type=0", tmp("src_gray.png"))
    magick(tmp("src_rgba.png"), "-colorspace", "gray", "-depth", "8", "-define", "png:color-type=4", tmp("src_ga.png"))

    pw = 160
    ph = 120
    photo = String.new(encoding: Encoding::BINARY)
    ph.times do |y|
      pw.times do |x|
        seed = (seed * 1_103_515_245 + 12_345) & 0x7fffffff
        r = (128 + 100 * Math.sin(x / 13.0) * Math.cos(y / 17.0)).round
        g = (x + y) * 255 / (pw + ph)
        b = (128 + 90 * Math.sin((x * x + y * y) / 900.0) + (seed >> 27)).round.clamp(0, 255)
        a = x > 120 ? 255 - (x - 120) * 6 : 255
        photo << [r, g, b, a].pack("C4")
      end
    end
    write_pam(tmp("photo_rgba.pam"), pw, ph, photo)
    magick(tmp("photo_rgba.pam"), "PNG32:#{tmp('photo_rgba.png')}")
    magick(tmp("photo_rgba.pam"), "-alpha", "off", "PNG24:#{tmp('photo_rgb.png')}")

    qr = RQRCodeCore::QRCode.new("https://example.com/qr_reader/formats", level: :m)
    n = qr.modules.size
    pbm = "P1\n#{n + 8} #{n + 8}\n".b
    (n + 8).times do |y|
      row = (n + 8).times.map { |x| x.between?(4, n + 3) && y.between?(4, n + 3) && qr.modules[y - 4][x - 4] }
      pbm << row.map { |dark| dark ? "1" : "0" }.join(" ") << "\n"
    end
    File.binwrite(tmp("qr.pbm"), pbm)
    magick(tmp("qr.pbm"), "-scale", "400%", "PNG8:#{tmp('qr.png')}")
  end

  def write_pam(path, w, h, rgba)
    File.binwrite(path, "P7\nWIDTH #{w}\nHEIGHT #{h}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n".b + rgba)
  end

  # --- fixtures ---------------------------------------------------------------

  # Returns { fixture name => reference source file (usually itself) }.
  def build_fixtures
    fixtures = {}
    add = ->(name, ref = name) { fixtures[name] = ref }
    rgb = tmp("src_rgb.png")
    rgba = tmp("src_rgba.png")

    # PNG: every colour type and bit depth, plain and Adam7, from ImageMagick.
    gray_src = tmp("src_gray.png")
    gray_levels = { 1 => %w[-threshold 50%], 2 => %w[-posterize 4], 4 => %w[-posterize 16], 8 => [],
                    16 => %w[-depth 16] }
    gray_levels.each do |depth, opts|
      ["", "_adam7"].each do |suffix|
        name = "png_gray#{depth}#{suffix}.png"
        il = suffix.empty? ? [] : %w[-interlace PNG]
        magick(gray_src, *opts, *il, "-define", "png:color-type=0", "-define", "png:bit-depth=#{depth}", out(name))
        add.(name)
      end
    end
    { "gray_alpha8" => ["-define", "png:color-type=4", "-define", "png:bit-depth=8"],
      "gray_alpha16" => ["-depth", "16", "-define", "png:color-type=4", "-define", "png:bit-depth=16"],
      "rgb8" => ["-alpha", "off", "-define", "png:color-type=2", "-define", "png:bit-depth=8"],
      "rgb16" => ["-alpha", "off", "-depth", "16", "-define", "png:color-type=2", "-define", "png:bit-depth=16"],
      "rgba8" => ["-define", "png:color-type=6", "-define", "png:bit-depth=8"],
      "rgba16" => ["-depth", "16", "-define", "png:color-type=6", "-define", "png:bit-depth=16"] }.each do |kind, opts|
      src = kind.start_with?("gray") ? tmp("src_ga.png") : rgba
      magick(src, *opts, out("png_#{kind}.png"))
      magick(src, *opts, "-interlace", "PNG", out("png_#{kind}_adam7.png"))
      add.("png_#{kind}.png")
      add.("png_#{kind}_adam7.png")
    end
    5.times do |filter| # one fixed filter type for all rows (-quality 9N)
      magick(rgb, "-quality", "9#{filter}", "PNG24:#{out("png_rgb8_filter#{filter}.png")}")
      add.("png_rgb8_filter#{filter}.png")
    end
    magick(rgba, "-colors", "200", "PNG8:#{out('png_palette8_trns.png')}")
    magick(rgb, "-colors", "200", "-interlace", "PNG", "PNG8:#{out('png_palette8_adam7.png')}")
    add.("png_palette8_trns.png")
    add.("png_palette8_adam7.png")

    # PNG: palettes with explicit bit depths and tRNS variants, from Pillow.
    pillow(<<~PY, rgb, DIR)
      import sys
      from PIL import Image
      src, d = sys.argv[1], sys.argv[2]
      im = Image.open(src).convert("RGB")
      for bits in (1, 2, 4, 8):
          im.quantize(1 << bits).save(f"{d}/png_palette{bits}.png", bits=bits)
      im.quantize(16).save(f"{d}/png_palette4_trns.png", bits=4, transparency=bytes([0, 128, 255, 40, 7]))
      im.quantize(4).save(f"{d}/png_palette2_trns.png", bits=2, transparency=bytes([90]))
      gray = im.convert("L")
      gray.save(f"{d}/png_gray8_trns.png", transparency=gray.getpixel((20, 10)))
      im.save(f"{d}/png_rgb8_trns.png", transparency=im.getpixel((5, 5)))
    PY
    %w[png_palette1 png_palette2 png_palette4 png_palette8 png_palette4_trns png_palette2_trns png_gray8_trns
       png_rgb8_trns].each { |n| add.("#{n}.png") }

    # PNG: medium images.
    magick(tmp("photo_rgb.png"), "PNG24:#{out('png_medium_photo.png')}")
    magick(tmp("photo_rgba.png"), "-interlace", "PNG", "PNG32:#{out('png_medium_photo_rgba_adam7.png')}")
    magick(tmp("qr.png"), "-colorspace", "gray", "-define", "png:color-type=0", "-define", "png:bit-depth=1",
           out("png_medium_qr1.png"))
    %w[png_medium_photo.png png_medium_photo_rgba_adam7.png png_medium_qr1.png].each { |n| add.(n) }

    # GIF
    magick(rgb, "-colors", "64", out("gif_global.gif"))
    magick(rgb, "-colors", "64", "-interlace", "GIF", out("gif_interlaced.gif"))
    magick(rgba, "-channel", "A", "-threshold", "50%", "+channel", "-colors", "64", out("gif_transparent.gif"))
    magick(rgb, "-colors", "2", out("gif_2colors.gif"))
    magick(rgb, "-colors", "256", out("gif_256colors.gif"))
    magick(rgb, "-resize", "20x10!", "-colors", "16", "-repage", "41x29+7+5", out("gif_frame_offset.gif"))
    magick(rgb, "(", rgb, "-negate", ")", "-colors", "32", "-delay", "10", out("gif_animated.gif"))
    pillow(<<~PY, rgb, out("gif_local_palette.gif"))
      import sys
      from PIL import Image
      Image.open(sys.argv[1]).convert("RGB").quantize(50).save(sys.argv[2], include_color_table=True)
    PY
    %w[gif_global gif_interlaced gif_transparent gif_2colors gif_256colors gif_frame_offset gif_animated
       gif_local_palette].each { |n| add.("#{n}.gif") }
    # The local palette must win: blank out the global one (same pixels).
    gif = File.binread(out("gif_local_palette.gif"))
    gsize = 3 << ((gif.getbyte(10) & 7) + 1)
    gif[13, gsize] = "\0".b * gsize
    File.binwrite(out("gif_local_palette_only.gif"), gif)
    add.("gif_local_palette_only.gif", "gif_local_palette.gif")
    magick(tmp("qr.png"), "-colors", "2", out("gif_medium_qr.gif"))
    add.("gif_medium_qr.gif")

    # BMP
    magick(rgb, "-monochrome", "BMP3:#{out('bmp_1bit.bmp')}")
    magick(rgb, "-colors", "16", "-compress", "None", "BMP3:#{out('bmp_4bit.bmp')}")
    magick(rgb, "-colors", "200", "-compress", "None", "BMP3:#{out('bmp_8bit.bmp')}")
    magick(rgb, "-colors", "200", "-compress", "RLE", "BMP3:#{out('bmp_rle8.bmp')}")
    magick(rgb, "BMP3:#{out('bmp_24bit.bmp')}")
    magick(rgb, "BMP2:#{out('bmp_os2_24bit.bmp')}")
    magick(rgb, "-colors", "200", "BMP2:#{out('bmp_os2_8bit.bmp')}")
    magick(rgba, "BMP:#{out('bmp_v5_32bit_alpha.bmp')}")
    magick(rgb, "BMP:#{out('bmp_v5_24bit.bmp')}")
    magick(rgb, "-define", "bmp:subtype=RGB565", "BMP:#{out('bmp_rgb565.bmp')}")
    magick(rgb, "-define", "bmp:subtype=RGB555", "BMP:#{out('bmp_rgb555.bmp')}")
    magick(rgba, "-define", "bmp:subtype=ARGB4444", "BMP:#{out('bmp_argb4444.bmp')}")
    magick(rgba, "-define", "bmp:subtype=ARGB1555", "BMP:#{out('bmp_argb1555.bmp')}")
    %w[bmp_1bit bmp_4bit bmp_8bit bmp_rle8 bmp_24bit bmp_os2_24bit bmp_os2_8bit bmp_v5_32bit_alpha
       bmp_v5_24bit bmp_rgb565 bmp_rgb555].each { |n| add.("#{n}.bmp") }
    # ImageMagick widens 4-bit fields to v << 4 and 1-bit alpha to 128 when
    # reading these, so their references are computed here instead.
    %w[bmp_argb4444 bmp_argb1555].each { |n| add.("#{n}.bmp", :bitfields) }
    pillow(<<~PY, rgba, DIR)
      import sys
      from PIL import Image
      src, d = sys.argv[1], sys.argv[2]
      im = Image.open(src)
      im.save(f"{d}/bmp_pillow_32bit_bgra.bmp")
      im.convert("RGB").quantize(37).save(f"{d}/bmp_pillow_short_palette.bmp")
      im.convert("L").save(f"{d}/bmp_pillow_gray.bmp")
    PY
    %w[bmp_pillow_32bit_bgra bmp_pillow_short_palette bmp_pillow_gray].each { |n| add.("#{n}.bmp") }
    craft_bmps(add)
    magick(tmp("qr.png"), "-colors", "2", "-type", "Palette", "-compress", "RLE",
           "BMP3:#{out('bmp_medium_qr_rle8.bmp')}")
    add.("bmp_medium_qr_rle8.bmp")

    # PNM / PAM
    gray_src = tmp("src_gray.png")
    {
      "pnm_p1.pbm" => ["-monochrome", "-compress", "none", "pbm:"],
      "pnm_p2.pgm" => ["-compress", "none", "pgm:"],
      "pnm_p3.ppm" => ["-compress", "none", "ppm:"],
      "pnm_p4.pbm" => ["-monochrome", "pbm:"],
      "pnm_p5.pgm" => ["pgm:"],
      "pnm_p6.ppm" => ["ppm:"],
      "pnm_p5_maxval15.pgm" => ["-depth", "4", "pgm:"],
      "pnm_p5_16bit.pgm" => ["-depth", "16", "pgm:"],
      "pnm_p6_16bit.ppm" => ["-depth", "16", "ppm:"],
      "pnm_p3_16bit.ppm" => ["-depth", "16", "-compress", "none", "ppm:"],
      "pam_rgb.pam" => ["pam:"],
      "pam_gray.pam" => ["pam:"],
      "pam_gray16.pam" => ["-depth", "16", "pam:"]
    }.each do |name, opts|
      *args, prefix = opts
      src = name.match?(/p[25]|gray|maxval15/) ? gray_src : rgb
      magick(src, *args, "#{prefix}#{out(name)}")
      add.(name)
    end
    magick(rgba, "pam:#{out('pam_rgb_alpha.pam')}")
    magick(tmp("src_ga.png"), "pam:#{out('pam_gray_alpha.pam')}")
    add.("pam_rgb_alpha.pam")
    add.("pam_gray_alpha.pam")
    craft_pnms(add)
    magick(tmp("qr.png"), "-monochrome", "pbm:#{out('pnm_medium_qr.pbm')}")
    add.("pnm_medium_qr.pbm")
    fixtures
  end

  # BMP variants no encoder writes directly.
  def craft_bmps(add)
    # RLE4 from the 4-bit fixture's indices.
    bmp = File.binread(out("bmp_4bit.bmp"))
    w, h = bmp.unpack("l<l<", offset: 18)
    offset = bmp.unpack1("V", offset: 10)
    stride = ((w * 4 + 31) >> 5) << 2
    rows = Array.new(h) { |y| bmp.unpack1("H#{w}", offset: offset + y * stride).chars.map { |c| c.to_i(16) } }
    data = rle4_encode(rows)
    header = bmp.byteslice(0, offset)
    header[30, 4] = [2].pack("V") # BI_RLE4
    header[34, 4] = [data.bytesize].pack("V")
    file = header + data
    file[2, 4] = [file.bytesize].pack("V")
    File.binwrite(out("bmp_rle4.bmp"), file)
    add.("bmp_rle4.bmp", "bmp_4bit.bmp")

    # Top-down variants: negative height, rows stored top first.
    %w[bmp_24bit bmp_8bit bmp_1bit].each do |name|
      bmp = File.binread(out("#{name}.bmp"))
      w, h, _planes, bpp = bmp.unpack("l<l<vv", offset: 18)
      offset = bmp.unpack1("V", offset: 10)
      stride = ((w * bpp + 31) >> 5) << 2
      rows = Array.new(h) { |y| bmp.byteslice(offset + y * stride, stride) }
      flipped = bmp.byteslice(0, offset) + rows.reverse.join
      flipped[22, 4] = [-h].pack("l<")
      File.binwrite(out("#{name}_topdown.bmp"), flipped)
      add.("#{name}_topdown.bmp", "#{name}.bmp")
    end

    # BITMAPV4HEADER: the V5 file without its last 16 header bytes.
    bmp = File.binread(out("bmp_v5_32bit_alpha.bmp"))
    offset = bmp.unpack1("V", offset: 10)
    v4 = bmp.byteslice(0, 14 + 108) + bmp.byteslice(offset..)
    v4[2, 4] = [v4.bytesize].pack("V")
    v4[10, 4] = [14 + 108].pack("V")
    v4[14, 4] = [108].pack("V")
    File.binwrite(out("bmp_v4_32bit_alpha.bmp"), v4)
    add.("bmp_v4_32bit_alpha.bmp", "bmp_v5_32bit_alpha.bmp")

    # 32 bpp with 10-bit channel masks (BITMAPV4 header) from the 24-bit pixels.
    bmp = File.binread(out("bmp_24bit.bmp"))
    w, h = bmp.unpack("l<l<", offset: 18)
    offset = bmp.unpack1("V", offset: 10)
    stride = ((w * 24 + 31) >> 5) << 2
    pixels = String.new(encoding: Encoding::BINARY)
    h.times do |y|
      w.times do |x|
        b, g, r = bmp.unpack("C3", offset: offset + y * stride + x * 3)
        ten = ->(v) { (v * 1023 + 127) / 255 }
        pixels << [(ten.(r) << 20) | (ten.(g) << 10) | ten.(b)].pack("V")
      end
    end
    v4 = [40 + 68].pack("V") + [w, h, 1, 32, 3, pixels.bytesize, 2835, 2835, 0, 0].pack("l<l<vvVVl<l<VV") +
         [0x3FF00000, 0xFFC00, 0x3FF, 0].pack("V4") + "sRGB".b.reverse + ("\0".b * 48)
    file = "BM".b + [14 + v4.bytesize + pixels.bytesize, 0, 14 + v4.bytesize].pack("VVV") + v4 + pixels
    File.binwrite(out("bmp_v4_32bit_101010.bmp"), file)
    add.("bmp_v4_32bit_101010.bmp", "bmp_24bit.bmp")
  end

  # Runs (equal or alternating nibbles) where they pay off, absolute groups
  # otherwise; rows are in file order (bottom-up).
  def rle4_encode(rows)
    data = String.new(encoding: Encoding::BINARY)
    rows.each do |row|
      i = 0
      literal = []
      flush = lambda do
        until literal.empty?
          group = literal.shift(255)
          if group.size < 3
            data << [group.size, (group[0] << 4) | (group[1] || 0)].pack("CC")
          else
            nibbles = group.map { |v| v.to_s(16) }.join
            bytes = [nibbles].pack("H*")
            bytes << "\0" if bytes.bytesize.odd?
            data << [0, group.size].pack("CC") << bytes
          end
        end
      end
      while i < row.size
        run = 2
        run += 1 while i + run < row.size && run < 255 && row[i + run] == row[i + (run & 1)]
        run = row.size - i if run > row.size - i
        if run >= 4
          flush.call
          data << [run, (row[i] << 4) | (row[i + 1] || 0)].pack("CC")
          i += run
        else
          literal << row[i]
          i += 1
        end
      end
      flush.call
      data << "\0\0".b
    end
    data << "\0\1".b
  end

  def craft_pnms(add)
    # maxval 4095 holding round(v * 4095 / 255) of the 8-bit fixture, which
    # must decode back to v. (ImageMagick floors when it scales, so its own
    # 12-bit output does not round-trip.)
    p6 = File.binread(out("pnm_p6.ppm"))
    raster = p6.byteslice(p6.match(/\AP6\s\d+\s\d+\s\d+\s/n).end(0)..)
    wide = raster.bytes.map { |v| (v * 4095 + 127) / 255 }.pack("n*")
    File.binwrite(out("pnm_p6_maxval4095.ppm"), "P6\n41 29\n4095\n".b + wide)
    add.("pnm_p6_maxval4095.ppm", "pnm_p6.ppm")

    # Comments everywhere in the header.
    p6 = File.binread(out("pnm_p6.ppm"))
    w, h, max = p6.match(/\AP6\s(\d+)\s(\d+)\s(\d+)\s/n).captures
    raster = p6.byteslice($~.end(0)..)
    File.binwrite(out("pnm_p6_comments.ppm"),
                  "P6#c1\n# c2\n#{w}#c3\n #{h} # c4 #\n#c5\n#{max}\n".b + raster)
    add.("pnm_p6_comments.ppm", "pnm_p6.ppm")
    p2 = File.binread(out("pnm_p2.pgm"))
    File.binwrite(out("pnm_p2_comments.pgm"), p2.sub("\n", "\n# comment\n").sub(/(\d+ )/, "\\1#inline\n"))
    add.("pnm_p2_comments.pgm", "pnm_p2.pgm")
    # PAM BLACKANDWHITE from the PBM (PAM: 1 = white).
    p4 = File.binread(out("pnm_p4.pbm"))
    w, h = p4.match(/\AP4\s(\d+)\s(\d+)\s/n).captures.map(&:to_i)
    raster = p4.byteslice($~.end(0)..)
    stride = (w + 7) / 8
    bits = Array.new(h) { |y| raster.unpack1("B#{w}", offset: y * stride) }.join
    File.binwrite(out("pam_blackandwhite.pam"),
                  "P7\n# black and white\nWIDTH #{w}\nHEIGHT #{h}\nDEPTH 1\nMAXVAL 1\n".b +
                  "TUPLTYPE BLACKANDWHITE\nENDHDR\n".b + bits.tr("01", "\x01\x00".b))
    add.("pam_blackandwhite.pam", "pnm_p4.pbm")
  end

  # --- references ---------------------------------------------------------------

  def magick_rgba(path)
    args = File.extname(path) == ".gif" ? ["#{path}[0]", "-background", "white", "-flatten"] : ["#{path}[0]"]
    rgba, status = Open3.capture2("magick", *args, "-depth", "8", "rgba:-", binmode: true)
    raise "magick cannot decode #{path}" unless status.success?

    w, h = Open3.capture2("magick", *args, "-format", "%w %h", "info:")[0].split.map(&:to_i)
    raise "unexpected RGBA size for #{path}" unless rgba.bytesize == w * h * 4

    [w, h, rgba.b]
  end

  # Straightforward decoding of a bottom-up 16 bpp BITFIELDS BMP with a V4+
  # header, widening each field to 8 bits by bit replication.
  def bitfields_rgba(path)
    bmp = File.binread(path)
    w, h = bmp.unpack("l<l<", offset: 18)
    offset = bmp.unpack1("V", offset: 10)
    masks = bmp.unpack("V4", offset: 54)
    stride = ((w * 16 + 31) >> 5) << 2
    widen = lambda do |v, mask|
      shift = (mask & -mask).bit_length - 1
      bits = (mask >> shift).to_s(2)
      field = ((v & mask) >> shift).to_s(2).rjust(bits.size, "0")
      (field * 8)[0, 8].to_i(2) # repeat the bits: 5-bit abcde -> abcdeabc
    end
    rgba = String.new(encoding: Encoding::BINARY)
    h.times do |y|
      w.times do |x|
        v = bmp.unpack1("v", offset: offset + (h - 1 - y) * stride + x * 2)
        rgba << masks.map { |m| widen.(v, m) }.pack("C4")
      end
    end
    [w, h, rgba]
  end

  def write_references(fixtures)
    cache = {}
    fixtures.sort.to_h do |name, ref_source|
      computed = ref_source == :bitfields
      key = computed ? name : ref_source
      w, h, rgba = cache[key] ||= computed ? bitfields_rgba(out(name)) : magick_rgba(out(ref_source))
      digest = Digest::SHA256.hexdigest(rgba)[0, 16]
      ref = "ref_#{digest}.rgba.z"
      File.binwrite(out(ref), Zlib::Deflate.deflate(rgba, Zlib::BEST_COMPRESSION)) unless File.exist?(out(ref))
      [name, { "width" => w, "height" => h, "reference" => ref }]
    end
  end

  # Decodes files with Pillow; yields (path, w, h, rgba) or (path, nil, nil, error).
  def pillow_decode(paths)
    Dir.mktmpdir do |dir|
      output = pillow(PILLOW_DECODE, dir, *paths)
      output.each_line do |line|
        i, w, h = line.split(" ", 3)
        path = paths[i.to_i]
        if w == "error"
          yield path, nil, nil, h.strip
        else
          yield path, w.to_i, h.to_i, File.binread(File.join(dir, "#{i}.rgba"))
        end
      end
    end
  end

  def luma(w, h, rgba)
    QrReader::Image.from_pixels(w, h, rgba, :rgba).data
  end

  def cross_check(manifest)
    pillow_decode(manifest.keys.map { |n| out(n) }) do |path, w, h, rgba|
      name = File.basename(path)
      entry = manifest[name]
      next warn("  Pillow cannot decode #{name}: #{rgba}") unless w
      next warn("  Pillow size differs for #{name}: #{w}x#{h}") unless [w, h] == [entry["width"], entry["height"]]

      expected = luma(w, h, Zlib::Inflate.inflate(File.binread(out(entry["reference"]))))
      got = luma(w, h, rgba)
      next if expected == got

      diffs = expected.bytes.zip(got.bytes).map { |a, b| (a - b).abs }
      warn "  Pillow disagrees on #{name}: #{diffs.count(&:positive?)} pixels, max diff #{diffs.max}"
    end
  end

  def write_corpus_digests
    paths = Dir[File.join(CORPUS, "**", "*.png")].sort
    lines = []
    pillow_decode(paths) do |path, w, h, rgba|
      raise "Pillow cannot decode #{path}: #{rgba}" unless w

      rel = path.delete_prefix("#{CORPUS}/")
      gray = luma(w, h, rgba)
      mw, mh, mrgba = magick_rgba(path)
      warn "  ImageMagick disagrees on corpus #{rel}" unless [mw, mh] == [w, h] && luma(mw, mh, mrgba) == gray
      lines << "#{rel} #{w}x#{h} #{Digest::SHA256.hexdigest(gray)}"
    end
    File.write(out("zxing_png_luma.txt"), "#{lines.sort.join("\n")}\n")
  end
end

FixtureGenerator.run if $PROGRAM_NAME == __FILE__
