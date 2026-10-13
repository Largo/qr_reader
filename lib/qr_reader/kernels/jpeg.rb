# frozen_string_literal: true

require_relative "../errors"

# JPEG kernels: a luminance-only JPEG decoder in the Ruby subset that Spinel
# compiles (see DESIGN.md, "Kernels"); QrReader::Formats::JPEG wraps it.
#
# Supported: baseline (SOF0), extended sequential Huffman (SOF1) and
# progressive (SOF2) 8-bit JPEGs with any sampling factors, restart
# intervals, 8/16-bit quantisation tables, 1 component (gray), 3 components
# (YCbCr, or RGB via Adobe APP14 / component ids "RGB") and 4 components
# (Adobe CMYK and YCCK). Arithmetic coding, lossless, hierarchical, 12-bit
# and JPEG-LS files raise UnsupportedImageError. The output matches
# libjpeg-turbo's default "islow" IDCT exactly (as built with SIMD, which
# saturates out-of-range samples), including the reduced IDCTs,
# per-component DCT scaling and upsampling used for scale 2, 4 and 8.
# Truncated scan data decodes what is present (missing blocks stay
# mid-gray); damaged restart intervals are resynchronised by their marker
# numbers; other corruption raises ImageError.
#
# How it stays fast in pure Ruby:
# * For YCbCr only Y is reconstructed (Y is the luminance). Chroma blocks
#   are entropy-decoded and dropped; chroma-only progressive scans (and
#   AC scans at scale 8) are skipped without decoding.
# * Byte stuffing and restart markers are removed per scan at C speed and
#   the scan is unpacked to 32-bit words, so the bit reader never checks
#   for markers.
# * Huffman lookahead tables also carry the run length and sign-extended
#   coefficient, so most coefficients cost a single table lookup.
# * Each block remembers the zigzag index of its last nonzero coefficient,
#   which selects a DC-only fill or an IDCT specialised for the inputs
#   that can be nonzero (derived from libjpeg's formulas).
# * Hot loops live in methods called per MCU, block row or block, so YJIT
#   (which compiles a method once it has been called 30 times) kicks in
#   during the first decode.
# * Samples are collected four to an Array element (32-bit words) per MCU
#   row and packed to bytes at C speed.
#
# Two resolutions for the price of one entropy decoding: jpeg_luma_keep
# also returns the decoded coefficients of the luminance components in a
# compact store (see JpegDecoder#store), from which jpeg_render produces
# any other scale with IDCTs only.
module QrReaderKernels
  # [width, height] from the frame header (the height from a DNL marker
  # when the header gives 0), without decoding.
  # spinel-sample: QrReaderKernels.jpeg_info("\xFF\xD8".b)
  def self.jpeg_info(bytes)
    JpegDecoder.new(bytes, 1, false).info
  end

  # Luminance at 1/+scale+ (1, 2, 4 or 8) of the size, ceil(width / scale)
  # x ceil(height / scale) bytes, row-major.
  # spinel-sample: QrReaderKernels.jpeg_luma("\xFF\xD8".b, 1)
  def self.jpeg_luma(bytes, scale)
    JpegDecoder.new(bytes, scale, false).decode
  end

  # Like jpeg_luma, but also returns the luminance components' coefficients
  # as a compact store for jpeg_render: [luma, store].
  # spinel-sample: QrReaderKernels.jpeg_luma_keep("\xFF\xD8".b, 4)
  def self.jpeg_luma_keep(bytes, scale)
    decoder = JpegDecoder.new(bytes, scale, true)
    luma = decoder.decode
    [luma, decoder.store]
  end

  # Luminance at 1/+scale+ from a coefficient store made by jpeg_luma_keep:
  # the same bytes as jpeg_luma at that scale, without entropy decoding.
  # spinel-sample: QrReaderKernels.jpeg_render("\x00".b, 1)
  def self.jpeg_render(store, scale)
    JpegDecoder.new(store, scale, false).render_store
  end

  # --- Tables -------------------------------------------------------------

  # Lookahead bits of the Huffman fast tables.
  JPEG_FAST_BITS = 10
  JPEG_FAST_MASK = (1 << JPEG_FAST_BITS) - 1

  # Run used for end-of-block in the AC fast tables: it pushes the
  # coefficient index past 63, ending the block loop without a branch.
  # A block loop that ended at k > JPEG_EOB_RUN had its EOB at k - EOB_RUN - 1.
  JPEG_EOB_RUN = 100

  # Zigzag index -> natural (row-major) index.
  JPEG_ZIGZAG = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
  ].freeze

  # JPEG_ZIGZAG extended for corrupt runs past 63 (clamped to 63 like
  # libjpeg) and for the end-of-block pseudo run (scratch slot 64).
  JPEG_ZIGZAG_EXT = (JPEG_ZIGZAG + Array.new(16, 63) + Array.new(JPEG_EOB_RUN + 4 - 16, 64)).freeze

  # Entries per block of stored progressive coefficients: 64 coefficients
  # in natural order (not dequantised) and, at index 64, the zigzag index
  # of the last nonzero one. (Without the store, scale 8 only keeps DCs.)
  JPEG_BLOCK_STRIDE = 65

  # Decoded samples are buffered as packed little-endian words (first
  # sample in the low byte: "V*" packs faster than "N*"). By output block
  # size (8 / scale): samples per word, words per block row, the factor
  # that repeats a sample over a word, and the pack directive.
  JPEG_SAMPLES_PER_WORD = [0, 1, 2, 0, 4, 0, 0, 0, 4].freeze
  JPEG_WORDS = [0, 1, 1, 0, 1, 0, 0, 0, 2].freeze
  JPEG_SPREAD = [0, 1, 0x0101, 0, 0x01010101, 0, 0, 0, 0x01010101].freeze
  JPEG_PACK = ["", "C*", "v*", "", "V*", "", "", "", "V*"].freeze

  # Largest supported output (64 Mi pixels, e.g. 8192 x 8192); bigger
  # images need a larger scale. Guards against absurd header sizes.
  JPEG_MAX_PIXELS = 1 << 26

  # Most coefficients (Array entries, 576 MiB) a progressive JPEG may
  # store: enough for one needed component of a MAX_PIXELS image, but not
  # for four (CMYK) of that size, which need a larger scale.
  JPEG_MAX_COEFFICIENTS = 72 << 20

  # Block visits (blocks covered by decoded scans) per block of the needed
  # components after which the rest of a file is ignored: real progressive
  # files make about 3 to 10, but crafted ones could repeat cheap scans
  # (e.g. end-of-band runs over the whole image).
  JPEG_MAX_VISITS = 64

  # Decoded scans after which the rest of a file is ignored: crafted files
  # with endless refinement scans could otherwise take very long (real
  # progressive files have about 6 to 20 scans).
  JPEG_MAX_SCANS = 256

  # Colour spaces of the stored components.
  JPEG_GRAY = 0
  JPEG_YCBCR = 1
  JPEG_RGB = 2
  JPEG_CMYK = 3
  JPEG_YCCK = 4
  JPEG_OTHER = 5

  # Standard Huffman tables (ITU T.81 Annex K.3), used when a scan refers
  # to an undefined table 0 or 1 (Motion-JPEG frames omit them), like
  # libjpeg-turbo does: code counts per length and symbols.
  JPEG_STD_DC_COUNTS = [
    [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
  ].freeze
  JPEG_STD_DC_SYMBOLS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].freeze
  JPEG_STD_AC_COUNTS = [
    [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d], [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
  ].freeze
  JPEG_STD_AC_SYMBOLS = [
    [
      0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
      0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
      0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
      0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
      0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
      0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
      0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
      0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
      0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
      0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
      0xf9, 0xfa
    ],
    [
      0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
      0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
      0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
      0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
      0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
      0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
      0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
      0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
      0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
      0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
      0xf9, 0xfa
    ]
  ].freeze

  # Post-IDCT range limiting of libjpeg-turbo's 8x8, 4x4 and 2x2 IDCTs,
  # whose SIMD versions (used on x86 and ARM) saturate: indexed by
  # (sample + 128) & 0xFFFF, clamps samples within +-32767 to 0..255.
  def self.jpeg_clamp_table
    t = Array.new(65_536, 0)
    i = 0
    while i < 32_896
      t[i] = i < 256 ? i : 255
      i += 1
    end
    t
  end

  # libjpeg's C range-limit table (used by its 1x1 IDCT at scale 8),
  # indexed by (sample + 128) & 1023: clamps to 0..255 near the valid range
  # but wraps far out-of-range samples around.
  def self.jpeg_range_limit_table
    t = Array.new(1024, 0)
    i = 0
    while i < 1024
      c = (i - 128) & 1023
      t[i] = if c < 128 then c + 128
             elsif c < 512 then 255
             elsif c < 896 then 0
             else c - 896
             end
      i += 1
    end
    t
  end

  # libjpeg's YCbCr -> RGB tables (jdcolor.c, 16-bit fixed point), indexed
  # by the Cb/Cr sample: Cr -> R, Cb -> B, Cr -> G and Cb -> G (+ rounding).
  def self.jpeg_color_table(kind)
    t = Array.new(256, 0)
    i = 0
    while i < 256
      x = i - 128
      t[i] = case kind
             when 0 then (91_881 * x + 32_768) >> 16
             when 1 then (116_130 * x + 32_768) >> 16
             when 2 then -46_802 * x
             else -22_554 * x + 32_768
             end
      i += 1
    end
    t
  end

  JPEG_CLAMP = jpeg_clamp_table.freeze
  JPEG_RANGE_LIMIT = jpeg_range_limit_table.freeze
  JPEG_CR_R = jpeg_color_table(0).freeze
  JPEG_CB_B = jpeg_color_table(1).freeze
  JPEG_CR_G = jpeg_color_table(2).freeze
  JPEG_CB_G = jpeg_color_table(3).freeze

  # A shared empty Array: "not defined" tables, unallocated coefficient rows.
  JPEG_NONE = Array.new(0, 0).freeze

  JPEG_FF = "\xFF".b.freeze
  JPEG_DNL_MARKER = "\xFF\xDC\x00\x04".b.freeze
  # Zero bytes appended to a scan: more than one MCU can consume, so a
  # truncated MCU never reads past the end of the word array.
  JPEG_TAIL_PADDING = ("\0" * 4096).b.freeze

  # First Integer of a coefficient store.
  JPEG_STORE_MAGIC = 0x314B_504A # "JPK1"

  # Name of an unsupported frame type (SOF marker code).
  def self.jpeg_sof_name(code)
    case code
    when 0xC3 then "lossless"
    when 0xC5 then "hierarchical"
    when 0xC6 then "hierarchical progressive"
    when 0xC7 then "hierarchical lossless"
    when 0xC9 then "arithmetic-coded"
    when 0xCA then "arithmetic-coded progressive"
    when 0xCB then "arithmetic-coded lossless"
    when 0xCD then "arithmetic-coded hierarchical"
    when 0xCE then "arithmetic-coded hierarchical progressive"
    when 0xCF then "arithmetic-coded hierarchical lossless"
    else "JPEG-LS"
    end
  end

  # Raised internally when the data ends early; decoding then finishes with
  # what was decoded so far.
  class JpegTruncated < QrReader::ImageError; end

  # A Huffman table with FAST_BITS lookahead tables.
  #
  # +look+ maps the next FAST_BITS bits to (code length << 8 | symbol), or 0
  # for longer codes (see #decode_long). +fast+ also folds in the extra
  # bits: (value << 16) | (run << 8) | (total bit length), or 0 when code
  # and extra bits do not fit in FAST_BITS. Zero-valued AC entries are the
  # end-of-block (run JPEG_EOB_RUN) and ZRL (run 15) symbols.
  class JpegHuffman
    attr_reader :fast, :look

    # +counts+: number of codes of each length 1..16; +symbols+ in code order.
    def initialize(counts, symbols, ac)
      @fast = Array.new(1 << JPEG_FAST_BITS, 0)
      @look = Array.new(1 << JPEG_FAST_BITS, 0)
      @maxcode = Array.new(18, 0)
      @valoff = Array.new(17, 0)
      @symbols = symbols
      code = 0
      index = 0
      len = 1
      while len <= 16
        n = counts[len - 1]
        @valoff[len] = index - code
        i = 0
        while i < n
          sym = symbols[index]
          raise QrReader::ImageError, "corrupt JPEG: bad DC Huffman symbol #{sym}" if !ac && sym > 15

          add_entries(code, len, sym, ac) if len <= JPEG_FAST_BITS
          code += 1
          index += 1
          i += 1
        end
        # Codes must fit in len bits and may not be all ones (like libjpeg).
        raise QrReader::ImageError, "corrupt JPEG: bad Huffman table" if n > 0 && code >= (1 << len)

        @maxcode[len] = code << (16 - len)
        code <<= 1
        len += 1
      end
      @maxcode[17] = 1 << 17
    end

    # Decodes a code longer than FAST_BITS from the next 16 bits. Returns
    # (length << 8) | symbol; an invalid code yields symbol 0 and length 16
    # ("fake a zero", like libjpeg).
    def decode_long(window)
      len = JPEG_FAST_BITS + 1
      len += 1 while window >= @maxcode[len]
      return 16 << 8 if len > 16

      (len << 8) | @symbols[(window >> (16 - len)) + @valoff[len]]
    end

    private

    def add_entries(code, len, sym, ac)
      shift = JPEG_FAST_BITS - len
      base = code << shift
      @look.fill((len << 8) | sym, base, 1 << shift)
      if ac
        run = sym >> 4
        size = sym & 15
      else
        run = 0
        size = sym
      end
      if size == 0
        # DC: difference 0. AC: ZRL, or end of block (libjpeg treats every
        # other zero-size symbol in sequential scans as EOB).
        run = JPEG_EOB_RUN if ac && run != 15
        @fast.fill((run << 8) | len, base, 1 << shift)
      elsif size <= shift
        rest = shift - size
        count = 1 << rest
        head = (run << 8) | (len + size)
        half = 1 << (size - 1)
        offset = (1 << size) - 1
        v = 0
        while v <= offset
          value = v < half ? v - offset : v
          @fast.fill((value << 16) | head, base | (v << rest), count)
          v += 1
        end
      end
    end
  end

  # Frame component state.
  class JpegComponent
    attr_reader :index, :id, :h, :v, :tq
    # Sample size at full scale, blocks covered by a non-interleaved scan,
    # allocated block grid (padded to whole MCUs) and plane size in samples.
    attr_accessor :cw, :ch, :bw, :bh, :abw, :abh, :pw, :ph
    # Whether the component contributes to the luminance output.
    attr_accessor :needed
    # Output size of its blocks (libjpeg's DCT_scaled_size: 8, 4, 2 or 1)
    # and the IDCT producing them.
    attr_accessor :bs, :idct
    # Output plane (binary String, pw x ph, filled row by row), and for
    # progressive JPEGs the coefficients: one Array per block row (JPEG_NONE
    # until data arrives) with +stride+ entries per block.
    attr_accessor :plane, :coefs, :stride
    # Latched dequantisation table, indexed by (extended) zigzag position.
    attr_accessor :qz
    # Coefficient store: entry data and the byte offset of each block row.
    attr_reader :sdata, :srows

    def initialize(index, id, h, v, tq)
      @index = index
      @id = id
      @h = h
      @v = v
      @tq = tq
      @needed = false
      @plane = "".b
      @coefs = []
      @stride = JPEG_BLOCK_STRIDE
      @qz = JPEG_NONE
      @sdata = "".b
      @srows = []
    end

    # Appends one block row of store entries (see JpegDecoder#store).
    def store_row(entries)
      return if @srows.size >= @abh

      @srows << @sdata.bytesize
      @sdata << entries.pack("s<*")
    end

    # Pads the store with all-zero (mid-gray) block rows up to the full
    # height.
    def store_finish
      return if @srows.size >= @abh

      row = []
      i = 0
      while i < @abw
        row << 0 << 0
        i += 1
      end
      row = row.pack("s<*")
      while @srows.size < @abh
        @srows << @sdata.bytesize
        @sdata << row
      end
    end
  end

  # Inverse DCTs, bit-exact with libjpeg's jidctint.c ("islow", 8x8 output)
  # and jidctred.c (4x4 and 2x2 output for scaled decoding).
  #
  # The idct<size>_<n> methods are libjpeg's 1-D kernels specialised for
  # blocks whose nonzero coefficients lie in the top-left n x n corner
  # (dropping zero terms changes nothing in integer arithmetic). Rounding
  # and the +128 level shift are folded into the DC term of each pass.
  #
  # Input: dequantised coefficients in natural order at c[base, 64].
  # Output: a bs x bs block written to the Array +out+ as packed
  # little-endian words (JPEG_WORDS[bs] per block row) at word offset
  # +off+ with row stride +stride+ (in words). Writing four samples per
  # Array element instead of one is markedly faster under YJIT.
  #
  # One instance (with a fixed set of instance variables, which keeps
  # YJIT's code monomorphic) serves a whole decode.
  class JpegIDCT
    attr_reader :bs

    # +bs+: output block size 8, 4, 2 or 1 (1 needs no IDCT, only #fill).
    def initialize(bs)
      @bs = bs
      @ws = Array.new(64, 0)
    end

    # IDCT of the block at c[base, 64] whose last nonzero coefficient has
    # zigzag index +km+ (> 0; DC-only blocks are filled by callers).
    def transform(c, base, km, out, off, stride)
      bs = @bs
      if bs == 8
        if km <= 2 then idct8_2(c, base, out, off, stride)
        elsif km <= 9 then idct8_4(c, base, out, off, stride)
        elsif km <= 20 then idct8_6(c, base, out, off, stride)
        else idct8_8(c, base, out, off, stride)
        end
      elsif bs == 4
        if km <= 2 then idct4_2(c, base, out, off, stride)
        elsif km <= 9 then idct4_4(c, base, out, off, stride)
        else idct4_8(c, base, out, off, stride)
        end
      elsif km <= 2
        idct2_2(c, base, out, off, stride)
      else
        idct2_8(c, base, out, off, stride)
      end
    end

    # Sample of a DC-only block (the same for every IDCT size, except that
    # libjpeg-turbo's 1x1 IDCT wraps instead of saturating).
    def dc_sample(dequantised_dc)
      if @bs == 1
        JPEG_RANGE_LIMIT[((dequantised_dc + 1028) >> 3) & 1023]
      else
        JPEG_CLAMP[((dequantised_dc + 1028) >> 3) & 0xFFFF]
      end
    end

    # Fills a bs x bs block of +out+ (packed words) with sample +value+.
    def fill(out, off, stride, value)
      bs = @bs
      v = value * JPEG_SPREAD[bs]
      r = 0
      if bs == 8
        while r < 8
          out[off] = v
          out[off + 1] = v
          off += stride
          r += 1
        end
      else
        while r < bs
          out[off] = v
          off += stride
          r += 1
        end
      end
    end

    def idct8_2(c, base, out, off, stride)
      rl = JPEG_CLAMP
      ws = @ws
      i = 0
      ci = base
      while i <= 1
        d0 = c[ci]
        d1 = c[ci + 8]
        if d1 == 0
          ws[i] = ws[i + 8] = ws[i + 16] = ws[i + 24] = ws[i + 32] = ws[i + 40] = ws[i + 48] = ws[i + 56] = d0 << 2
        else
          t0 = (d0 << 13) + 1024
          o3 = d1 * 11_363
          o2 = d1 * 9633
          o1 = d1 * 6437
          o0 = d1 * 2260
          ws[i] = (t0 + o3) >> 11
          ws[i + 8] = (t0 + o2) >> 11
          ws[i + 16] = (t0 + o1) >> 11
          ws[i + 24] = (t0 + o0) >> 11
          ws[i + 32] = (t0 - o0) >> 11
          ws[i + 40] = (t0 - o1) >> 11
          ws[i + 48] = (t0 - o2) >> 11
          ws[i + 56] = (t0 - o3) >> 11
        end
        i += 1
        ci = base + i
      end
      i = 0
      while i < 64
        d0 = ws[i]
        d1 = ws[i + 1]
        if d1 == 0
          v = rl[((d0 + 4112) >> 5) & 0xFFFF] * 0x1010101
          out[off] = v
          out[off + 1] = v
        else
          t0 = (d0 + 4112) << 13
          o3 = d1 * 11_363
          o2 = d1 * 9633
          o1 = d1 * 6437
          o0 = d1 * 2260
          out[off] = rl[((t0 + o3) >> 18) & 0xFFFF] | (rl[((t0 + o2) >> 18) & 0xFFFF] << 8) | (rl[((t0 + o1) >> 18) & 0xFFFF] << 16) | (rl[((t0 + o0) >> 18) & 0xFFFF] << 24)
          out[off + 1] = rl[((t0 - o0) >> 18) & 0xFFFF] | (rl[((t0 - o1) >> 18) & 0xFFFF] << 8) | (rl[((t0 - o2) >> 18) & 0xFFFF] << 16) | (rl[((t0 - o3) >> 18) & 0xFFFF] << 24)
        end
        off += stride
        i += 8
      end
    end

    def idct8_4(c, base, out, off, stride)
      rl = JPEG_CLAMP
      ws = @ws
      i = 0
      ci = base
      while i <= 3
        d0 = c[ci]
        d1 = c[ci + 8]
        d2 = c[ci + 16]
        d3 = c[ci + 24]
        if d1 == 0 && d2 == 0 && d3 == 0
          ws[i] = ws[i + 8] = ws[i + 16] = ws[i + 24] = ws[i + 32] = ws[i + 40] = ws[i + 48] = ws[i + 56] = d0 << 2
        else
          t0 = (d0 << 13) + 1024
          t2 = d2 * 4433
          t3 = d2 * 10_703
          t10 = t0 + t3
          t13 = t0 - t3
          t11 = t0 + t2
          t12 = t0 - t2
          o0 = d1 * 2260 - d3 * 6436
          o1 = d1 * 6437 - d3 * 11_362
          o2 = d1 * 9633 - d3 * 2259
          o3 = d1 * 11_363 + d3 * 9633
          ws[i] = (t10 + o3) >> 11
          ws[i + 8] = (t11 + o2) >> 11
          ws[i + 16] = (t12 + o1) >> 11
          ws[i + 24] = (t13 + o0) >> 11
          ws[i + 32] = (t13 - o0) >> 11
          ws[i + 40] = (t12 - o1) >> 11
          ws[i + 48] = (t11 - o2) >> 11
          ws[i + 56] = (t10 - o3) >> 11
        end
        i += 1
        ci = base + i
      end
      i = 0
      while i < 64
        d0 = ws[i]
        d1 = ws[i + 1]
        d2 = ws[i + 2]
        d3 = ws[i + 3]
        if d1 == 0 && d2 == 0 && d3 == 0
          v = rl[((d0 + 4112) >> 5) & 0xFFFF] * 0x1010101
          out[off] = v
          out[off + 1] = v
        else
          t0 = (d0 + 4112) << 13
          t2 = d2 * 4433
          t3 = d2 * 10_703
          t10 = t0 + t3
          t13 = t0 - t3
          t11 = t0 + t2
          t12 = t0 - t2
          o0 = d1 * 2260 - d3 * 6436
          o1 = d1 * 6437 - d3 * 11_362
          o2 = d1 * 9633 - d3 * 2259
          o3 = d1 * 11_363 + d3 * 9633
          out[off] = rl[((t10 + o3) >> 18) & 0xFFFF] | (rl[((t11 + o2) >> 18) & 0xFFFF] << 8) | (rl[((t12 + o1) >> 18) & 0xFFFF] << 16) | (rl[((t13 + o0) >> 18) & 0xFFFF] << 24)
          out[off + 1] = rl[((t13 - o0) >> 18) & 0xFFFF] | (rl[((t12 - o1) >> 18) & 0xFFFF] << 8) | (rl[((t11 - o2) >> 18) & 0xFFFF] << 16) | (rl[((t10 - o3) >> 18) & 0xFFFF] << 24)
        end
        off += stride
        i += 8
      end
    end

    def idct8_6(c, base, out, off, stride)
      rl = JPEG_CLAMP
      ws = @ws
      i = 0
      ci = base
      while i <= 5
        d0 = c[ci]
        d1 = c[ci + 8]
        d2 = c[ci + 16]
        d3 = c[ci + 24]
        d4 = c[ci + 32]
        d5 = c[ci + 40]
        if d1 == 0 && d2 == 0 && d3 == 0 && d4 == 0 && d5 == 0
          ws[i] = ws[i + 8] = ws[i + 16] = ws[i + 24] = ws[i + 32] = ws[i + 40] = ws[i + 48] = ws[i + 56] = d0 << 2
        else
          t0 = ((d0 + d4) << 13) + 1024
          t1 = ((d0 - d4) << 13) + 1024
          t2 = d2 * 4433
          t3 = d2 * 10_703
          t10 = t0 + t3
          t13 = t0 - t3
          t11 = t1 + t2
          t12 = t1 - t2
          z2 = d5 + d3
          z4 = d5 + d1
          z5 = (z4 + d3) * 9633
          z1 = d1 * -7373
          z2 *= -20_995
          z3 = d3 * -16_069 + z5
          z4 = z4 * -3196 + z5
          o0 = z1 + z3
          o1 = d5 * 16_819 + z2 + z4
          o2 = d3 * 25_172 + z2 + z3
          o3 = d1 * 12_299 + z1 + z4
          ws[i] = (t10 + o3) >> 11
          ws[i + 8] = (t11 + o2) >> 11
          ws[i + 16] = (t12 + o1) >> 11
          ws[i + 24] = (t13 + o0) >> 11
          ws[i + 32] = (t13 - o0) >> 11
          ws[i + 40] = (t12 - o1) >> 11
          ws[i + 48] = (t11 - o2) >> 11
          ws[i + 56] = (t10 - o3) >> 11
        end
        i += 1
        ci = base + i
      end
      i = 0
      while i < 64
        d0 = ws[i]
        d1 = ws[i + 1]
        d2 = ws[i + 2]
        d3 = ws[i + 3]
        d4 = ws[i + 4]
        d5 = ws[i + 5]
        if d1 == 0 && d2 == 0 && d3 == 0 && d4 == 0 && d5 == 0
          v = rl[((d0 + 4112) >> 5) & 0xFFFF] * 0x1010101
          out[off] = v
          out[off + 1] = v
        else
          t0 = ((d0 + d4) + 4112) << 13
          t1 = ((d0 - d4) + 4112) << 13
          t2 = d2 * 4433
          t3 = d2 * 10_703
          t10 = t0 + t3
          t13 = t0 - t3
          t11 = t1 + t2
          t12 = t1 - t2
          z2 = d5 + d3
          z4 = d5 + d1
          z5 = (z4 + d3) * 9633
          z1 = d1 * -7373
          z2 *= -20_995
          z3 = d3 * -16_069 + z5
          z4 = z4 * -3196 + z5
          o0 = z1 + z3
          o1 = d5 * 16_819 + z2 + z4
          o2 = d3 * 25_172 + z2 + z3
          o3 = d1 * 12_299 + z1 + z4
          out[off] = rl[((t10 + o3) >> 18) & 0xFFFF] | (rl[((t11 + o2) >> 18) & 0xFFFF] << 8) | (rl[((t12 + o1) >> 18) & 0xFFFF] << 16) | (rl[((t13 + o0) >> 18) & 0xFFFF] << 24)
          out[off + 1] = rl[((t13 - o0) >> 18) & 0xFFFF] | (rl[((t12 - o1) >> 18) & 0xFFFF] << 8) | (rl[((t11 - o2) >> 18) & 0xFFFF] << 16) | (rl[((t10 - o3) >> 18) & 0xFFFF] << 24)
        end
        off += stride
        i += 8
      end
    end

    def idct8_8(c, base, out, off, stride)
      rl = JPEG_CLAMP
      ws = @ws
      i = 0
      ci = base
      while i <= 7
        d0 = c[ci]
        d1 = c[ci + 8]
        d2 = c[ci + 16]
        d3 = c[ci + 24]
        d4 = c[ci + 32]
        d5 = c[ci + 40]
        d6 = c[ci + 48]
        d7 = c[ci + 56]
        if d1 == 0 && d2 == 0 && d3 == 0 && d4 == 0 && d5 == 0 && d6 == 0 && d7 == 0
          ws[i] = ws[i + 8] = ws[i + 16] = ws[i + 24] = ws[i + 32] = ws[i + 40] = ws[i + 48] = ws[i + 56] = d0 << 2
        else
          z1 = (d2 + d6) * 4433
          t2 = z1 - d6 * 15_137
          t3 = z1 + d2 * 6270
          t0 = ((d0 + d4) << 13) + 1024
          t1 = ((d0 - d4) << 13) + 1024
          t10 = t0 + t3
          t13 = t0 - t3
          t11 = t1 + t2
          t12 = t1 - t2
          z1 = d7 + d1
          z2 = d5 + d3
          z3 = d7 + d3
          z4 = d5 + d1
          z5 = (z3 + z4) * 9633
          z1 *= -7373
          z2 *= -20_995
          z3 = z3 * -16_069 + z5
          z4 = z4 * -3196 + z5
          o0 = d7 * 2446 + z1 + z3
          o1 = d5 * 16_819 + z2 + z4
          o2 = d3 * 25_172 + z2 + z3
          o3 = d1 * 12_299 + z1 + z4
          ws[i] = (t10 + o3) >> 11
          ws[i + 8] = (t11 + o2) >> 11
          ws[i + 16] = (t12 + o1) >> 11
          ws[i + 24] = (t13 + o0) >> 11
          ws[i + 32] = (t13 - o0) >> 11
          ws[i + 40] = (t12 - o1) >> 11
          ws[i + 48] = (t11 - o2) >> 11
          ws[i + 56] = (t10 - o3) >> 11
        end
        i += 1
        ci = base + i
      end
      i = 0
      while i < 64
        d0 = ws[i]
        d1 = ws[i + 1]
        d2 = ws[i + 2]
        d3 = ws[i + 3]
        d4 = ws[i + 4]
        d5 = ws[i + 5]
        d6 = ws[i + 6]
        d7 = ws[i + 7]
        if d1 == 0 && d2 == 0 && d3 == 0 && d4 == 0 && d5 == 0 && d6 == 0 && d7 == 0
          v = rl[((d0 + 4112) >> 5) & 0xFFFF] * 0x1010101
          out[off] = v
          out[off + 1] = v
        else
          z1 = (d2 + d6) * 4433
          t2 = z1 - d6 * 15_137
          t3 = z1 + d2 * 6270
          t0 = ((d0 + d4) + 4112) << 13
          t1 = ((d0 - d4) + 4112) << 13
          t10 = t0 + t3
          t13 = t0 - t3
          t11 = t1 + t2
          t12 = t1 - t2
          z1 = d7 + d1
          z2 = d5 + d3
          z3 = d7 + d3
          z4 = d5 + d1
          z5 = (z3 + z4) * 9633
          z1 *= -7373
          z2 *= -20_995
          z3 = z3 * -16_069 + z5
          z4 = z4 * -3196 + z5
          o0 = d7 * 2446 + z1 + z3
          o1 = d5 * 16_819 + z2 + z4
          o2 = d3 * 25_172 + z2 + z3
          o3 = d1 * 12_299 + z1 + z4
          out[off] = rl[((t10 + o3) >> 18) & 0xFFFF] | (rl[((t11 + o2) >> 18) & 0xFFFF] << 8) | (rl[((t12 + o1) >> 18) & 0xFFFF] << 16) | (rl[((t13 + o0) >> 18) & 0xFFFF] << 24)
          out[off + 1] = rl[((t13 - o0) >> 18) & 0xFFFF] | (rl[((t12 - o1) >> 18) & 0xFFFF] << 8) | (rl[((t11 - o2) >> 18) & 0xFFFF] << 16) | (rl[((t10 - o3) >> 18) & 0xFFFF] << 24)
        end
        off += stride
        i += 8
      end
    end

    def idct4_2(c, base, out, off, stride)
      rl = JPEG_CLAMP
      ws = @ws
      i = 0
      ci = base
      while i <= 1
        d0 = c[ci]
        d1 = c[ci + 8]
        if d1 == 0
          ws[i] = ws[i + 8] = ws[i + 16] = ws[i + 24] = d0 << 2
        else
          t0 = (d0 << 14) + 2048
          t2 = 0
          t10 = t0 + t2
          t12 = t0 - t2
          o0 = d1 * 8697
          o2 = d1 * 20_995
          ws[i] = (t10 + o2) >> 12
          ws[i + 8] = (t12 + o0) >> 12
          ws[i + 16] = (t12 - o0) >> 12
          ws[i + 24] = (t10 - o2) >> 12
        end
        i += 1
        ci = base + i
      end
      i = 0
      while i < 32
        d0 = ws[i]
        d1 = ws[i + 1]
        if d1 == 0
          v = rl[((d0 + 4112) >> 5) & 0xFFFF] * 0x1010101
          out[off] = v
        else
          t0 = (d0 + 4112) << 14
          t2 = 0
          t10 = t0 + t2
          t12 = t0 - t2
          o0 = d1 * 8697
          o2 = d1 * 20_995
          out[off] = rl[((t10 + o2) >> 19) & 0xFFFF] | (rl[((t12 + o0) >> 19) & 0xFFFF] << 8) | (rl[((t12 - o0) >> 19) & 0xFFFF] << 16) | (rl[((t10 - o2) >> 19) & 0xFFFF] << 24)
        end
        off += stride
        i += 8
      end
    end

    def idct4_4(c, base, out, off, stride)
      rl = JPEG_CLAMP
      ws = @ws
      i = 0
      ci = base
      while i <= 3
        d0 = c[ci]
        d1 = c[ci + 8]
        d2 = c[ci + 16]
        d3 = c[ci + 24]
        if d1 == 0 && d2 == 0 && d3 == 0
          ws[i] = ws[i + 8] = ws[i + 16] = ws[i + 24] = d0 << 2
        else
          t0 = (d0 << 14) + 2048
          t2 = d2 * 15_137
          t10 = t0 + t2
          t12 = t0 - t2
          o0 = d3 * -17_799 + d1 * 8697
          o2 = d3 * 7373 + d1 * 20_995
          ws[i] = (t10 + o2) >> 12
          ws[i + 8] = (t12 + o0) >> 12
          ws[i + 16] = (t12 - o0) >> 12
          ws[i + 24] = (t10 - o2) >> 12
        end
        i += 1
        ci = base + i
      end
      i = 0
      while i < 32
        d0 = ws[i]
        d1 = ws[i + 1]
        d2 = ws[i + 2]
        d3 = ws[i + 3]
        if d1 == 0 && d2 == 0 && d3 == 0
          v = rl[((d0 + 4112) >> 5) & 0xFFFF] * 0x1010101
          out[off] = v
        else
          t0 = (d0 + 4112) << 14
          t2 = d2 * 15_137
          t10 = t0 + t2
          t12 = t0 - t2
          o0 = d3 * -17_799 + d1 * 8697
          o2 = d3 * 7373 + d1 * 20_995
          out[off] = rl[((t10 + o2) >> 19) & 0xFFFF] | (rl[((t12 + o0) >> 19) & 0xFFFF] << 8) | (rl[((t12 - o0) >> 19) & 0xFFFF] << 16) | (rl[((t10 - o2) >> 19) & 0xFFFF] << 24)
        end
        off += stride
        i += 8
      end
    end

    def idct4_8(c, base, out, off, stride)
      rl = JPEG_CLAMP
      ws = @ws
      i = 0
      ci = base
      while i <= 7
        d0 = c[ci]
        d1 = c[ci + 8]
        d2 = c[ci + 16]
        d3 = c[ci + 24]
        d5 = c[ci + 40]
        d6 = c[ci + 48]
        d7 = c[ci + 56]
        if d1 == 0 && d2 == 0 && d3 == 0 && d5 == 0 && d6 == 0 && d7 == 0
          ws[i] = ws[i + 8] = ws[i + 16] = ws[i + 24] = d0 << 2
        else
          t0 = (d0 << 14) + 2048
          t2 = d2 * 15_137 + d6 * -6270
          t10 = t0 + t2
          t12 = t0 - t2
          o0 = d7 * -1730 + d5 * 11_893 + d3 * -17_799 + d1 * 8697
          o2 = d7 * -4176 + d5 * -4926 + d3 * 7373 + d1 * 20_995
          ws[i] = (t10 + o2) >> 12
          ws[i + 8] = (t12 + o0) >> 12
          ws[i + 16] = (t12 - o0) >> 12
          ws[i + 24] = (t10 - o2) >> 12
        end
        i += (i == 3 ? 2 : 1)
        ci = base + i
      end
      i = 0
      while i < 32
        d0 = ws[i]
        d1 = ws[i + 1]
        d2 = ws[i + 2]
        d3 = ws[i + 3]
        d5 = ws[i + 5]
        d6 = ws[i + 6]
        d7 = ws[i + 7]
        if d1 == 0 && d2 == 0 && d3 == 0 && d5 == 0 && d6 == 0 && d7 == 0
          v = rl[((d0 + 4112) >> 5) & 0xFFFF] * 0x1010101
          out[off] = v
        else
          t0 = (d0 + 4112) << 14
          t2 = d2 * 15_137 + d6 * -6270
          t10 = t0 + t2
          t12 = t0 - t2
          o0 = d7 * -1730 + d5 * 11_893 + d3 * -17_799 + d1 * 8697
          o2 = d7 * -4176 + d5 * -4926 + d3 * 7373 + d1 * 20_995
          out[off] = rl[((t10 + o2) >> 19) & 0xFFFF] | (rl[((t12 + o0) >> 19) & 0xFFFF] << 8) | (rl[((t12 - o0) >> 19) & 0xFFFF] << 16) | (rl[((t10 - o2) >> 19) & 0xFFFF] << 24)
        end
        off += stride
        i += 8
      end
    end

    def idct2_2(c, base, out, off, stride)
      rl = JPEG_CLAMP
      ws = @ws
      i = 0
      ci = base
      while i <= 1
        d0 = c[ci]
        d1 = c[ci + 8]
        if d1 == 0
          ws[i] = ws[i + 8] = d0 << 2
        else
          t10 = (d0 << 15) + 4096
          t0 = d1 * 29_692
          ws[i] = (t10 + t0) >> 13
          ws[i + 8] = (t10 - t0) >> 13
        end
        i += 1
        ci = base + i
      end
      i = 0
      while i < 16
        d0 = ws[i]
        d1 = ws[i + 1]
        if d1 == 0
          v = rl[((d0 + 4112) >> 5) & 0xFFFF] * 0x101
          out[off] = v
        else
          t10 = (d0 + 4112) << 15
          t0 = d1 * 29_692
          out[off] = rl[((t10 + t0) >> 20) & 0xFFFF] | (rl[((t10 - t0) >> 20) & 0xFFFF] << 8)
        end
        off += stride
        i += 8
      end
    end

    def idct2_8(c, base, out, off, stride)
      rl = JPEG_CLAMP
      ws = @ws
      i = 0
      ci = base
      while i <= 7
        d0 = c[ci]
        d1 = c[ci + 8]
        d3 = c[ci + 24]
        d5 = c[ci + 40]
        d7 = c[ci + 56]
        if d1 == 0 && d3 == 0 && d5 == 0 && d7 == 0
          ws[i] = ws[i + 8] = d0 << 2
        else
          t10 = (d0 << 15) + 4096
          t0 = d7 * -5906 + d5 * 6967 + d3 * -10_426 + d1 * 29_692
          ws[i] = (t10 + t0) >> 13
          ws[i + 8] = (t10 - t0) >> 13
        end
        i += (i == 1 || i == 3 || i == 5 ? 2 : 1)
        ci = base + i
      end
      i = 0
      while i < 16
        d0 = ws[i]
        d1 = ws[i + 1]
        d3 = ws[i + 3]
        d5 = ws[i + 5]
        d7 = ws[i + 7]
        if d1 == 0 && d3 == 0 && d5 == 0 && d7 == 0
          v = rl[((d0 + 4112) >> 5) & 0xFFFF] * 0x101
          out[off] = v
        else
          t10 = (d0 + 4112) << 15
          t0 = d7 * -5906 + d5 * 6967 + d3 * -10_426 + d1 * 29_692
          out[off] = rl[((t10 + t0) >> 20) & 0xFFFF] | (rl[((t10 - t0) >> 20) & 0xFFFF] << 8)
        end
        off += stride
        i += 8
      end
    end
  end

  # Decoder state for one JPEG stream, or for rendering a coefficient store.
  class JpegDecoder
    # Restart interval, MCU grid and whether to keep a coefficient store.
    attr_reader :restart_interval, :mcux, :mcuy, :keep

    # +bytes+: the JPEG (or a coefficient store for #render_store).
    def initialize(bytes, scale, keep)
      @data = bytes
      @scale = scale
      @bs = 8 / scale
      @keep = keep
      @qt = [JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE]
      # Huffman table definitions and built tables: DC 0..3, AC 4..7.
      @hcounts = [JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE]
      @hsymbols = [JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE, JPEG_NONE]
      @htables = []
      @hbuilt = [false, false, false, false, false, false, false, false]
      @restart_interval = 0
      @jfif = false
      @adobe_transform = -1
      @components = []
      @scans_decoded = 0
      @marker_end = 0
      @precision = 0
      @width = 0
      @height = 0
      @progressive = false
      @frame_end = 0
      @hmax = 0
      @vmax = 0
      @mcux = 0
      @mcuy = 0
      @out_w = 0
      @out_h = 0
      @color = JPEG_GRAY
      @scanned = []
      @visits = 0
      @max_visits = 0
      @seg_fill = false
      @starts = []
      @ends = []
    end

    def info
      begin
        parse(true)
      rescue JpegTruncated
        raise QrReader::ImageError, "truncated JPEG header"
      end
      raise QrReader::ImageError, "JPEG has no frame header" if @components.empty?

      begin
        resolve_height
      rescue JpegTruncated
        raise QrReader::ImageError, "truncated JPEG header"
      end
      [@width, @height]
    end

    def decode
      begin
        parse(false)
      rescue QrReader::UnsupportedImageError => e
        raise e
      rescue JpegTruncated
        # Truncation after complete scans: keep what was decoded.
        raise QrReader::ImageError, "truncated JPEG" if @scans_decoded == 0
      rescue QrReader::ImageError => e
        # Corruption after complete scans: keep what was decoded.
        raise e if @scans_decoded == 0
      end
      raise QrReader::ImageError, "JPEG has no image data" if @scans_decoded == 0

      finish
    end

    def huffman_table(ac, id)
      slot = ac ? id + 4 : id
      return @htables[slot] if @hbuilt[slot]

      counts = @hcounts[slot]
      symbols = @hsymbols[slot]
      if counts.empty?
        raise QrReader::ImageError, "corrupt JPEG: missing Huffman table" if id > 1

        counts = ac ? JPEG_STD_AC_COUNTS[id] : JPEG_STD_DC_COUNTS[id]
        symbols = ac ? JPEG_STD_AC_SYMBOLS[id] : JPEG_STD_DC_SYMBOLS
      end
      table = JpegHuffman.new(counts, symbols, ac)
      @htables << table while @htables.size <= slot
      @htables[slot] = table
      @hbuilt[slot] = true
      table
    end

    # Latches the component's quantisation table (as libjpeg does at the
    # component's first scan), indexed by extended zigzag position.
    def latch_quant(comp)
      return unless comp.qz.empty?

      q = @qt[comp.tq]
      raise QrReader::ImageError, "corrupt JPEG: missing quantisation table #{comp.tq}" if q.empty?

      comp.qz = q + Array.new(16, q[63]) + Array.new(JPEG_ZIGZAG_EXT.size - 80, 0)
    end

    # The coefficient store of a decode with +keep+ (a binary String).
    #
    # Layout: a header of little-endian 32-bit Integers - magic, header
    # size (in Integers), width, height, colour space, hmax, vmax,
    # component count, stored component count, then per stored component
    # index, h, v, abw, abh, data offset, data size, offset of its row
    # table in the header, and its 64 quantisation values (zigzag order),
    # then the row tables (byte offset of each block row in the
    # component's data) - followed by the components' entry data.
    #
    # Entries are signed 16-bit. Each block is a list of AC entries in
    # increasing zigzag order, closed by a DC entry: an AC coefficient v at
    # zigzag index k (1..63) with -512 <= v < 512 is (v << 6) | k, larger
    # ones are k << 6 followed by v; the DC entry is 0 followed by the DC
    # value. Values are raw (not dequantised). Blocks that were not decoded
    # are all-zero (mid-gray), like in a direct decode.
    def store
      return "".b unless @keep

      needed = []
      i = 0
      while i < @components.size
        c = @components[i]
        if c.needed
          c.store_finish
          needed << c
        end
        i += 1
      end
      head = [JPEG_STORE_MAGIC, 0, @width, @height, @color, @hmax, @vmax, @components.size, needed.size]
      tables = head.size + needed.size * 72
      data_off = 0
      i = 0
      while i < needed.size
        c = needed[i]
        head << c.index << c.h << c.v << c.abw << c.abh << data_off << c.sdata.bytesize << tables
        tables += c.abh
        data_off += c.sdata.bytesize
        k = 0
        while k < 64
          head << (c.qz.empty? ? 0 : c.qz[k])
          k += 1
        end
        i += 1
      end
      i = 0
      while i < needed.size
        rows = needed[i].srows
        r = 0
        while r < rows.size
          head << rows[r]
          r += 1
        end
        i += 1
      end
      head[1] = head.size
      out = head.pack("l<*")
      i = 0
      while i < needed.size
        out << needed[i].sdata
        i += 1
      end
      out
    end

    # Luminance at this decoder's scale from the coefficient store in @data.
    def render_store
      data = @data
      raise QrReader::ImageError, "not a JPEG coefficient store" if data.bytesize < 36

      head = data.byteslice(0, 36).unpack("l<*")
      count = head[1]
      if head[0] != JPEG_STORE_MAGIC || count < 9 || count * 4 > data.bytesize
        raise QrReader::ImageError, "not a JPEG coefficient store"
      end

      head = data.byteslice(0, count * 4).unpack("l<*")
      @width = head[2]
      @height = head[3]
      @color = head[4]
      @hmax = head[5]
      @vmax = head[6]
      ncomp = head[7]
      nstored = head[8]
      if @width < 1 || @height < 1 || @hmax < 1 || @hmax > 4 || @vmax < 1 || @vmax > 4 || ncomp < 1 || ncomp > 10
        raise QrReader::ImageError, "corrupt JPEG coefficient store"
      end
      i = 0
      while i < ncomp
        @components << JpegComponent.new(i, i, 1, 1, 0)
        i += 1
      end
      setup_output
      p = 9
      i = 0
      while i < nstored
        raise QrReader::ImageError, "corrupt JPEG coefficient store" if p + 72 > count

        c = JpegComponent.new(head[p], head[p], head[p + 1], head[p + 2], 0)
        if c.index < 0 || c.index >= ncomp || c.h < 1 || c.h > @hmax || c.v < 1 || c.v > @vmax
          raise QrReader::ImageError, "corrupt JPEG coefficient store"
        end

        c.needed = true
        c.abw = head[p + 3]
        c.abh = head[p + 4]
        mcux = (@width + 8 * @hmax - 1) / (8 * @hmax)
        mcuy = (@height + 8 * @vmax - 1) / (8 * @vmax)
        if c.abw < 1 || c.abw > mcux * c.h || c.abh < 1 || c.abh > mcuy * c.v
          raise QrReader::ImageError, "corrupt JPEG coefficient store"
        end

        c.qz = head[p + 8, 64]
        c.bs = scaled_block_size(c)
        c.idct = JpegIDCT.new(c.bs)
        c.pw = c.abw * c.bs
        c.ph = c.abh * c.bs
        @components[c.index] = c
        render_store_component(c, count * 4 + head[p + 5], head[p + 6], head, head[p + 7])
        p += 72
        i += 1
      end
      output
    end

    private

    # ---------------------------------------------------------------
    # Marker parsing

    def parse(header_only)
      data = @data
      raise QrReader::ImageError, "not a JPEG file" unless data.getbyte(0) == 0xFF && data.getbyte(1) == 0xD8

      pos = 2
      while (code = next_marker(pos)) >= 0
        pos = @marker_end
        if code >= 0xC0 && code <= 0xC2
          pos = read_frame(pos, code)
          return if header_only
        elsif code == 0xC3 || (code >= 0xC5 && code <= 0xC7) || (code >= 0xC9 && code <= 0xCB) ||
              (code >= 0xCD && code <= 0xCF) || code == 0xF7
          raise QrReader::UnsupportedImageError, "#{QrReaderKernels.jpeg_sof_name(code)} JPEG is not supported" unless header_only

          read_frame(pos, code)
          return
        elsif code == 0xC4
          pos = read_dht(pos)
        elsif code == 0xDB
          pos = read_dqt(pos)
        elsif code == 0xDD
          pos = read_dri(pos)
        elsif code == 0xDA
          raise QrReader::ImageError, "corrupt JPEG: scan before frame header" if header_only

          pos = read_scan(pos)
        elsif code == 0xD9
          return
        elsif code == 0xE0
          pos = read_app0(pos)
        elsif code == 0xEE
          pos = read_app14(pos)
        elsif (code >= 0xD0 && code <= 0xD8) || code == 0x01
          # markers without payload
        elsif code == 0xDE || code == 0xDF
          raise QrReader::UnsupportedImageError, "hierarchical JPEG is not supported"
        elsif code >= 0x02 && code <= 0xBF
          raise QrReader::ImageError, "corrupt JPEG: unknown marker 0x#{code.to_s(16).upcase}"
        else
          pos = segment_end(pos)
        end
      end
    end

    # Finds the next marker at or after +pos+, skipping junk and fill bytes.
    # Returns its code (and sets @marker_end to the position after it), or
    # -1 at the end of the data.
    def next_marker(pos)
      data = @data
      while true
        pos = data.index(JPEG_FF, pos)
        return -1 unless pos

        pos += 1 while data.getbyte(pos) == 0xFF
        code = data.getbyte(pos)
        return -1 unless code

        if code != 0
          @marker_end = pos + 1
          return code
        end
      end
    end

    def u16(pos)
      hi = @data.getbyte(pos)
      lo = @data.getbyte(pos + 1)
      raise JpegTruncated, "truncated JPEG" unless hi && lo

      (hi << 8) | lo
    end

    def byte(pos)
      b = @data.getbyte(pos)
      raise JpegTruncated, "truncated JPEG" unless b

      b
    end

    # Position after the marker segment whose length field is at +pos+.
    def segment_end(pos)
      len = u16(pos)
      raise QrReader::ImageError, "corrupt JPEG: bad marker length" if len < 2
      raise JpegTruncated, "truncated JPEG" if pos + len > @data.bytesize

      pos + len
    end

    def read_frame(pos, code)
      stop = segment_end(pos)
      raise QrReader::ImageError, "corrupt JPEG: duplicate frame header" unless @components.empty?

      @precision = byte(pos + 2)
      @height = u16(pos + 3)
      @width = u16(pos + 5)
      count = byte(pos + 7)
      raise QrReader::ImageError, "corrupt JPEG: bad image width" if @width == 0
      raise QrReader::ImageError, "corrupt JPEG: bad component count" if count < 1 || count > 10
      raise QrReader::ImageError, "corrupt JPEG: bad frame header length" if stop - pos != 8 + 3 * count

      @progressive = code == 0xC2
      comps = []
      i = 0
      while i < count
        p = pos + 8 + 3 * i
        hv = byte(p + 1)
        h = hv >> 4
        v = hv & 15
        tq = byte(p + 2)
        raise QrReader::ImageError, "corrupt JPEG: bad sampling factors" if h < 1 || h > 4 || v < 1 || v > 4
        raise QrReader::ImageError, "corrupt JPEG: bad quantisation table id" if tq > 3

        comps << JpegComponent.new(i, byte(p), h, v, tq)
        i += 1
      end
      @components = comps
      @frame_end = stop
      stop
    end

    def read_dht(pos)
      stop = segment_end(pos)
      p = pos + 2
      while p < stop
        info = byte(p)
        klass = info >> 4
        id = info & 15
        raise QrReader::ImageError, "corrupt JPEG: bad Huffman table id" if klass > 1 || id > 3

        counts = []
        total = 0
        i = 0
        while i < 16
          n = byte(p + 1 + i)
          counts << n
          total += n
          i += 1
        end
        raise QrReader::ImageError, "corrupt JPEG: bad Huffman table" if total > 256 || p + 17 + total > stop

        symbols = @data.byteslice(p + 17, total).unpack("C*")
        slot = klass == 0 ? id : id + 4
        @hcounts[slot] = counts
        @hsymbols[slot] = symbols
        @hbuilt[slot] = false
        p += 17 + total
      end
      stop
    end

    def read_dqt(pos)
      stop = segment_end(pos)
      p = pos + 2
      while p < stop
        info = byte(p)
        precision = info >> 4
        id = info & 15
        size = precision == 0 ? 64 : 128
        raise QrReader::ImageError, "corrupt JPEG: bad quantisation table" if precision > 1 || id > 3 || p + 1 + size > stop

        @qt[id] = @data.byteslice(p + 1, size).unpack(precision == 0 ? "C64" : "n64")
        p += 1 + size
      end
      stop
    end

    def read_dri(pos)
      stop = segment_end(pos)
      raise QrReader::ImageError, "corrupt JPEG: bad DRI marker" if stop - pos != 4

      @restart_interval = u16(pos + 2)
      stop
    end

    def read_app0(pos)
      stop = segment_end(pos)
      @jfif = true if stop - pos >= 16 && @data.byteslice(pos + 2, 5) == "JFIF\0"
      stop
    end

    def read_app14(pos)
      stop = segment_end(pos)
      @adobe_transform = byte(pos + 13) if stop - pos >= 14 && @data.byteslice(pos + 2, 5) == "Adobe"
      stop
    end

    # Height 0 in the frame header means it is given by a DNL marker after
    # the first scan (0xFF 0xDC cannot occur inside scan data).
    def resolve_height
      return if @height != 0

      at = @data.index(JPEG_DNL_MARKER, @frame_end)
      raise QrReader::ImageError, "corrupt JPEG: zero image height" unless at

      @height = u16(at + 4)
      raise QrReader::ImageError, "corrupt JPEG: zero image height" if @height == 0
    end

    # ---------------------------------------------------------------
    # Frame setup (at the first scan, when all header markers are known)

    def setup_frame
      return if @hmax > 0

      if @precision != 8
        if @precision == 12 || @precision == 16
          raise QrReader::UnsupportedImageError, "#{@precision}-bit JPEG is not supported"
        end

        raise QrReader::ImageError, "corrupt JPEG: bad sample precision #{@precision}"
      end
      resolve_height
      # A coefficient store only for images that can be rendered at full size.
      @keep = false if @width * @height > JPEG_MAX_PIXELS
      comps = @components
      @color = color_space
      nneeded = if @color == JPEG_RGB then 3
                elsif @color == JPEG_CMYK || @color == JPEG_YCCK then 4
                else 1
                end
      hmax = 0
      vmax = 0
      i = 0
      while i < comps.size
        c = comps[i]
        hmax = c.h if c.h > hmax
        vmax = c.v if c.v > vmax
        i += 1
      end
      @hmax = hmax
      @vmax = vmax
      setup_output
      @mcux = (@width + 8 * hmax - 1) / (8 * hmax)
      @mcuy = (@height + 8 * vmax - 1) / (8 * vmax)
      idcts = [nil, nil, nil, nil, nil, nil, nil, nil, nil]
      single = comps.size == 1
      blocks = 0
      i = 0
      while i < comps.size
        c = comps[i]
        c.bs = scaled_block_size(c)
        idct = idcts[c.bs]
        unless idct
          idct = JpegIDCT.new(c.bs)
          idcts[c.bs] = idct
        end
        c.idct = idct
        setup_component(c, i < nneeded, single)
        blocks += c.abw * c.abh if c.needed
        i += 1
      end
      check_coefficient_memory if @progressive
      @scanned = Array.new(comps.size, false)
      @visits = 0
      @max_visits = JPEG_MAX_VISITS * blocks + 65_536
    end

    # Output size at this decoder's scale (checked against MAX_PIXELS).
    def setup_output
      w = @width
      h = @height
      @out_w = (w + @scale - 1) / @scale
      @out_h = (h + @scale - 1) / @scale
      raise QrReader::UnsupportedImageError, "JPEG too large (#{w}x#{h})" if @out_w * @out_h > JPEG_MAX_PIXELS
    end

    # libjpeg's per-component DCT scaling: at reduced scales a subsampled
    # component gets a larger IDCT where that replaces upsampling.
    def scaled_block_size(c)
      size = @bs
      while size < 8 && ((@hmax * @bs) % (c.h * size * 2)) == 0 && ((@vmax * @bs) % (c.v * size * 2)) == 0
        size *= 2
      end
      size
    end

    # Progressive JPEGs keep all coefficients of the needed components (8
    # bytes per Array entry): refuse sizes whose storage would explode.
    def check_coefficient_memory
      entries = 0
      i = 0
      while i < @components.size
        c = @components[i]
        entries += c.abw * c.abh * c.stride if c.needed
        i += 1
      end
      return if entries <= JPEG_MAX_COEFFICIENTS

      raise QrReader::UnsupportedImageError, "progressive JPEG too large to decode at scale #{@scale} " \
                                             "(#{@width}x#{@height}, #{@components.size} components)"
    end

    def setup_component(c, needed, single)
      c.cw = (@width * c.h + @hmax - 1) / @hmax
      c.ch = (@height * c.v + @vmax - 1) / @vmax
      c.bw = (c.cw + 7) / 8
      c.bh = (c.ch + 7) / 8
      c.abw = single ? c.bw : @mcux * c.h
      c.abh = single ? c.bh : @mcuy * c.v
      c.pw = c.abw * c.bs
      c.ph = c.abh * c.bs
      c.needed = needed
      return unless needed

      if @progressive
        # Only the DC is kept when it is all that is rendered.
        c.stride = c.bs == 1 && !@keep ? 1 : JPEG_BLOCK_STRIDE
        c.coefs = Array.new(c.abh, JPEG_NONE)
      else
        c.plane = String.new(capacity: c.pw * c.ph, encoding: Encoding::BINARY)
      end
    end

    # Colour space of the stored components, following libjpeg's rules.
    def color_space
      comps = @components
      n = comps.size
      if n == 1
        JPEG_GRAY
      elsif n == 3
        if @jfif then JPEG_YCBCR
        elsif @adobe_transform >= 0 then @adobe_transform == 0 ? JPEG_RGB : JPEG_YCBCR
        elsif comps[0].id == 82 && comps[1].id == 71 && comps[2].id == 66 then JPEG_RGB # "RGB"
        else JPEG_YCBCR
        end
      elsif n == 4
        @adobe_transform <= 0 ? JPEG_CMYK : JPEG_YCCK
      else
        JPEG_OTHER
      end
    end

    # ---------------------------------------------------------------
    # Scans

    def read_scan(pos)
      raise QrReader::ImageError, "corrupt JPEG: scan before frame header" if @components.empty?

      stop = segment_end(pos)
      count = byte(pos + 2)
      raise QrReader::ImageError, "corrupt JPEG: bad scan header" if count < 1 || count > 4 || stop - pos != 6 + 2 * count

      comps = []
      dcs = []
      acs = []
      i = 0
      while i < count
        id = byte(pos + 3 + 2 * i)
        tables = byte(pos + 4 + 2 * i)
        comp = scan_component(id, comps)
        raise QrReader::ImageError, "corrupt JPEG: bad scan component" unless comp
        raise QrReader::ImageError, "corrupt JPEG: bad Huffman table id" if (tables >> 4) > 3 || (tables & 15) > 3

        comps << comp
        dcs << (tables >> 4)
        acs << (tables & 15)
        i += 1
      end
      ss = byte(stop - 3)
      se = byte(stop - 2)
      ah = byte(stop - 1) >> 4
      al = byte(stop - 1) & 15

      setup_frame
      raise QrReader::ImageError, "corrupt JPEG: too many blocks per MCU" if count > 1 && mcu_blocks(comps) > 10

      validate_progression(count, ss, se, ah, al) if @progressive
      seg_end = scan_extent(stop)
      if decode_scan?(comps, ss)
        # Crafted files could repeat cheap scans that each visit every block.
        @visits += count == 1 ? comps[0].bw * comps[0].bh : @mcux * @mcuy * mcu_blocks(comps)
        raise QrReader::ImageError, "corrupt JPEG: too many scans" if @scans_decoded >= JPEG_MAX_SCANS || @visits > @max_visits

        words = entropy_words(stop, seg_end)
        @scans_decoded += 1
        if @progressive
          JpegProgressive.new(self, comps, dcs, ss, se, ah, al, acs[0], words, @starts, @ends).run
        else
          JpegSequential.new(self, comps, dcs, acs, words, @starts, @ends).run
        end
      end
      seg_end
    end

    # The first component with this id not yet in the scan (some encoders
    # write duplicate ids; libjpeg-turbo matches them so), or nil.
    def scan_component(id, taken)
      i = 0
      while i < @components.size
        c = @components[i]
        if c.id == id
          free = true
          j = 0
          while j < taken.size
            free = false if taken[j].equal?(c)
            j += 1
          end
          return c if free
        end
        i += 1
      end
      nil
    end

    # Blocks per MCU of an interleaved scan.
    def mcu_blocks(comps)
      n = 0
      i = 0
      while i < comps.size
        n += comps[i].h * comps[i].v
        i += 1
      end
      n
    end

    def validate_progression(count, ss, se, ah, al)
      bad = ss == 0 ? se != 0 : ss > se || se > 63 || count != 1
      bad ||= ah != 0 && al != ah - 1
      bad ||= al > 13
      raise QrReader::ImageError, "corrupt JPEG: bad progressive scan parameters" if bad
    end

    # Whether a scan contributes to the output: scans without needed
    # components, progressive AC scans of components decoded DC-only (block
    # size 1, without a coefficient store) and repeated sequential scans
    # are skipped.
    def decode_scan?(comps, ss)
      unless @progressive
        # A component has a single sequential scan: repeats are ignored,
        # and so are scans of components the output does not need.
        fresh = false
        i = 0
        while i < comps.size
          c = comps[i]
          fresh = true if c.needed && !@scanned[c.index]
          @scanned[c.index] = true
          i += 1
        end
        return fresh
      end
      if ss == 0
        i = 0
        while i < comps.size
          return true if comps[i].needed
          i += 1
        end
        return false
      end
      c = comps[0]
      c.needed && c.stride > 1
    end

    # End of the entropy-coded data starting at +pos+: the first 0xFF that
    # is neither stuffing nor a restart marker. Fill bytes (0xFF runs)
    # before stuffing or RST are allowed. With restart intervals, reserved
    # marker codes (corrupt data) do not end the scan either: like libjpeg,
    # decoding resumes at the next RST.
    def scan_extent(pos)
      data = @data
      size = data.bytesize
      resync = @restart_interval > 0
      while (e = data.index(JPEG_FF, pos))
        r = e + 1
        c = data.getbyte(r)
        return size unless c

        if c == 0xFF
          r += 1 while data.getbyte(r) == 0xFF
          c = data.getbyte(r)
          return e unless c
          return e unless c == 0 || (c >= 0xD0 && c <= 0xD7) || (resync && c < 0xC0)
        elsif c != 0 && (c < 0xD0 || c > 0xD7)
          return e if !resync || c >= 0xC0
        end
        pos = r + 1
      end
      size
    end

    # The entropy-coded segment [pos, stop) without byte stuffing, split at
    # restart markers and unpacked to big-endian 32-bit words. Each restart
    # interval starts on a word boundary; @starts[i] is its first word,
    # @ends[i] the bit position just after its data.
    def entropy_words(pos, stop)
      data = @data
      stop -= 1 if stop > pos && data.getbyte(stop - 1) == 0xFF # dangling half of a stuffed byte
      resync = @restart_interval > 0
      pieces = []
      marks = []
      cur = String.new(capacity: stop - pos + 4 + JPEG_TAIL_PADDING.bytesize, encoding: Encoding::BINARY)
      cut = false # the interval's data ended at a reserved marker (corrupt data)
      p = pos
      while p < stop
        f = data.index(JPEG_FF, p)
        if f.nil? || f >= stop
          cur << data.byteslice(p, stop - p) unless cut
          break
        end
        cur << data.byteslice(p, f - p) if !cut && f > p
        q = f + 1
        q += 1 while q < stop && data.getbyte(q) == 0xFF # fill bytes
        if q >= stop
          cur << data.byteslice(f, stop - f) unless cut
          break
        end
        c = data.getbyte(q)
        if c == 0
          cur << JPEG_FF unless cut
        elsif c >= 0xD0 && c <= 0xD7
          break unless resync # a stray RST ends the data, like in libjpeg

          pieces << cur
          marks << c
          cur = "".b
          cut = false
        else
          # Reserved marker: fill bytes before it stay, the interval ends.
          cur << data.byteslice(f, q - 1 - f) if !cut && q - 1 > f
          cut = true
        end
        p = q + 1
      end
      pieces << cur
      pieces = restart_intervals(pieces, marks) unless marks.empty?
      starts = []
      ends = []
      if pieces.size == 1
        buf = pieces[0]
        starts << 0
        ends << (buf.bytesize << 3)
        buf << "\0" * (-buf.bytesize & 3)
      else
        total = 0
        i = 0
        while i < pieces.size
          total += pieces[i].bytesize + 3
          i += 1
        end
        buf = String.new(capacity: total + JPEG_TAIL_PADDING.bytesize, encoding: Encoding::BINARY)
        i = 0
        while i < pieces.size
          piece = pieces[i]
          word = buf.bytesize >> 2
          starts << word
          ends << ((word << 5) + (piece.bytesize << 3))
          buf << piece << "\0" * (-piece.bytesize & 3)
          i += 1
        end
      end
      buf << JPEG_TAIL_PADDING
      @starts = starts
      @ends = ends
      buf.unpack("N*")
    end

    # Assigns the data pieces of a scan split at restart markers (pieces[0]
    # before the first marker, pieces[j + 1] after marks[j]) to restart
    # intervals by the markers' numbers (modulo 8). A marker without the
    # expected number is judged by the next one: if that one continues from
    # the expected number, this marker is corrupt and counts as expected; if
    # it continues from this marker, intervals were lost (up to five; they
    # stay empty, i.e. gray) or, for a marker one or two behind, the data is
    # stale and dropped. Otherwise libjpeg's resync rules apply: one or two
    # ahead means lost intervals, one or two behind stale data, else resume.
    def restart_intervals(pieces, marks)
      out = [pieces[0]]
      expected = 0
      n = marks.size
      j = 0
      while j < n
        m = marks[j] & 7
        ahead = (m - expected) & 7
        if ahead != 0
          nxt = j + 1 < n ? marks[j + 1] & 7 : -1
          if nxt == ((expected + 1) & 7)
            ahead = 0
          elsif nxt != ((m + 1) & 7) && ahead >= 3 && ahead <= 5
            ahead = 0
          end
        end
        if ahead < 6
          a = 0
          while a < ahead
            out << "".b
            a += 1
          end
          out << pieces[j + 1]
          expected += ahead + 1
        end
        j += 1
      end
      out
    end

    # ---------------------------------------------------------------
    # Output

    def finish
      comps = @components
      i = 0
      while i < comps.size
        c = comps[i]
        if c.needed
          if @progressive
            if @keep
              store_coefficients(c)
              render_store_rows(c, c.sdata, 0, c.sdata.bytesize, c.srows)
            else
              render_coefficients(c)
            end
          else
            gray = c.pw * c.ph - c.plane.bytesize
            c.plane << "\x80".b * gray if gray > 0
          end
        end
        i += 1
      end
      output
    end

    # Luminance from the component planes.
    def output
      comps = @components
      color = @color
      if color == JPEG_RGB
        convert_rgb(component_samples(comps[0]), component_samples(comps[1]), component_samples(comps[2]))
      elsif color == JPEG_CMYK || color == JPEG_YCCK
        convert_cmyk(component_samples(comps[0]), component_samples(comps[1]), component_samples(comps[2]),
                     component_samples(comps[3]), color == JPEG_YCCK)
      else
        component_samples(comps[0])
      end
    end

    # IDCTs the stored progressive coefficients of +c+ into its plane.
    def render_coefficients(c)
      latch_quant(c)
      q = Array.new(64, 0)
      k = 0
      while k < 64
        q[JPEG_ZIGZAG[k]] = c.qz[k]
        k += 1
      end
      bs = c.bs
      plane = String.new(capacity: c.pw * c.ph, encoding: Encoding::BINARY)
      buf = Array.new(c.pw / JPEG_SAMPLES_PER_WORD[bs] * bs, 0)
      blk = Array.new(64, 0)
      pack = JPEG_PACK[bs]
      rows = c.coefs
      by = 0
      while by < c.abh
        row = rows[by]
        if row.empty?
          buf.fill(128 * JPEG_SPREAD[bs]) # no data: all coefficients 0
        elsif bs == 1
          render_dc_row(c, row, q[0], buf)
        else
          render_coefficient_row(c, row, q, blk, buf)
        end
        plane << buf.pack(pack)
        rows[by] = JPEG_NONE
        by += 1
      end
      c.plane = plane
    end

    # IDCTs block row +row+ (raw coefficients, natural order) of +c+ into
    # +buf+ (packed words), dequantised with +q+ (natural order).
    def render_coefficient_row(c, row, q, blk, buf)
      idct = c.idct
      zz = JPEG_ZIGZAG
      stride = c.pw / JPEG_SAMPLES_PER_WORD[c.bs]
      step = JPEG_WORDS[c.bs]
      base = 0
      off = 0
      while off < stride
        km = row[base + 64]
        if km == 0
          idct.fill(buf, off, stride, idct.dc_sample(row[base] * q[0]))
        else
          k = 0
          while k <= km
            n = zz[k]
            blk[n] = row[base + n] * q[n]
            k += 1
          end
          idct.transform(blk, 0, km, buf, off, stride)
          k = 0
          while k <= km
            blk[zz[k]] = 0
            k += 1
          end
        end
        base += JPEG_BLOCK_STRIDE
        off += step
      end
    end

    # DC-only samples (block size 1) of block row +row+ of +c+.
    def render_dc_row(c, row, q0, buf)
      idct = c.idct
      stride = c.stride
      n = c.abw
      base = 0
      x = 0
      while x < n
        buf[x] = idct.dc_sample(row[base] * q0)
        base += stride
        x += 1
      end
    end

    # Moves the stored progressive coefficients of +c+ into its coefficient
    # store (see #store).
    def store_coefficients(c)
      latch_quant(c)
      rows = c.coefs
      entries = []
      by = 0
      while by < c.abh
        row = rows[by]
        if row.empty?
          x = 0
          while x < c.abw
            entries << 0 << 0
            x += 1
          end
        else
          coefficient_entries(row, c.abw, entries)
        end
        c.store_row(entries)
        entries.clear
        rows[by] = JPEG_NONE
        by += 1
      end
    end

    # Appends the store entries of the +n+ blocks of a coefficient row.
    def coefficient_entries(row, n, entries)
      zz = JPEG_ZIGZAG
      base = 0
      x = 0
      while x < n
        km = row[base + 64]
        k = 1
        while k <= km
          v = row[base + zz[k]]
          if v != 0
            if v >= -512 && v < 512
              entries << ((v << 6) | k)
            else
              entries << (k << 6) << v
            end
          end
          k += 1
        end
        entries << 0 << row[base]
        base += JPEG_BLOCK_STRIDE
        x += 1
      end
    end

    # Renders component +c+ from the store data at byte offset +data_off+
    # (+size+ bytes) whose row table starts at head[+table+].
    def render_store_component(c, data_off, size, head, table)
      if data_off < 0 || size < 0 || data_off + size > @data.bytesize || table + c.abh > head.size
        raise QrReader::ImageError, "corrupt JPEG coefficient store"
      end

      render_store_rows(c, @data, data_off, size, head[table, c.abh])
    end

    # Renders the plane of +c+ from store data at data[base, size] whose
    # block rows start at the offsets +rows+.
    def render_store_rows(c, data, base, size, rows)
      bs = c.bs
      qz = c.qz
      q0 = qz[0]
      plane = String.new(capacity: c.pw * c.ph, encoding: Encoding::BINARY)
      buf = Array.new(c.pw / JPEG_SAMPLES_PER_WORD[bs] * bs, 0)
      blk = Array.new(64, 0)
      pack = JPEG_PACK[bs]
      by = 0
      while by < c.abh
        start = rows[by]
        stop = by + 1 < rows.size ? rows[by + 1] : size
        stop = start if stop < start || stop > size
        entries = data.byteslice(base + start, stop - start).unpack("s<*")
        entries << 0 << 0 # a corrupt row ends with zero blocks
        if bs == 1
          store_dc_row(c, entries, q0, buf)
        else
          render_entry_row(c, entries, qz, blk, buf)
        end
        plane << buf.pack(pack)
        by += 1
      end
      c.plane = plane
    end

    # IDCTs a block row of store entries into +buf+ (packed words).
    def render_entry_row(c, entries, qz, blk, buf)
      idct = c.idct
      zz = JPEG_ZIGZAG
      stride = c.pw / JPEG_SAMPLES_PER_WORD[c.bs]
      step = JPEG_WORDS[c.bs]
      last = entries.size - 2
      i = 0
      off = 0
      while off < stride
        km = 0
        dc = 0
        while i < last
          e = entries[i]
          k = e & 63
          if k != 0
            v = e >> 6
            i += 1
          else
            k = e >> 6
            v = entries[i + 1]
            i += 2
            if k <= 0 || k > 63
              dc = v
              break
            end
          end
          blk[zz[k]] = v * qz[k]
          km = k
        end
        if km == 0
          idct.fill(buf, off, stride, idct.dc_sample(dc * qz[0]))
        else
          blk[0] = dc * qz[0]
          idct.transform(blk, 0, km, buf, off, stride)
          blk.fill(0)
        end
        off += step
      end
    end

    # DC-only samples (block size 1) of a block row of store entries.
    def store_dc_row(c, entries, q0, buf)
      idct = c.idct
      n = c.abw
      last = entries.size - 2
      i = 0
      x = 0
      while x < n
        dc = 0
        while i < last
          e = entries[i]
          if (e & 63) != 0
            i += 1
          else
            k = e >> 6
            i += 2
            if k <= 0 || k > 63
              dc = entries[i - 1]
              break
            end
          end
        end
        buf[x] = idct.dc_sample(dc * q0)
        x += 1
      end
    end

    # Samples of component +c+ at output size (cropped, or upsampled when
    # the component is subsampled relative to the frame).
    def component_samples(c)
      ow = @out_w
      oh = @out_h
      # Samples per MCU after scaling (libjpeg's input group), which the
      # upsampler expands to hmax x vmax output pixels.
      h = c.h * c.bs / @bs
      v = c.v * c.bs / @bs
      return crop(c.plane, c.pw, ow, oh) if h == @hmax && v == @vmax

      # Component size at this scale (libjpeg's downsampled size).
      cw = (@width * c.h * c.bs + @hmax * 8 - 1) / (@hmax * 8)
      ch = (@height * c.v * c.bs + @vmax * 8 - 1) / (@vmax * 8)
      # libjpeg's "fancy" upsampling needs DCT_scaled_size > 1.
      JpegUpsampler.new(c.plane, c.pw, cw, ch, @hmax, @vmax, h, v, @bs > 1).run(ow, oh)
    end

    def crop(plane, pw, w, h)
      return plane.byteslice(0, w * h) if pw == w

      out = String.new(capacity: w * h, encoding: Encoding::BINARY)
      y = 0
      while y < h
        out << plane.byteslice(y * pw, w)
        y += 1
      end
      out
    end

    def convert_rgb(r, g, b)
      w = @out_w
      out = String.new(capacity: w * @out_h, encoding: Encoding::BINARY)
      y = 0
      while y < @out_h
        rgb_row(r, g, b, out, y * w, w)
        y += 1
      end
      out
    end

    def rgb_row(r, g, b, out, i, n)
      stop = i + n
      while i < stop
        out << ((306 * r.getbyte(i) + 601 * g.getbyte(i) + 117 * b.getbyte(i) + 0x200) >> 10)
        i += 1
      end
    end

    def convert_cmyk(c, m, y, k, ycck)
      w = @out_w
      out = String.new(capacity: w * @out_h, encoding: Encoding::BINARY)
      row = 0
      while row < @out_h
        if ycck
          ycck_row(c, m, y, k, out, row * w, w)
        else
          cmyk_row(c, m, y, k, out, row * w, w)
        end
        row += 1
      end
      out
    end

    # Adobe CMYK JPEGs store inverted ink (255 = no ink), so the stored
    # values are 255 - ink: R = C' * K' / 255 (rounded) and so on.
    def cmyk_row(c, m, y, k, out, i, n)
      stop = i + n
      while i < stop
        kk = k.getbyte(i)
        r = (c.getbyte(i) * kk + 127) / 255
        g = (m.getbyte(i) * kk + 127) / 255
        b = (y.getbyte(i) * kk + 127) / 255
        out << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
        i += 1
      end
    end

    # YCCK stores YCbCr-encoded CMY plus K; libjpeg converts it to CMYK with
    # its fixed-point YCbCr->RGB tables (C = 255 - R, ...), which then goes
    # through #cmyk_row's formula.
    def ycck_row(y, cb, cr, k, out, i, n)
      cr_r = JPEG_CR_R
      cb_b = JPEG_CB_B
      cr_g = JPEG_CR_G
      cb_g = JPEG_CB_G
      stop = i + n
      while i < stop
        yy = 255 - y.getbyte(i)
        u = cb.getbyte(i)
        v = cr.getbyte(i)
        kk = k.getbyte(i)
        c = yy - cr_r[v]
        m = yy - ((cb_g[u] + cr_g[v]) >> 16)
        ye = yy - cb_b[u]
        c = c < 0 ? 0 : (c > 255 ? 255 : c)
        m = m < 0 ? 0 : (m > 255 ? 255 : m)
        ye = ye < 0 ? 0 : (ye > 255 ? 255 : ye)
        r = (c * kk + 127) / 255
        g = (m * kk + 127) / 255
        b = (ye * kk + 127) / 255
        out << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
        i += 1
      end
    end
  end

  # Decodes one sequential (baseline or extended) scan into the component
  # planes, MCU row by MCU row. Blocks of components that do not contribute
  # to the luminance are entropy-decoded and dropped. With a coefficient
  # store, the raw coefficients of the needed blocks are also recorded.
  class JpegSequential
    def initialize(decoder, comps, dcs, acs, words, starts, ends)
      @ri = decoder.restart_interval
      @keep = decoder.keep
      @words = words
      @starts = starts
      @ends = ends
      @acc = 0
      @bits = 0
      @wi = 0
      @endbit = 0
      interleaved = comps.size > 1
      if interleaved
        @mcux = decoder.mcux
        @mcuy = decoder.mcuy
      else
        @mcux = comps[0].bw
        @mcuy = comps[0].bh
      end
      @preds = Array.new(comps.size, 0)
      # Per block of the MCU.
      @pred_idx = []
      @dc_fast = []
      @dc_look = []
      @dc_table = []
      @ac_fast = []
      @ac_look = []
      @ac_table = []
      @need = [] # whether the block is rendered
      @ac = [] # whether its AC coefficients are decoded (else skipped)
      @q = []
      @out = []
      @off = []
      @step = []
      @stride = []
      @idct = []
      @ent = [] # its store entry list (index into @ents), or -1
      # Per needed component: row buffer (packed words), its rows, words per
      # MCU and per row.
      @row_comp = []
      @row_buf = []
      @row_n = []
      @row_step = []
      @row_stride = []
      # Store entry lists (one per block row of an MCU row), their block
      # counts, components and blocks per MCU.
      @ents = []
      @ent_count = []
      @ent_comp = []
      @ent_hn = []
      @ent_mark = []
      setup_blocks(decoder, comps, dcs, acs, interleaved)
      @nb = @pred_idx.size
      @blk = Array.new(@nb * 65, 0)
      @kmax = Array.new(@nb, 0)
    end

    def run
      total = @mcux * @mcuy
      ri = @ri
      mcu = 0
      interval = 0
      mx = 0
      my = 0
      keep = @keep
      while mcu < total
        if interval >= @starts.size
          finish_row(mx, my) # no data left: the rest stays gray
          return
        end
        n = total - mcu
        n = ri if ri > 0 && ri < n
        start_interval(interval)
        interval += 1
        dead = false
        while n > 0
          n -= 1
          mcu += 1
          if dead
            gray_mcu(mx)
          elsif !(keep ? decode_mcu_keep(mx) : decode_mcu(mx))
            # Ran past the end of the data: drop this MCU and the rest of
            # the interval (or of the image).
            dead = true
            if ri == 0 || interval >= @starts.size
              finish_row(mx, my)
              return
            end
            gray_mcu(mx)
          end
          mx += 1
          next unless mx == @mcux

          flush
          mx = 0
          my += 1
        end
      end
    end

    private

    def setup_blocks(decoder, comps, dcs, acs, interleaved)
      dummy = JpegIDCT.new(1)
      si = 0
      while si < comps.size
        c = comps[si]
        dc = decoder.huffman_table(false, dcs[si])
        ac = decoder.huffman_table(true, acs[si])
        hn = interleaved ? c.h : 1
        vn = interleaved ? c.v : 1
        row = -1
        ent = -1
        if c.needed
          decoder.latch_quant(c)
          bs = c.bs
          stride = c.pw / JPEG_SAMPLES_PER_WORD[bs]
          nrows = vn * bs
          row = @row_buf.size
          @row_comp << c
          @row_buf << Array.new(stride * nrows, 0)
          @row_n << nrows
          @row_step << hn * JPEG_WORDS[bs]
          @row_stride << stride
          if @keep
            ent = @ents.size
            r = 0
            while r < vn
              @ents << []
              @ent_count << 0
              @ent_comp << c
              @ent_hn << hn
              @ent_mark << 0
              r += 1
            end
          end
        end
        by = 0
        while by < vn
          bx = 0
          while bx < hn
            @pred_idx << si
            @dc_fast << dc.fast
            @dc_look << dc.look
            @dc_table << dc
            @ac_fast << ac.fast
            @ac_look << ac.look
            @ac_table << ac
            if row >= 0
              bs = c.bs
              @need << true
              @ac << (bs > 1 || @keep)
              @q << c.qz
              @out << @row_buf[row]
              @off << (by * bs * @row_stride[row]) + (bx * JPEG_WORDS[bs])
              @step << @row_step[row]
              @stride << @row_stride[row]
              @idct << c.idct
              @ent << (ent >= 0 ? ent + by : -1)
            else
              @need << false
              @ac << false
              @q << JPEG_NONE
              @out << JPEG_NONE
              @off << 0
              @step << 0
              @stride << 0
              @idct << dummy
              @ent << -1
            end
            bx += 1
          end
          by += 1
        end
        si += 1
      end
    end

    def start_interval(index)
      @wi = @starts[index]
      @endbit = @ends[index]
      @acc = 0
      @bits = 0
      @preds.fill(0)
    end

    # Decodes the MCU at column +mx+ and writes its needed blocks to the
    # row buffers. Returns false (writing nothing) if the MCU ran past the
    # end of the interval's data.
    def decode_mcu(mx)
      words = @words
      acc = @acc
      bits = @bits
      wi = @wi
      preds = @preds
      kmaxes = @kmax
      blk = @blk
      zz = JPEG_ZIGZAG_EXT
      nb = @nb
      b = 0
      base = 0
      while b < nb
        # DC coefficient (bits >= 31 after a refill covers any code + extra bits)
        if bits < 31
          acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
          wi += 1
          bits += 32
        end
        e = @dc_fast[b][(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
        if e != 0
          bits -= e & 255
          diff = e >> 16
        else
          e = @dc_look[b][(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
          e = @dc_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e == 0
          bits -= e >> 8
          s = e & 255
          if s == 0
            diff = 0
          else
            diff = (acc >> (bits - s)) & ((1 << s) - 1)
            bits -= s
            diff -= (1 << s) - 1 if diff < (1 << (s - 1))
          end
        end
        ci = @pred_idx[b]
        pred = ((preds[ci] + diff + 32_768) & 0xFFFF) - 32_768 # JCOEF wraps to 16 bits
        preds[ci] = pred

        # AC coefficients
        fast = @ac_fast[b]
        k = 1
        if @ac[b]
          q = @q[b]
          blk[base] = pred * q[0]
          while k < 64
            if bits < 31
              acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
              wi += 1
              bits += 32
            end
            e = fast[(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
            if e != 0
              bits -= e & 255
              k += (e >> 8) & 255
              blk[base + zz[k]] = (e >> 16) * q[k]
              k += 1
            else
              e = @ac_look[b][(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
              e = @ac_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e == 0
              bits -= e >> 8
              s = e & 15
              if s != 0
                k += (e >> 4) & 15
                v = (acc >> (bits - s)) & ((1 << s) - 1)
                bits -= s
                v -= (1 << s) - 1 if v < (1 << (s - 1))
                blk[base + zz[k]] = v * q[k]
                k += 1
              elsif (e & 0xF0) == 0xF0
                k += 16
              else
                k += JPEG_EOB_RUN + 1
              end
            end
          end
          kmaxes[b] = k > JPEG_EOB_RUN ? k - JPEG_EOB_RUN - 2 : 63
        else
          if @need[b]
            blk[base] = pred * @q[b][0]
            kmaxes[b] = 0
          end
          # Skip the AC coefficients.
          while k < 64
            if bits < 31
              acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
              wi += 1
              bits += 32
            end
            e = fast[(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
            if e != 0
              bits -= e & 255
              k += ((e >> 8) & 255) + 1
            else
              e = @ac_look[b][(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
              e = @ac_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e == 0
              bits -= (e >> 8) + (e & 15)
              if (e & 15) != 0
                k += ((e >> 4) & 15) + 1
              elsif (e & 0xF0) == 0xF0
                k += 16
              else
                break
              end
            end
          end
        end
        b += 1
        base += 65
      end

      if (wi << 5) - bits > @endbit
        blk.fill(0)
        return false
      end

      @acc = acc
      @bits = bits
      @wi = wi
      render_mcu(mx)
      true
    end

    # Like #decode_mcu, and records the raw coefficients of the needed
    # blocks as store entries (see JpegDecoder#store).
    def decode_mcu_keep(mx)
      words = @words
      acc = @acc
      bits = @bits
      wi = @wi
      preds = @preds
      kmaxes = @kmax
      blk = @blk
      zz = JPEG_ZIGZAG_EXT
      nb = @nb
      j = 0
      while j < @ents.size
        @ent_mark[j] = @ents[j].size
        j += 1
      end
      b = 0
      base = 0
      while b < nb
        if bits < 31
          acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
          wi += 1
          bits += 32
        end
        e = @dc_fast[b][(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
        if e != 0
          bits -= e & 255
          diff = e >> 16
        else
          e = @dc_look[b][(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
          e = @dc_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e == 0
          bits -= e >> 8
          s = e & 255
          if s == 0
            diff = 0
          else
            diff = (acc >> (bits - s)) & ((1 << s) - 1)
            bits -= s
            diff -= (1 << s) - 1 if diff < (1 << (s - 1))
          end
        end
        ci = @pred_idx[b]
        pred = ((preds[ci] + diff + 32_768) & 0xFFFF) - 32_768
        preds[ci] = pred

        fast = @ac_fast[b]
        k = 1
        if @ac[b]
          q = @q[b]
          ents = @ents[@ent[b]]
          blk[base] = pred * q[0]
          while k < 64
            if bits < 31
              acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
              wi += 1
              bits += 32
            end
            e = fast[(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
            if e != 0
              bits -= e & 255
              k += (e >> 8) & 255
              if (v = e >> 16) != 0 # not EOB or ZRL; |v| < 512
                blk[base + zz[k]] = v * q[k]
                ents << ((v << 6) | (k < 64 ? k : 63))
              end
              k += 1
            else
              e = @ac_look[b][(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
              e = @ac_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e == 0
              bits -= e >> 8
              s = e & 15
              if s != 0
                k += (e >> 4) & 15
                v = (acc >> (bits - s)) & ((1 << s) - 1)
                bits -= s
                v -= (1 << s) - 1 if v < (1 << (s - 1))
                blk[base + zz[k]] = v * q[k]
                kk = k < 64 ? k : 63
                if v >= -512 && v < 512
                  ents << ((v << 6) | kk)
                else
                  ents << (kk << 6) << v
                end
                k += 1
              elsif (e & 0xF0) == 0xF0
                k += 16
              else
                k += JPEG_EOB_RUN + 1
              end
            end
          end
          kmaxes[b] = k > JPEG_EOB_RUN ? k - JPEG_EOB_RUN - 2 : 63
          ents << 0 << pred
        else
          while k < 64
            if bits < 31
              acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
              wi += 1
              bits += 32
            end
            e = fast[(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
            if e != 0
              bits -= e & 255
              k += ((e >> 8) & 255) + 1
            else
              e = @ac_look[b][(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
              e = @ac_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e == 0
              bits -= (e >> 8) + (e & 15)
              if (e & 15) != 0
                k += ((e >> 4) & 15) + 1
              elsif (e & 0xF0) == 0xF0
                k += 16
              else
                break
              end
            end
          end
        end
        b += 1
        base += 65
      end

      if (wi << 5) - bits > @endbit
        blk.fill(0)
        # Drop the MCU's entries.
        j = 0
        while j < @ents.size
          ents = @ents[j]
          ents.pop while ents.size > @ent_mark[j]
          j += 1
        end
        return false
      end

      @acc = acc
      @bits = bits
      @wi = wi
      j = 0
      while j < @ents.size
        @ent_count[j] += @ent_hn[j]
        j += 1
      end
      render_mcu(mx)
      true
    end

    # IDCTs the decoded blocks of the MCU at column +mx+ into the row
    # buffers and clears them.
    def render_mcu(mx)
      blk = @blk
      kmaxes = @kmax
      nb = @nb
      b = 0
      base = 0
      while b < nb
        if @need[b]
          idct = @idct[b]
          off = @off[b] + mx * @step[b]
          km = kmaxes[b]
          if km == 0
            idct.fill(@out[b], off, @stride[b], idct.dc_sample(blk[base]))
            blk[base] = 0
          elsif idct.bs == 1
            idct.fill(@out[b], off, @stride[b], idct.dc_sample(blk[base]))
            blk.fill(0, base, 65)
          else
            idct.transform(blk, base, km, @out[b], off, @stride[b])
            blk.fill(0, base, 65)
          end
        end
        b += 1
        base += 65
      end
    end

    # Fills the MCU at column +mx+ of the row buffers with mid-gray (and
    # records all-zero blocks in the store).
    def gray_mcu(mx)
      b = 0
      while b < @nb
        @idct[b].fill(@out[b], @off[b] + mx * @step[b], @stride[b], 128) if @need[b]
        b += 1
      end
      return unless @keep

      j = 0
      while j < @ents.size
        ents = @ents[j]
        h = 0
        while h < @ent_hn[j]
          ents << 0 << 0
          h += 1
        end
        @ent_count[j] += @ent_hn[j]
        j += 1
      end
    end

    # Appends the MCU row in the row buffers to the planes (and the store).
    def flush
      i = 0
      while i < @row_buf.size
        c = @row_comp[i]
        len = c.pw * @row_n[i]
        c.plane << @row_buf[i].pack(JPEG_PACK[c.bs]) if c.plane.bytesize + len <= c.pw * c.ph
        i += 1
      end
      return unless @keep

      j = 0
      while j < @ents.size
        c = @ent_comp[j]
        ents = @ents[j]
        n = @ent_count[j]
        while n < c.abw
          ents << 0 << 0
          n += 1
        end
        c.store_row(ents)
        ents.clear
        @ent_count[j] = 0
        j += 1
      end
    end

    # Grays MCUs +mx+.. of the current row and flushes it; rows below stay
    # gray.
    def finish_row(mx, my)
      return if my >= @mcuy

      i = 0
      while i < @row_buf.size
        c = @row_comp[i]
        buf = @row_buf[i]
        from = mx * @row_step[i]
        stride = @row_stride[i]
        if from < stride
          gray = 128 * JPEG_SPREAD[c.bs]
          r = 0
          while r < @row_n[i]
            buf.fill(gray, r * stride + from, stride - from)
            r += 1
          end
        end
        i += 1
      end
      flush
    end
  end

  # Decodes one progressive scan into the stored coefficients: DC first or
  # refinement (possibly interleaved), or AC first or refinement of one
  # spectral band of one component. Stored coefficients are kept in 16-bit
  # range like libjpeg's JCOEF.
  class JpegProgressive
    DC_FIRST = 0
    DC_REFINE = 1
    AC_FIRST = 2
    AC_REFINE = 3

    def initialize(decoder, comps, dcs, ss, se, ah, al, ac, words, starts, ends)
      @ri = decoder.restart_interval
      @words = words
      @starts = starts
      @ends = ends
      @ss = ss
      @se = se
      @al = al
      @acc = 0
      @bits = 0
      @wi = 0
      @endbit = 0
      @eobrun = 0
      @preds = Array.new(comps.size, 0)
      @newnz = Array.new(64, 0)
      if comps.size == 1
        @units_x = comps[0].bw
        @units_y = comps[0].bh
      else
        @units_x = decoder.mcux
        @units_y = decoder.mcuy
      end
      if ss == 0
        @kind = ah == 0 ? DC_FIRST : DC_REFINE
        setup_dc(decoder, comps, dcs)
      else
        @kind = ah == 0 ? AC_FIRST : AC_REFINE
        c = comps[0]
        decoder.latch_quant(c)
        @table = decoder.huffman_table(true, ac)
        @rows = c.coefs
        @abw = c.abw
      end
    end

    def run
      ux = @units_x
      total = ux * @units_y
      ri = @ri
      u = 0
      interval = 0
      while u < total && interval < @starts.size
        n = total - u
        n = ri if ri > 0 && ri < n
        @wi = @starts[interval]
        @endbit = @ends[interval]
        @acc = 0
        @bits = 0
        @eobrun = 0
        @preds.fill(0)
        interval += 1
        stop = u + n
        while u < stop
          y = u / ux
          x0 = u - y * ux
          x1 = x0 + stop - u
          x1 = ux if x1 > ux
          kind = @kind
          ok = if kind <= DC_REFINE then dc_row(y, x0, x1)
               elsif kind == AC_FIRST then ac_first_row(y, x0, x1)
               else ac_refine_row(y, x0, x1)
               end
          # On running out of data, skip the rest of the interval.
          u = ok ? u + x1 - x0 : stop
        end
      end
    end

    private

    def setup_dc(decoder, comps, dcs)
      interleaved = comps.size > 1
      @b_rows = []
      @b_need = []
      @b_width = []
      @b_row = []
      @b_col = [] # entry index of the block in its row, at MCU column 0
      @b_colstep = [] # entries per MCU column
      @b_rowstep = []
      @b_pred = []
      @b_fast = []
      @b_look = []
      @b_table = []
      si = 0
      while si < comps.size
        c = comps[si]
        decoder.latch_quant(c) if c.needed
        t = decoder.huffman_table(false, dcs[si]) if @kind == DC_FIRST
        hn = interleaved ? c.h : 1
        vn = interleaved ? c.v : 1
        stride = c.stride
        by = 0
        while by < vn
          bx = 0
          while bx < hn
            @b_rows << c.coefs
            @b_need << c.needed
            @b_width << c.abw * stride
            @b_row << by
            @b_col << bx * stride
            @b_colstep << hn * stride
            @b_rowstep << vn
            @b_pred << si
            if t
              @b_table << t
              @b_fast << t.fast
              @b_look << t.look
            end
            bx += 1
          end
          by += 1
        end
        si += 1
      end
      @nb = @b_rows.size
    end

    # Coefficient row +r+ of the block list +rows+ (allocated on first use).
    def coef_row(rows, r, width)
      row = rows[r]
      if row.empty?
        row = Array.new(width, 0)
        rows[r] = row
      end
      row
    end

    # DC first / refinement scan, MCUs mx0...mx1 of MCU row my.
    def dc_row(my, mx0, mx1)
      words = @words
      acc = @acc
      bits = @bits
      wi = @wi
      preds = @preds
      refine = @kind == DC_REFINE
      al = @al
      bit = 1 << al
      nb = @nb
      mx = mx0
      while mx < mx1
        b = 0
        while b < nb
          if bits < 31
            acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
            wi += 1
            bits += 32
          end
          need = @b_need[b]
          if need
            coefs = coef_row(@b_rows[b], @b_row[b] + my * @b_rowstep[b], @b_width[b])
            idx = @b_col[b] + mx * @b_colstep[b]
          else
            coefs = JPEG_NONE
            idx = 0
          end
          if refine
            bits -= 1
            coefs[idx] |= bit if need && ((acc >> bits) & 1) == 1
          else
            e = @b_fast[b][(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
            if e != 0
              bits -= e & 255
              diff = e >> 16
            else
              e = @b_look[b][(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
              e = @b_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e == 0
              bits -= e >> 8
              s = e & 255
              if s == 0
                diff = 0
              else
                diff = (acc >> (bits - s)) & ((1 << s) - 1)
                bits -= s
                diff -= (1 << s) - 1 if diff < (1 << (s - 1))
              end
            end
            ci = @b_pred[b]
            pred = ((preds[ci] + diff + 32_768) & 0xFFFF) - 32_768
            preds[ci] = pred
            coefs[idx] = (((pred << al) + 32_768) & 0xFFFF) - 32_768 if need
          end
          b += 1
        end
        if (wi << 5) - bits > @endbit
          # Out of data: undo this MCU of a first scan.
          undo_dc(my, mx) unless refine
          return false
        end
        mx += 1
      end
      @acc = acc
      @bits = bits
      @wi = wi
      true
    end

    def undo_dc(my, mx)
      b = 0
      while b < @nb
        if @b_need[b]
          coef_row(@b_rows[b], @b_row[b] + my * @b_rowstep[b], @b_width[b])[@b_col[b] + mx * @b_colstep[b]] = 0
        end
        b += 1
      end
    end

    # First scan of AC band ss..se, blocks bx0...bx1 of block row by.
    def ac_first_row(by, bx0, bx1)
      words = @words
      acc = @acc
      bits = @bits
      wi = @wi
      eobrun = @eobrun
      table = @table
      fast = table.fast
      look = table.look
      coefs = coef_row(@rows, by, @abw * JPEG_BLOCK_STRIDE)
      ss = @ss
      se = @se
      al = @al
      zz = JPEG_ZIGZAG_EXT
      bx = bx0
      while bx < bx1
        if eobrun > 0
          # Blocks inside an end-of-band run have nothing in this band.
          skip = bx1 - bx
          skip = eobrun if eobrun < skip
          eobrun -= skip
          bx += skip
          next
        end
        base = bx * JPEG_BLOCK_STRIDE
        k = ss
        last = 0
        while k <= se
          if bits < 31
            acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
            wi += 1
            bits += 32
          end
          peek = (acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK
          e = fast[peek]
          if e != 0 && (v = e >> 16) != 0
            bits -= e & 255
            k += (e >> 8) & 255
            coefs[base + zz[k]] = (((v << al) + 32_768) & 0xFFFF) - 32_768
            last = k
            k += 1
          else
            e = look[peek]
            e = table.decode_long((acc >> (bits - 16)) & 0xFFFF) if e == 0
            bits -= e >> 8
            s = e & 15
            r = (e >> 4) & 15
            if s != 0
              k += r
              v = (acc >> (bits - s)) & ((1 << s) - 1)
              bits -= s
              v -= (1 << s) - 1 if v < (1 << (s - 1))
              coefs[base + zz[k]] = (((v << al) + 32_768) & 0xFFFF) - 32_768
              last = k
              k += 1
            elsif r == 15
              k += 16
            else
              # End of band: this block and 2^r - 1 + (r extra bits) more.
              eobrun = (1 << r) - 1
              if r > 0
                eobrun += (acc >> (bits - r)) & ((1 << r) - 1)
                bits -= r
              end
              break
            end
          end
        end
        if (wi << 5) - bits > @endbit
          # Out of data: undo this block (the band was empty before).
          k = ss
          while k <= se
            coefs[base + zz[k]] = 0
            k += 1
          end
          return false
        end
        last = 63 if last > 63
        coefs[base + 64] = last if last > coefs[base + 64]
        bx += 1
      end
      @acc = acc
      @bits = bits
      @wi = wi
      @eobrun = eobrun
      true
    end

    # Successive approximation refinement of AC band ss..se (libjpeg's
    # decode_mcu_AC_refine), blocks bx0...bx1 of block row by.
    def ac_refine_row(by, bx0, bx1)
      words = @words
      acc = @acc
      bits = @bits
      wi = @wi
      eobrun = @eobrun
      table = @table
      look = table.look
      coefs = coef_row(@rows, by, @abw * JPEG_BLOCK_STRIDE)
      ss = @ss
      se = @se
      p1 = 1 << @al
      m1 = -1 << @al
      zz = JPEG_ZIGZAG_EXT
      newnz = @newnz
      bx = bx0
      while bx < bx1
        base = bx * JPEG_BLOCK_STRIDE
        last = coefs[base + 64]
        nnz = 0
        if eobrun > 0 && last < ss
          # Inside an end-of-band run with nothing to refine in this band
          # (and likewise the following blocks).
          eobrun -= 1
          bx += 1
          while eobrun > 0 && bx < bx1 && coefs[bx * JPEG_BLOCK_STRIDE + 64] < ss
            eobrun -= 1
            bx += 1
          end
          next
        end
        k = ss
        if eobrun == 0
          while k <= se
            if bits < 31
              acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
              wi += 1
              bits += 32
            end
            e = look[(acc >> (bits - JPEG_FAST_BITS)) & JPEG_FAST_MASK]
            e = table.decode_long((acc >> (bits - 16)) & 0xFFFF) if e == 0
            bits -= e >> 8
            s = e & 15
            r = (e >> 4) & 15
            if s != 0
              # A new coefficient of magnitude 1 (its size should be 1).
              bits -= 1
              s = ((acc >> bits) & 1) == 1 ? p1 : m1
            elsif r != 15
              eobrun = 1 << r
              if r > 0
                eobrun += (acc >> (bits - r)) & ((1 << r) - 1)
                bits -= r
              end
              break
            end
            # Skip r zero coefficients, refining the nonzero ones passed.
            while k <= se
              pos = base + zz[k]
              cv = coefs[pos]
              if cv != 0
                if bits < 31
                  acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
                  wi += 1
                  bits += 32
                end
                bits -= 1
                if ((acc >> bits) & 1) == 1 && (cv & p1) == 0
                  coefs[pos] = (((cv >= 0 ? cv + p1 : cv + m1) + 32_768) & 0xFFFF) - 32_768
                end
              else
                r -= 1
                break if r < 0
              end
              k += 1
            end
            if s != 0
              pos = base + zz[k]
              coefs[pos] = s
              newnz[nnz] = pos
              nnz += 1 if nnz < 63
              last = k if k > last
            end
            k += 1
          end
        end
        if eobrun > 0
          # Refine the band's remaining nonzero coefficients; none lie beyond
          # the block's last nonzero position.
          limit = last < se ? last : se
          while k <= limit
            pos = base + zz[k]
            cv = coefs[pos]
            if cv != 0
              if bits < 31
                acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
                wi += 1
                bits += 32
              end
              bits -= 1
              if ((acc >> bits) & 1) == 1 && (cv & p1) == 0
                coefs[pos] = (((cv >= 0 ? cv + p1 : cv + m1) + 32_768) & 0xFFFF) - 32_768
              end
            end
            k += 1
          end
          eobrun -= 1
        end
        if (wi << 5) - bits > @endbit
          # Out of data: re-zero the coefficients this block made nonzero
          # (like libjpeg), so that its last nonzero index stays valid.
          while nnz > 0
            nnz -= 1
            coefs[newnz[nnz]] = 0
          end
          return false
        end

        coefs[base + 64] = last > 63 ? 63 : last
        bx += 1
      end
      @acc = acc
      @bits = bits
      @wi = wi
      @eobrun = eobrun
      true
    end
  end

  # Upsamples a subsampled component plane to the output size, choosing the
  # method like libjpeg (jdsample.c): with +fancy+ (DCT_scaled_size > 1) 2x
  # ratios use the "fancy" triangle filters (h2v1 and h2v2 only for
  # components wider than 2 samples, h1v2 always), other integer ratios
  # replicate samples. Fractional ratios, which libjpeg rejects, use the
  # nearest sample. Output rows are appended byte by byte (much faster than
  # packing an Array).
  class JpegUpsampler
    REPLICATE = 0
    H2V1 = 1
    H1V2 = 2
    H2V2 = 3

    # +plane+ has row stride +stride+; the component's valid size is +cw+ x
    # +ch+ samples, and +h+ x +v+ of them cover +hmax+ x +vmax+ output pixels.
    def initialize(plane, stride, cw, ch, hmax, vmax, h, v, fancy)
      @plane = plane
      @stride = stride
      @cw = cw
      @ch = ch
      @hmax = hmax
      @vmax = vmax
      @h = h
      @v = v
      @row_y_a = -1
      @row_y_b = -1
      @row_a = JPEG_NONE
      @row_b = JPEG_NONE
      @rh = (hmax % h) == 0 ? hmax / h : 0
      rv = (vmax % v) == 0 ? vmax / v : 0
      @mode = if fancy && @rh == 2 && rv == 1 && cw > 2 then H2V1
              elsif fancy && @rh == 1 && rv == 2 then H1V2
              elsif fancy && @rh == 2 && rv == 2 && cw > 2 then H2V2
              else REPLICATE
              end
    end

    def run(ow, oh)
      out = String.new(capacity: ow * oh, encoding: Encoding::BINARY)
      mode = @mode
      last_src = -1
      y = 0
      while y < oh
        start = out.bytesize
        if mode == H2V1
          h2v1(row(y), out, ow)
        elsif mode == H1V2
          h1v2(y, out)
        elsif mode == H2V2
          h2v2(y, out, ow)
        else
          # Replicated rows: copy the previous output row.
          src = y * @v / @vmax
          if src == last_src
            out << out.byteslice(start - ow, ow)
          else
            replicate_row(row(src), out, ow)
            last_src = src
          end
        end
        raise QrReader::ImageError, "corrupt JPEG: upsampling mismatch" unless out.bytesize == start + ow

        y += 1
      end
      out
    end

    private

    # Samples of component row +y+ (clamped to the valid rows, as libjpeg
    # repeats the first and last row for context), including the padding
    # columns after the valid width.
    def row(y)
      y = 0 if y < 0
      y = @ch - 1 if y >= @ch
      return @row_b if y == @row_y_b # the fancy filters read each row up to four times
      return @row_a if y == @row_y_a

      @row_y_b = @row_y_a
      @row_b = @row_a
      @row_y_a = y
      @row_a = @plane.byteslice(y * @stride, @stride).unpack("C*")
    end

    # Appends sample x * h / hmax of +src+ for x < ow: replication for
    # integer ratios, the nearest sample for fractional ones.
    def replicate_row(src, out, ow)
      last = @cw - 1
      rh = @rh
      x = 0
      if rh > 0
        sx = 0
        while x < ow
          v = src[sx]
          r = rh
          while r > 0 && x < ow
            out << v
            x += 1
            r -= 1
          end
          sx += 1
        end
      else
        h = @h
        hmax = @hmax
        while x < ow
          sx = x * h / hmax
          out << src[sx > last ? last : sx]
          x += 1
        end
      end
    end

    # libjpeg h1v2_fancy_upsample: 3/4 nearer + 1/4 further row.
    def h1v2(y, out)
      lower = (y & 1) == 1
      near = row(y >> 1)
      far = row(lower ? (y >> 1) + 1 : (y >> 1) - 1)
      bias = lower ? 2 : 1
      n = @cw
      x = 0
      while x < n
        out << ((near[x] * 3 + far[x] + bias) >> 2)
        x += 1
      end
    end

    # libjpeg h2v1_fancy_upsample: 3/4 nearer + 1/4 further sample. The last
    # output exists only if the output is that wide.
    def h2v1(s, out, ow)
      n = @cw
      out << s[0] << ((s[0] * 3 + s[1] + 2) >> 2)
      x = 1
      while x < n - 1
        t = s[x] * 3
        out << ((t + s[x - 1] + 1) >> 2) << ((t + s[x + 1] + 2) >> 2)
        x += 1
      end
      out << ((s[n - 1] * 3 + s[n - 2] + 1) >> 2)
      out << s[n - 1] if 2 * n <= ow
    end

    # libjpeg h2v2_fancy_upsample on column sums 3 * nearer + further row.
    def h2v2(y, out, ow)
      lower = (y & 1) == 1
      near = row(y >> 1)
      far = row(lower ? (y >> 1) + 1 : (y >> 1) - 1)
      n = @cw
      this = near[0] * 3 + far[0]
      nxt = near[1] * 3 + far[1]
      out << ((this * 4 + 8) >> 4) << ((this * 3 + nxt + 7) >> 4)
      x = 1
      while x < n - 1
        last = this
        this = nxt
        nxt = near[x + 1] * 3 + far[x + 1]
        t = this * 3
        out << ((t + last + 8) >> 4) << ((t + nxt + 7) >> 4)
        x += 1
      end
      out << ((nxt * 3 + this + 8) >> 4)
      out << ((nxt * 4 + 7) >> 4) if 2 * n <= ow
    end
  end
end
