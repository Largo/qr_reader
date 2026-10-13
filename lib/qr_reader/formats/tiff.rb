# frozen_string_literal: true

require "zlib"

module QrReader
  module Formats
    # TIFF decoder, aimed at what scanners, fax software and image editors
    # write: bilevel CCITT pages as well as gray, colour and palette images.
    #
    #   TIFF.decode(bytes)                 # => first page as a QrReader::Image
    #   TIFF.decode(bytes, page: -1)       # => last page (negative indices count from the end)
    #   TIFF.page_count(bytes)             # => 3
    #   TIFF.each_page(bytes) { |image| }  # decodes one page at a time; Enumerator without a block
    #   TIFF.dimensions(bytes, page: 1)    # => [2480, 3508], from the page's directory only
    #
    # Supported: little and big endian, BigTIFF, multi-page directory chains,
    # strips and tiles; compression none, CCITT RLE / Group 3 / Group 4 (see
    # CCITT), LZW (also the old LSB-first variant), JPEG (JPEGTables merged
    # into each strip or tile; old-style JPEG only via JPEGInterchangeFormat),
    # Deflate and PackBits; predictor 2 (horizontal differencing) and 3
    # (floating point); photometric WhiteIsZero, BlackIsZero, RGB, palette,
    # CMYK, YCbCr (luma only) and CIELab (L* as luminance); 1 to 64 bits per
    # sample (unsigned, signed or floating point); planar configurations 1 and
    # 2; FillOrder 2; extra samples (associated or unassociated alpha is
    # composited over white like Image.from_pixels). Orientation is ignored:
    # QR codes read in any orientation.
    #
    # Pages are the images of the main directory chain; reduced-resolution
    # copies (thumbnails) and transparency masks are skipped. Damaged or
    # missing strips and tiles are left white, like truncated data; only a page
    # without any decodable image data raises ImageError.
    module TIFF
      NEW_SUBFILE_TYPE = 254
      SUBFILE_TYPE = 255
      IMAGE_WIDTH = 256
      IMAGE_LENGTH = 257
      BITS_PER_SAMPLE = 258
      COMPRESSION = 259
      PHOTOMETRIC = 262
      FILL_ORDER = 266
      STRIP_OFFSETS = 273
      SAMPLES_PER_PIXEL = 277
      ROWS_PER_STRIP = 278
      STRIP_BYTE_COUNTS = 279
      PLANAR_CONFIGURATION = 284
      T4_OPTIONS = 292
      PREDICTOR = 317
      COLOR_MAP = 320
      TILE_WIDTH = 322
      TILE_LENGTH = 323
      TILE_OFFSETS = 324
      TILE_BYTE_COUNTS = 325
      INK_SET = 332
      EXTRA_SAMPLES = 338
      SAMPLE_FORMAT = 339
      JPEG_TABLES = 347
      JPEG_INTERCHANGE_FORMAT = 513
      JPEG_INTERCHANGE_FORMAT_LENGTH = 514
      YCBCR_SUBSAMPLING = 530

      # Field type -> byte size.
      TYPE_SIZES = {
        1 => 1, 2 => 1, 3 => 2, 4 => 4, 5 => 8, 6 => 1, 7 => 1, 8 => 2, 9 => 4, 10 => 8,
        11 => 4, 12 => 8, 13 => 4, 16 => 8, 17 => 8, 18 => 8
      }.freeze
      # Integer field type -> unpack directive, little and big endian.
      INT_DIRECTIVES_LE = {
        1 => "C*", 3 => "v*", 4 => "V*", 6 => "c*", 7 => "C*", 8 => "s<*", 9 => "l<*", 13 => "V*",
        16 => "Q<*", 17 => "q<*", 18 => "Q<*"
      }.freeze
      INT_DIRECTIVES_BE = {
        1 => "C*", 3 => "n*", 4 => "N*", 6 => "c*", 7 => "C*", 8 => "s>*", 9 => "l>*", 13 => "N*",
        16 => "Q>*", 17 => "q>*", 18 => "Q>*"
      }.freeze

      UNSUPPORTED_COMPRESSION = {
        9 => "JBIG (T.85)", 10 => "JBIG2 (T.43)", 32_766 => "NeXT RLE", 32_771 => "CCITT RLE (word-aligned)",
        32_809 => "ThunderScan RLE", 34_661 => "JBIG", 34_676 => "SGI LogLuv", 34_677 => "SGI LogLuv",
        34_712 => "JPEG 2000", 34_887 => "LERC", 34_892 => "lossy JPEG (DNG)", 34_925 => "LZMA",
        50_000 => "Zstandard", 50_001 => "WebP", 50_002 => "JPEG XL"
      }.freeze

      WHITE = "\xFF".b
      SOI = "\xFF\xD8".b
      EOI = "\xFF\xD9".b
      # Adobe APP14 segment without its transform byte (marks JPEG data as RGB).
      ADOBE = "\xFF\xEE\x00\x0EAdobe\x00\x64\x00\x00\x00\x00".b
      HEX_DIGITS = "0123456789abcdef".b
      ALL_BYTES = (0..255).to_a.freeze
      # Byte -> byte with its bits reversed (FillOrder 2), as String#tr tables.
      REVERSE_FROM = Image::TR_ESCAPE.call(ALL_BYTES)
      REVERSE_TO = Image::TR_ESCAPE.call(ALL_BYTES.map { |b| format("%08b", b).reverse.to_i(2) })
      # Byte -> its four 2-bit samples as bytes 0..3.
      TWO_BIT = Array.new(256) { |b| [b >> 6, (b >> 4) & 3, (b >> 2) & 3, b & 3].pack("C4").freeze }.freeze
      # Input slice size for Zlib, so that a decompression bomb stops early.
      INFLATE_SLICE = 16_384
      # Unpack directives (little, big endian) of wide samples for predictor 2.
      WORDS = { 16 => %w[v* n*], 32 => %w[V* N*], 64 => %w[Q<* Q>*] }.freeze
      # Unpack directives of floating point samples by [bits, big endian].
      FLOATS = { [32, false] => "e*", [32, true] => "g*", [64, false] => "E*", [64, true] => "G*" }.freeze

      # An empty binary String with room for +size+ bytes. Hot methods call
      # this rather than String.new(capacity:, encoding:) themselves: YJIT
      # side-exits on that keyword-argument call for the rest of the method.
      module Bytes
        def self.buffer(size)
          String.new(capacity: size, encoding: Encoding::BINARY)
        end
      end

      class << self
        # Decodes page +page+ (0-based; negative counts from the end) to a
        # luminance Image. Raises IndexError for a page that does not exist.
        def decode(bytes, page: 0)
          Container.new(bytes).page(page).decode
        end

        # Number of pages.
        def page_count(bytes)
          Container.new(bytes).pages.size
        end

        # Yields each page as an Image, decoding it only when it is reached.
        # Returns an Enumerator (sized by page_count) without a block.
        def each_page(bytes)
          return enum_for(:each_page, bytes) { page_count(bytes) } unless block_given?

          container = Container.new(bytes)
          container.pages.each_index { |i| yield container.page(i).decode }
          nil
        end

        # [width, height] of a page, read from its directory only.
        def dimensions(bytes, page: 0)
          Container.new(bytes).page(page).dimensions
        end
      end

      # The file header and the chain of image file directories (IFDs).
      class Container
        attr_reader :bytes

        def initialize(bytes)
          raise ImageError, "expected a String of TIFF data, got #{bytes.class}" unless bytes.is_a?(String)

          @bytes = bytes.encoding == Encoding::BINARY ? bytes : bytes.b
          raise ImageError, "truncated TIFF header" if @bytes.bytesize < 8

          case @bytes.byteslice(0, 4)
          when "II*\0" then @le = true
          when "MM\0*" then @le = false
          when "II+\0" then @le = @big = true
          when "MM\0+"
            @le = false
            @big = true
          else raise ImageError, "not a TIFF file"
          end
          @directives = @le ? INT_DIRECTIVES_LE : INT_DIRECTIVES_BE
          if @big
            raise ImageError, "unsupported BigTIFF offset size" unless @bytes.bytesize >= 16 && uint(4, 2) == 8

            @first = uint(8, 8)
          else
            @first = uint(4, 4)
          end
        end

        def little_endian?
          @le
        end

        # Directories of the pages, in file order.
        def pages
          @pages ||= begin
            dirs = directories
            raise ImageError, "TIFF file contains no image directory" if dirs.empty?

            main = dirs.reject(&:subsidiary?)
            main.empty? ? dirs : main
          end
        end

        def page(index)
          dir = pages[index] if index.is_a?(Integer)
          raise IndexError, "TIFF page #{index.inspect} out of range (#{pages.size} pages)" unless dir

          Page.new(self, dir)
        end

        # Unsigned little/big endian integer of +size+ bytes at +pos+.
        def uint(pos, size)
          v = 0
          if @le
            i = pos + size - 1
            while i >= pos
              v = (v << 8) | @bytes.getbyte(i)
              i -= 1
            end
          else
            stop = pos + size
            while pos < stop
              v = (v << 8) | @bytes.getbyte(pos)
              pos += 1
            end
          end
          v
        end

        # Integer values of a field (nil for non-integer types or values
        # outside the file).
        def ints(type, count, pos)
          directive = @directives[type] or return nil
          size = count * TYPE_SIZES[type]
          return nil if pos + size > @bytes.bytesize

          @bytes.byteslice(pos, size).unpack(directive)
        end

        # Raw bytes of a field.
        def blob(type, count, pos)
          size = count * TYPE_SIZES[type]
          return nil if pos + size > @bytes.bytesize

          @bytes.byteslice(pos, size)
        end

        private

        # Follows the IFD chain (stops at loops and offsets outside the file).
        def directories
          dirs = []
          seen = {}
          offset = @first
          while offset.positive? && !seen[offset]
            seen[offset] = true
            dir = read_directory(offset) or break
            dirs << dir
            offset = dir.next_offset
          end
          dirs
        end

        def read_directory(offset)
          size = @bytes.bytesize
          count_size, entry_size, value_size = @big ? [8, 20, 8] : [2, 12, 4]
          return nil if offset + count_size > size

          count = uint(offset, count_size)
          start = offset + count_size
          return nil if count.zero? || start + count * entry_size > size

          entries = {}
          count.times do |i|
            pos = start + i * entry_size
            tag = uint(pos, 2)
            type = uint(pos + 2, 2)
            n = uint(pos + 4, value_size)
            type_size = TYPE_SIZES[type]
            next if entries.key?(tag) || !type_size

            value_pos = pos + 4 + value_size
            value_pos = uint(value_pos, value_size) if n * type_size > value_size
            entries[tag] = [type, n, value_pos]
          end
          next_pos = start + count * entry_size
          next_offset = next_pos + value_size <= size ? uint(next_pos, value_size) : 0
          Directory.new(self, entries, next_offset)
        end
      end

      # One image file directory: tag -> [type, count, value position].
      class Directory
        attr_reader :next_offset

        def initialize(container, entries, next_offset)
          @container = container
          @entries = entries
          @next_offset = next_offset
        end

        def include?(tag)
          @entries.key?(tag)
        end

        # Integer values of +tag+, or nil.
        def ints(tag)
          entry = @entries[tag] or return nil
          @container.ints(*entry)
        end

        # First integer value of +tag+, or +default+.
        def int(tag, default = nil)
          ints(tag)&.first || default
        end

        # Raw bytes of +tag+ (JPEGTables), or nil.
        def blob(tag)
          entry = @entries[tag] or return nil
          @container.blob(*entry)
        end

        # Reduced-resolution image or transparency mask, not a page.
        def subsidiary?
          int(NEW_SUBFILE_TYPE, 0) & 5 != 0 || int(SUBFILE_TYPE) == 2
        end
      end

      # Decodes one page. Strips and tiles ("chunks") are decompressed to
      # sample rows, normalised to one byte per sample and converted to
      # luminance; bilevel CCITT chunks and colour JPEG chunks yield
      # luminance directly.
      class Page
        attr_reader :width, :height

        def initialize(container, dir)
          @bytes = container.bytes
          @le = container.little_endian?
          @dir = dir
          @width = dir.int(IMAGE_WIDTH)
          @height = dir.int(IMAGE_LENGTH)
          raise ImageError, "TIFF page without image dimensions" unless @width && @height

          raise ImageError, "invalid TIFF dimensions #{@width}x#{@height}" unless @width.positive? && @height.positive?
          return if @width * @height <= MAX_PIXELS

          raise UnsupportedImageError, "TIFF image too large (#{@width}x#{@height}, limit #{MAX_PIXELS} pixels)"
        end

        def dimensions
          [@width, @height]
        end

        def decode
          setup
          @decoded = 0
          data = if @codec == :ojpeg then old_jpeg
                 elsif @planes then decode_planar
                 else assemble(0, WHITE) { |src, cw, rows| chunk_luma(src, cw, rows) }
                 end
          raise ImageError, "TIFF page has no decodable image data" if @decoded.zero?

          Image.new(@width, @height, data)
        end

        private

        # --- parameters ---------------------------------------------------

        def setup
          d = @dir
          @spp = d.int(SAMPLES_PER_PIXEL, 1)
          raise ImageError, "invalid TIFF samples per pixel #{@spp}" unless @spp.between?(1, 64)

          depths = d.ints(BITS_PER_SAMPLE) || [1]
          @bps = depths.first
          raise ImageError, "invalid TIFF bits per sample #{@bps}" unless @bps&.between?(1, 64)
          unless depths.first(@spp).uniq.size == 1
            raise UnsupportedImageError, "TIFF images with different bit depths per sample are not supported"
          end

          @compression = d.int(COMPRESSION, 1)
          @photometric = d.int(PHOTOMETRIC) || default_photometric
          @fill_order = d.int(FILL_ORDER, 1)
          @predictor = d.int(PREDICTOR, 1)
          @sample_format = d.int(SAMPLE_FORMAT, 1)
          setup_layout
          setup_codec
          setup_color unless %i[ojpeg fax].include?(@codec)
        end

        def default_photometric
          if [2, 3, 4].include?(@dir.int(COMPRESSION)) then 0
          elsif @spp >= 3 then 2
          elsif @dir.include?(COLOR_MAP) then 3
          else 1
          end
        end

        def setup_layout
          d = @dir
          w = @width
          h = @height
          if d.include?(TILE_WIDTH)
            tw = d.int(TILE_WIDTH)
            tl = d.int(TILE_LENGTH)
            raise ImageError, "invalid TIFF tile size" unless tw&.positive? && tl&.positive?

            @tiled = true
            @chunk_w = tw
            @chunk_h = tl
            @across = (w + tw - 1) / tw
            @down = (h + tl - 1) / tl
            if @across * @down * tw * tl > 2 * MAX_PIXELS
              raise UnsupportedImageError, "TIFF tiles too large (#{tw}x#{tl} for a #{w}x#{h} image)"
            end

            @offsets = d.ints(TILE_OFFSETS) || d.ints(STRIP_OFFSETS)
            @counts = d.ints(TILE_BYTE_COUNTS) || d.ints(STRIP_BYTE_COUNTS)
          else
            rps = d.int(ROWS_PER_STRIP, h)
            rps = h unless rps.positive? && rps < h
            @tiled = false
            @chunk_w = w
            @chunk_h = rps
            @across = 1
            @down = (h + rps - 1) / rps
            @offsets = d.ints(STRIP_OFFSETS)
            @counts = d.ints(STRIP_BYTE_COUNTS)
          end
          raise ImageError, "TIFF page without image data offsets" unless @offsets

          @per_plane = @across * @down
        end

        def setup_codec
          case @compression
          when 1 then @codec = :none
          when 2, 3, 4 then setup_fax
          when 5 then @codec = :lzw
          when 6 then @codec = :ojpeg
          when 7
            @codec = :jpeg
            @jpeg_tables = @dir.blob(JPEG_TABLES)
          when 8, 32_946 then @codec = :deflate
          when 32_773 then @codec = :packbits
          else
            name = UNSUPPORTED_COMPRESSION.fetch(@compression) { "compression #{@compression}" }
            raise UnsupportedImageError, "#{name} TIFF images are not supported"
          end
        end

        def setup_fax
          raise ImageError, "CCITT-compressed TIFF must be 1 bit per pixel" unless @bps == 1 && @spp == 1

          @codec = :fax
          t4 = @dir.int(T4_OPTIONS, 0)
          @fax = case @compression
                 when 2 then { k: 0, encoded_byte_align: true }
                 when 3 then { k: t4 & 1, encoded_byte_align: t4 & 4 != 0, end_of_line: true }
                 else { k: -1 }
                 end
          @fax[:fill_order] = @fill_order
          @fax[:black_is_1] = @photometric == 1 # coded white runs are 0 bits
        end

        # Chooses the luminance conversion (@mode), which samples it reads
        # and the per-value mapping applied while unpacking samples.
        def setup_color
          ph = @photometric
          spp = @spp
          extra = @dir.ints(EXTRA_SAMPLES) || []
          @invert = false
          lut = nil
          color = case ph
                  when 0, 1
                    @invert = ph.zero?
                    1
                  when 2 then 3
                  when 3
                    lut = palette
                    1
                  when 5 then @dir.int(INK_SET, 1) == 1 && spp >= 4 ? 4 : 1
                  when 6 then 3
                  when 8, 9, 10 then 1 # L* only
                  else raise UnsupportedImageError, "TIFF photometric interpretation #{ph} is not supported"
                  end
          raise ImageError, "TIFF photometric #{ph} needs #{color} samples per pixel, got #{spp}" if spp < color

          alpha = spp > color && [1, 2].include?(extra.first) ? spp - extra.size : nil
          alpha = nil if alpha && alpha < color
          @associated = extra.first == 1
          @invert = true if ph == 5 && color == 1 # a single ink: 0 is white

          @mode = if @codec == :jpeg && spp > 1 && !planar? then :luma
                  elsif ph == 6 then planar? ? :single : :ycbcr
                  elsif color == 4 then :cmyk
                  elsif color == 3 && ph == 2 then alpha ? :rgba : :rgb
                  elsif alpha && lut.nil? && [0, 1].include?(ph) then :gray_alpha
                  else spp == 1 ? :single : :pick
                  end
          setup_planes(alpha)
          setup_samples(lut)
          @adobe = 0 if @mode == :luma && ph == 2 # JPEG data holds RGB, not YCbCr
        end

        def planar?
          @dir.int(PLANAR_CONFIGURATION, 1) == 2 && @spp > 1
        end

        # Sample offsets within a pixel (@channels) for the conversion and,
        # for planar data, which planes are needed.
        def setup_planes(alpha)
          used = case @mode
                 when :rgb then [0, 1, 2]
                 when :rgba then [0, 1, 2, alpha]
                 when :cmyk then [0, 1, 2, 3]
                 when :gray_alpha then [0, alpha]
                 else [0]
                 end
          if planar?
            @planes = used
            @channels = (0...used.size).to_a
            @stride = used.size
            @mode = :single if used.size == 1
          else
            @channels = used
            @stride = @spp
          end
        end

        # Mapping of unpacked sample values to output bytes: scaling of low
        # bit depths, palette lookup, WhiteIsZero inversion, signed samples.
        def setup_samples(lut)
          bps = @bps
          @float = @sample_format == 3
          if @float && ![32, 64].include?(bps)
            raise UnsupportedImageError, "#{bps}-bit floating point TIFF samples are not supported"
          end
          raise UnsupportedImageError, "TIFF palettes with more than 8 bits are not supported" if lut && bps > 8
          if @predictor == 2 && bps != 8 && !WORDS.key?(bps)
            raise UnsupportedImageError, "TIFF predictor 2 with #{bps}-bit samples is not supported"
          end
          unless [1, 2, 3].include?(@predictor)
            raise UnsupportedImageError, "TIFF predictor #{@predictor} is not supported"
          end
          raise UnsupportedImageError, "TIFF predictor 3 needs floating point samples" if @predictor == 3 && !@float
          raise UnsupportedImageError, "JPEG-compressed TIFF must have 8-bit samples" if @codec == :jpeg && bps != 8

          signed = @sample_format == 2 && bps >= 8
          final = %i[single pick].include?(@mode)
          max = (1 << bps) - 1
          levels = bps < 8 ? max + 1 : 256
          map = Array.new(levels) do |v|
            if lut then lut[v]
            else
              s = bps < 8 ? (v * 255 + max / 2) / max : v
              s ^= 0x80 if signed
              final && @invert ? 255 - s : s
            end
          end
          from = case bps
                 when 1 then "01".b
                 when 4 then HEX_DIGITS
                 else ALL_BYTES.first(levels).pack("C*")
                 end
          @fused_rgb = @mode == :rgb && @predictor == 2 && bps == 8 && !planar? && map == ALL_BYTES
          return if map == ALL_BYTES

          @tr_from = Image::TR_ESCAPE.call(from.bytes)
          @tr_to = Image::TR_ESCAPE.call(map)
        end

        # Palette entry -> luminance. 16-bit colour map values; files with
        # 8-bit values (all below 256) are accepted like libtiff does.
        def palette
          n = 1 << [@bps, 8].min
          cmap = @dir.ints(COLOR_MAP)
          raise ImageError, "TIFF palette image without a valid colour map" unless cmap && cmap.size >= 3 * n

          shift = cmap.first(3 * n).max < 256 ? 0 : 8
          Array.new(n) { |i| Image.luma(cmap[i] >> shift, cmap[n + i] >> shift, cmap[2 * n + i] >> shift) }
        end

        # --- chunk layout -------------------------------------------------

        # Decodes the chunks of one plane into a width * height buffer. The
        # block turns a chunk's data into rows of +cw+ bytes (possibly fewer
        # rows than asked for); missing parts are filled with +fill+.
        def assemble(plane, fill)
          w = @width
          h = @height
          cw = @chunk_w
          ch = @chunk_h
          base = plane * @per_plane
          # Chunks without an offset are missing: no need to visit them.
          count = (@offsets.size - base).clamp(0, @per_plane)
          if @tiled
            out = fill * (w * h)
            count.times do |i|
              data = chunk_data(base + i) or next
              x0 = (i % @across) * cw
              y0 = (i / @across) * ch
              part = yield(data, cw, ch) or next
              vis_w = [cw, w - x0].min
              rows = [part.bytesize / cw, h - y0].min
              rows.times { |r| out.bytesplice((y0 + r) * w + x0, vis_w, part.byteslice(r * cw, vis_w)) }
            end
          else
            out = Bytes.buffer(w * h)
            count.times do |i|
              rows = [ch, h - i * ch].min
              need = rows * w
              data = chunk_data(base + i)
              part = yield(data, w, rows) if data
              if part.nil? || part.empty?
                out << fill * need
              elsif part.bytesize >= need
                out << (part.bytesize == need ? part : part.byteslice(0, need))
              else
                out << part << fill * (need - part.bytesize)
              end
            end
            out << fill * (w * h - out.bytesize)
          end
          out
        end

        # Bytes of chunk +index+ (shorter when the file is truncated), or nil.
        def chunk_data(index)
          off = @offsets[index]
          size = @bytes.bytesize
          return nil unless off&.positive? && off < size

          count = @counts&.[](index)
          count ||= size - off
          return nil unless count.positive?

          @bytes.byteslice(off, count)
        end

        # Luminance rows of one chunk (planar configuration 1).
        def chunk_luma(data, cw, rows)
          case @codec
          when :fax then return fax_chunk(data, cw, rows)
          when :jpeg
            samples = jpeg_chunk(data, cw, rows) or return nil
            return samples if @mode == :luma

            avail = samples.bytesize / cw
            samples.tr!(@tr_from, @tr_to) if @tr_from
          else
            raw = decompress(data, chunk_size(cw, rows, @spp))
            return ycbcr_luma(raw, cw, rows) if @mode == :ycbcr
            return predicted_rgb_luma(raw, cw, rows) if @fused_rgb

            samples, avail = normalize(raw, cw, rows, @spp)
            return nil if avail.zero?

            @decoded += 1
          end
          convert(samples, cw, avail)
        end

        # Normalised samples of one chunk of one plane (planar configuration 2).
        def plane_samples(data, cw, rows)
          if @codec == :jpeg
            samples = jpeg_chunk(data, cw, rows) or return nil
            samples.tr!(@tr_from, @tr_to) if @tr_from
            return samples
          end

          samples, avail = normalize(decompress(data, chunk_size(cw, rows, 1)), cw, rows, 1)
          @decoded += 1 if avail.positive?
          samples
        end

        def decode_planar
          # Single planes hold luminance; otherwise white is the colour
          # samples' white and opaque alpha.
          alpha = @planes.last if %i[rgba gray_alpha].include?(@mode)
          fills = @planes.map { |p| @mode == :single || p == alpha ? WHITE : white_sample }
          planes = @planes.zip(fills).map do |p, fill|
            assemble(p, fill) { |src, cw, rows| plane_samples(src, cw, rows) }
          end
          return planes[0] if @mode == :single

          # Each row's planes are joined, so that the converters read them
          # as channels +w+ bytes apart. Rows without data are white.
          w = @width
          @channels = Array.new(planes.size) { |i| i * w }
          @stride = 1
          blank = fills.map { |fill| fill * w }.join
          white = WHITE * w
          out = Bytes.buffer(w * @height)
          @height.times do |y|
            row = planes.map { |pl| pl.byteslice(y * w, w) }.join
            if row == blank
              out << white
            else
              convert_row(row, 0, w, out)
            end
          end
          out
        end

        # The value of a white colour sample before conversion.
        def white_sample
          [0, 5].include?(@photometric) ? "\0".b : WHITE
        end

        # Expected decompressed size of a chunk.
        def chunk_size(cw, rows, nsamp)
          if @mode == :ycbcr
            sh, sv = subsampling
            ((rows + sv - 1) / sv) * ((cw + sh - 1) / sh) * (sh * sv + 2)
          else
            ((cw * nsamp * @bps + 7) >> 3) * rows
          end
        end

        # --- codecs -------------------------------------------------------

        def decompress(data, expected)
          data = data.tr(REVERSE_FROM, REVERSE_TO) if @fill_order == 2
          case @codec
          when :none then data
          when :lzw then LZW.new(data, expected).decode
          when :deflate then inflate(data, expected)
          when :packbits then packbits(data, expected)
          end
        end

        def fax_chunk(data, cw, rows)
          image = CCITT.decode(data, columns: cw, rows: rows, **@fax)
          @decoded += 1
          image.data
        rescue UnsupportedImageError
          raise
        rescue ImageError
          nil # not even the first row decodes: the chunk stays white
        end

        # Inflates zlib (or raw deflate) data; stops after +expected+ bytes
        # and keeps what was decoded before an error.
        def inflate(data, expected)
          out = Bytes.buffer(expected)
          [Zlib::MAX_WBITS, -Zlib::MAX_WBITS].each do |window_bits|
            zstream = Zlib::Inflate.new(window_bits)
            pos = 0
            while pos < data.bytesize && out.bytesize < expected
              out << zstream.inflate(data.byteslice(pos, INFLATE_SLICE))
              pos += INFLATE_SLICE
            end
            break
          rescue Zlib::Error
            break unless out.empty?
          ensure
            zstream&.reset
            zstream&.close
          end
          out
        end

        def packbits(data, expected)
          out = Bytes.buffer(expected)
          i = 0
          n = data.bytesize
          while i < n && out.bytesize < expected
            c = data.getbyte(i)
            i += 1
            if c < 128
              out << data.byteslice(i, c + 1)
              i += c + 1
            elsif c > 128
              b = data.byteslice(i, 1)
              out << b * (257 - c)
              i += 1
            end
          end
          out
        end

        # Luminance (or, for gray JPEGs, sample) rows of a JPEG chunk:
        # JPEGTables merged in, cropped or padded to +cw+ x +rows+.
        def jpeg_chunk(data, cw, rows)
          stream = data
          tables = @jpeg_tables
          if tables&.start_with?(SOI) && stream.start_with?(SOI)
            tables = tables.byteslice(0, tables.bytesize - 2) if tables.end_with?(EOI)
            stream = tables + stream.byteslice(2, stream.bytesize - 2)
          end
          if @adobe && stream.start_with?(SOI)
            stream = SOI + ADOBE + @adobe.chr + stream.byteslice(2, stream.bytesize - 2)
          end
          jw, jh = JPEG.dimensions(stream)
          return nil if jw * jh > cw * @chunk_h # not this chunk's image; also bounds crafted sizes

          image = JPEG.decode(stream)
          @decoded += 1
          fit(image.data, jw, [jh, rows].min, cw)
        rescue UnsupportedImageError
          raise
        rescue ImageError
          nil
        end

        # +rows+ rows of +cw+ bytes from a buffer with rows of +w+ bytes.
        def fit(data, w, rows, cw)
          return data.byteslice(0, cw * rows) if w == cw

          out = Bytes.buffer(cw * rows)
          rows.times do |r|
            out << data.byteslice(r * w, [w, cw].min)
            out << WHITE * (cw - w) if w < cw
          end
          out
        end

        # Old-style JPEG (compression 6): only the common case of a complete
        # JPEG stream at JPEGInterchangeFormat is supported.
        def old_jpeg
          off = @dir.int(JPEG_INTERCHANGE_FORMAT)
          unless off&.positive? && off < @bytes.bytesize
            raise UnsupportedImageError, "old-style JPEG TIFF images are not supported"
          end

          length = @dir.int(JPEG_INTERCHANGE_FORMAT_LENGTH)
          length = @bytes.bytesize - off unless length&.positive?
          image = JPEG.decode(@bytes.byteslice(off, length))
          @decoded = 1
          w = @width
          rows = [image.height, @height].min
          data = fit(image.data, image.width, rows, w)
          data << WHITE * (w * (@height - rows)) if rows < @height
          data
        rescue UnsupportedImageError
          raise
        rescue ImageError
          raise UnsupportedImageError, "old-style JPEG TIFF images are not supported"
        end

        # --- samples ------------------------------------------------------

        # Unpacks the complete rows of a decompressed chunk to one byte per
        # sample (values mapped by setup_samples). Returns [samples, rows].
        def normalize(raw, cw, rows, nsamp)
          bps = @bps
          count = cw * nsamp
          row_bytes = (count * bps + 7) >> 3
          avail = raw.bytesize / row_bytes
          avail = rows if avail > rows
          return ["".b, 0] if avail.zero?

          raw = raw.byteslice(0, avail * row_bytes) if raw.bytesize != avail * row_bytes
          raw = undo_predictor(raw, row_bytes, avail, nsamp) if @predictor != 1
          samples = case bps
                    when 8 then raw
                    when 1 then unpack_text(raw.unpack1("B*"), row_bytes * 8, count, avail)
                    when 4 then unpack_text(raw.unpack1("H*"), row_bytes * 2, count, avail)
                    end
          samples ||= unpack_rows(raw, row_bytes, count, avail)
          samples.tr!(@tr_from, @tr_to) if @tr_from
          [samples, avail]
        end

        # Rows of an unpacked bit/hex digit string trimmed to +count+ samples.
        def unpack_text(text, per_row, count, rows)
          text.force_encoding(Encoding::BINARY)
          return text if per_row == count

          out = Bytes.buffer(count * rows)
          rows.times { |r| out << text.byteslice(r * per_row, count) }
          out
        end

        def unpack_rows(raw, row_bytes, count, rows)
          bps = @bps
          out = Bytes.buffer(count * rows)
          if @float
            # File byte order, except after predictor 3 (always big-endian).
            directive = FLOATS[[bps, !@le || @predictor == 3]]
            rows.times { |r| floats_row(raw.byteslice(r * row_bytes, row_bytes).unpack(directive), out) }
          elsif bps == 2
            rows.times { |r| unpack2_row(raw, r * row_bytes, count, out) }
          elsif (bps & 7).zero?
            step = bps >> 3
            msb = @le ? step - 1 : 0
            rows.times { |r| pick(raw, r * row_bytes + msb, count, step, out) }
          else
            rows.times { |r| bits_row(raw, r * row_bytes, count, bps, out) }
          end
          out
        end

        # 2-bit samples (MSB first) -> one byte 0..3 each.
        def unpack2_row(src, off, n, out)
          stop = off + (n >> 2)
          i = off
          while i < stop
            out << TWO_BIT[src.getbyte(i)]
            i += 1
          end
          out << TWO_BIT[src.getbyte(stop)].byteslice(0, n & 3) if (n & 3).positive?
          out
        end

        # Every +step+-th byte (the most significant byte of wide samples).
        def pick(src, off, n, step, out)
          stop = off + n * step
          while off < stop
            out << src.getbyte(off)
            off += step
          end
          out
        end

        # Samples of an odd bit depth (MSB first), reduced to 8 bits if wider.
        def bits_row(src, off, n, bps, out)
          pos = off * 8
          shift = bps > 8 ? bps - 8 : 0
          i = 0
          while i < n
            v = 0
            need = bps
            while need.positive?
              left = 8 - (pos & 7)
              take = need < left ? need : left
              v = (v << take) | ((src.getbyte(pos >> 3) >> (left - take)) & ((1 << take) - 1))
              pos += take
              need -= take
            end
            out << (v >> shift)
            i += 1
          end
          out
        end

        # Floating point samples (0.0 = black, 1.0 = white) -> bytes.
        def floats_row(values, out)
          i = 0
          n = values.size
          while i < n
            v = values[i] * 255 + 0.5
            out << if v.nan? || v <= 0 then 0
                   elsif v >= 255 then 255
                   else v.to_i
                   end
            i += 1
          end
          out
        end

        # Returns +raw+ with the predictor undone (in place, or a new String).
        def undo_predictor(raw, row_bytes, rows, nsamp)
          bps = @bps
          if @predictor == 3
            rows.times do |r|
              off = r * row_bytes
              raw.bytesplice(off, row_bytes, float_row(raw.byteslice(off, row_bytes), nsamp, bps >> 3))
            end
          elsif bps == 8 && nsamp == 1
            out = Bytes.buffer(raw.bytesize)
            rows.times { |r| accumulate_row(raw, r * row_bytes, row_bytes, out) }
            return out
          elsif bps == 8
            rows.times { |r| accumulate_bytes(raw, r * row_bytes, row_bytes, nsamp) }
          else
            directive = WORDS[bps][@le ? 0 : 1]
            mask = (1 << bps) - 1
            rows.times do |r|
              off = r * row_bytes
              values = raw.byteslice(off, row_bytes).unpack(directive)
              accumulate(values, nsamp, mask)
              raw.bytesplice(off, row_bytes, values.pack(directive))
            end
          end
          raw
        end

        # Horizontal differencing on one 8-bit sample per pixel, appended to
        # +out+ (appending beats setbyte in place by about 1.5x).
        def accumulate_row(src, off, n, out)
          acc = 0
          i = off
          stop = off + n
          while i < stop
            out << (acc = (acc + src.getbyte(i)) & 0xFF)
            i += 1
          end
          out
        end

        # 8-bit RGB with horizontal differencing (what most writers produce
        # for colour LZW and Deflate): the predictor is undone while
        # converting to luminance, three to four times faster than two passes.
        def predicted_rgb_luma(raw, cw, rows)
          stride = @spp
          row_bytes = cw * stride
          avail = [raw.bytesize / row_bytes, rows].min
          return nil if avail.zero?

          @decoded += 1
          out = Bytes.buffer(cw * avail)
          avail.times { |r| predicted_rgb_row(raw, r * row_bytes, cw, stride, out) }
          out
        end

        def predicted_rgb_row(src, off, n, stride, out)
          r = g = b = 0
          i = off
          stop = off + n * stride
          while i < stop
            r = (r + src.getbyte(i)) & 0xFF
            g = (g + src.getbyte(i + 1)) & 0xFF
            b = (b + src.getbyte(i + 2)) & 0xFF
            out << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
            i += stride
          end
          out
        end

        # Horizontal differencing on bytes (8-bit samples).
        def accumulate_bytes(raw, off, len, stride)
          i = off + stride
          stop = off + len
          while i < stop
            raw.setbyte(i, (raw.getbyte(i) + raw.getbyte(i - stride)) & 0xFF)
            i += 1
          end
        end

        def accumulate(values, stride, mask)
          i = stride
          n = values.size
          while i < n
            values[i] = (values[i] + values[i - stride]) & mask
            i += 1
          end
        end

        # Undoes the floating point predictor: byte differencing over the
        # row, then the bytes of each sample are gathered from byte planes
        # (most significant first). The result is big-endian.
        def float_row(row, stride, size)
          bytes = row.bytes
          i = stride
          n = bytes.size
          while i < n
            bytes[i] = (bytes[i] + bytes[i - stride]) & 0xFF
            i += 1
          end
          count = n / size
          planes = Array.new(size) { |b| bytes[b * count, count] }
          planes[0].zip(*planes[1..]).flatten!.pack("C*")
        end

        # Y samples of subsampled YCbCr data (8 bits, data units of
        # h x v luma samples followed by Cb and Cr).
        def ycbcr_luma(raw, cw, rows)
          raise UnsupportedImageError, "#{@bps}-bit YCbCr TIFF images are not supported" unless @bps == 8

          sh, sv = subsampling
          units = (cw + sh - 1) / sh
          unit_size = sh * sv + 2
          unit_rows = [raw.bytesize / (units * unit_size), (rows + sv - 1) / sv].min
          return nil if unit_rows.zero?

          @decoded += 1
          out = Bytes.buffer(cw * rows)
          unit_rows.times do |ur|
            sv.times do |j|
              break if ur * sv + j >= rows

              ycbcr_row(raw, ur * units * unit_size + j * sh, sh, unit_size, cw, out)
            end
          end
          out
        end

        def ycbcr_row(raw, off, sh, unit_size, cw, out)
          x = 0
          while x < cw
            out << raw.getbyte(off + (x / sh) * unit_size + x % sh)
            x += 1
          end
          out
        end

        def subsampling
          @subsampling ||= begin
            sh, sv = @dir.ints(YCBCR_SUBSAMPLING) || [2, 2]
            sv ||= 2
            unless [1, 2, 4].include?(sh) && [1, 2, 4].include?(sv)
              raise ImageError, "invalid TIFF YCbCr subsampling #{sh}x#{sv}"
            end

            [sh, sv]
          end
        end

        # --- luminance ----------------------------------------------------

        def convert(samples, cw, rows)
          return samples if @mode == :single

          out = Bytes.buffer(cw * rows)
          stride = @stride
          rows.times { |r| convert_row(samples, r * cw * stride, cw, out) }
          out
        end

        # Appends the luminance of +n+ pixels at +off+ to +out+.
        def convert_row(src, off, n, out)
          c = @channels
          stride = @stride
          case @mode
          when :pick then pick(src, off, n, stride, out)
          when :rgb then rgb_row(src, off, n, out, c[0], c[1], c[2], stride)
          when :rgba
            if @associated
              premultiplied_row(src, off, n, out, c[0], c[1], c[2], c[3], stride)
            else
              rgba_row(src, off, n, out, c[0], c[1], c[2], c[3], stride)
            end
          when :gray_alpha then gray_alpha_row(src, off, n, out, c[1], stride)
          when :cmyk then cmyk_row(src, off, n, out, c[0], c[1], c[2], c[3], stride)
          end
        end

        def rgb_row(src, off, n, out, ro, go, bo, stride)
          i = off
          stop = off + n * stride
          while i < stop
            out << ((306 * src.getbyte(i + ro) + 601 * src.getbyte(i + go) + 117 * src.getbyte(i + bo) + 0x200) >> 10)
            i += stride
          end
          out
        end

        # Unassociated alpha, composited over white like Image.from_pixels.
        def rgba_row(src, off, n, out, ro, go, bo, ao, stride)
          i = off
          stop = off + n * stride
          while i < stop
            v = (306 * src.getbyte(i + ro) + 601 * src.getbyte(i + go) + 117 * src.getbyte(i + bo) + 0x200) >> 10
            a = src.getbyte(i + ao)
            out << (a == 255 ? v : (v * a + 255 * (255 - a) + 127) / 255)
            i += stride
          end
          out
        end

        # Associated (premultiplied) alpha: colour + (255 - alpha) of white.
        def premultiplied_row(src, off, n, out, ro, go, bo, ao, stride)
          i = off
          stop = off + n * stride
          while i < stop
            v = ((306 * src.getbyte(i + ro) + 601 * src.getbyte(i + go) + 117 * src.getbyte(i + bo) + 0x200) >> 10) +
                255 - src.getbyte(i + ao)
            out << (v > 255 ? 255 : v)
            i += stride
          end
          out
        end

        def gray_alpha_row(src, off, n, out, ao, stride)
          invert = @invert
          associated = @associated
          i = off
          stop = off + n * stride
          while i < stop
            v = src.getbyte(i)
            a = src.getbyte(i + ao)
            if associated
              v = a - v if invert
              v += 255 - a
              out << (v > 255 ? 255 : v)
            else
              v = 255 - v if invert
              out << (a == 255 ? v : (v * a + 255 * (255 - a) + 127) / 255)
            end
            i += stride
          end
          out
        end

        # Ink amounts (0 = none): R = (255 - C) * (255 - K) / 255, ..., like
        # the JPEG decoder's Adobe CMYK conversion.
        def cmyk_row(src, off, n, out, co, mo, yo, ko, stride)
          i = off
          stop = off + n * stride
          while i < stop
            k = 255 - src.getbyte(i + ko)
            r = ((255 - src.getbyte(i + co)) * k + 127) / 255
            g = ((255 - src.getbyte(i + mo)) * k + 127) / 255
            b = ((255 - src.getbyte(i + yo)) * k + 127) / 255
            out << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
            i += stride
          end
          out
        end
      end

      # TIFF LZW: MSB-first codes of 9 to 12 bits with "early change". Data
      # starting with 0x00 followed by an odd byte is the old LSB-first
      # variant without early change (detected like libtiff does).
      class LZW
        CLEAR = 256
        EOI = 257
        ROOTS = Array.new(256) { |b| b.chr.b.freeze }.freeze
        # Codes decoded per call of #step (YJIT compiles methods, not loops).
        BATCH = 1024

        def initialize(data, expected)
          @data = data + "\0\0\0\0".b
          @nbits = data.bytesize * 8
          @compat = data.start_with?("\0") && data.bytesize > 1 && data.getbyte(1).odd?
          @early = @compat ? 0 : 1
          @expected = expected
          @out = Bytes.buffer(expected)
          @table = ROOTS + [nil, nil]
          @next = 258
          @width = 9
          @pos = 0
          @prev = nil
          @done = false
        end

        def decode
          step until @done
          @out.bytesize > @expected ? @out.byteslice(0, @expected) : @out
        end

        private

        def step
          data = @data
          table = @table
          out = @out
          pos = @pos
          width = @width
          nxt = @next
          prev = @prev
          compat = @compat
          early = @early
          nbits = @nbits
          expected = @expected
          done = false
          n = BATCH
          while n.positive?
            if pos + width > nbits || out.bytesize >= expected
              done = true
              break
            end
            i = pos >> 3
            code = if compat
                     ((data.getbyte(i) | (data.getbyte(i + 1) << 8) | (data.getbyte(i + 2) << 16)) >> (pos & 7)) &
                       ((1 << width) - 1)
                   else
                     (((data.getbyte(i) << 16) | (data.getbyte(i + 1) << 8) | data.getbyte(i + 2)) >>
                       (24 - width - (pos & 7))) & ((1 << width) - 1)
                   end
            pos += width
            if code == CLEAR
              nxt = 258
              width = 9
              prev = nil
            elsif code == EOI
              done = true
              break
            elsif prev.nil?
              if code > 255
                done = true
                break
              end
              prev = table[code]
              out << prev
            else
              if code < nxt
                entry = table[code]
                table[nxt] = prev + ROOTS[entry.getbyte(0)] if nxt < 4096
              elsif code == nxt
                entry = prev + ROOTS[prev.getbyte(0)]
                table[nxt] = entry
              else
                done = true
                break
              end
              out << entry
              prev = entry
              nxt += 1 if nxt < 4096
              width += 1 if width < 12 && nxt + early >= (1 << width)
            end
            n -= 1
          end
          @pos = pos
          @width = width
          @next = nxt
          @prev = prev
          @done = done
        end
      end

      private_constant(*constants)
    end
  end
end
