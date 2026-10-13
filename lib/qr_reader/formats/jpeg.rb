# frozen_string_literal: true

module QrReader
  module Formats
    # Pure-Ruby JPEG decoder that produces luminance only.
    #
    #   JPEG.decode(bytes)            # => QrReader::Image
    #   JPEG.decode(bytes, scale: 4)  # => ceil(w/4) x ceil(h/4), like libjpeg's scaled decoding
    #   JPEG.dimensions(bytes)        # => [width, height]
    #
    # Supported: baseline (SOF0), extended sequential Huffman (SOF1) and
    # progressive (SOF2) 8-bit JPEGs with any sampling factors, restart
    # intervals, 8/16-bit quantisation tables, 1 component (gray), 3 components
    # (YCbCr, or RGB via Adobe APP14 / component ids "RGB") and 4 components
    # (Adobe CMYK and YCCK). Arithmetic coding, lossless, hierarchical and
    # 12-bit JPEGs raise UnsupportedImageError. The output matches
    # libjpeg-turbo's default "islow" IDCT exactly, including the reduced
    # IDCTs used for scale 2, 4 and 8. Truncated scan data decodes what is
    # present (missing blocks stay mid-gray); other corruption raises
    # ImageError. EXIF orientation is ignored.
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
    #   that can be nonzero (generated from libjpeg's formulas).
    # * Hot loops live in methods called per MCU or per block row, so YJIT
    #   (which compiles a method once it has been called 30 times) kicks in
    #   during the first decode.
    # * Samples are collected four to an Array element (32-bit words) per MCU
    #   row and packed to bytes at C speed.
    module JPEG
      # Lookahead bits of the Huffman fast tables.
      FAST_BITS = 10
      FAST_MASK = (1 << FAST_BITS) - 1

      # Run used for end-of-block in the AC fast tables: it pushes the
      # coefficient index past 63, ending the block loop without a branch.
      # A block loop that ended at k > EOB_RUN had its EOB at k - EOB_RUN - 1.
      EOB_RUN = 100

      # Zigzag index -> natural (row-major) index.
      ZIGZAG = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
      ].freeze

      # ZIGZAG extended for corrupt runs past 63 (clamped to 63 like libjpeg)
      # and for the end-of-block pseudo run (scratch slot 64).
      ZIGZAG_EXT = (ZIGZAG + [63] * 16 + [64] * (EOB_RUN + 4 - 16)).freeze

      # libjpeg's post-IDCT range limiting, indexed by (sample + 128) & 1023:
      # clamps to 0..255 (and wraps far out-of-range values the same way).
      RANGE_LIMIT = Array.new(1024) do |i|
        c = (i - 128) & 1023
        if c < 128 then c + 128
        elsif c < 512 then 255
        elsif c < 896 then 0
        else c - 896
        end
      end.freeze

      # Entries per block in a progressive coefficient row: 64 coefficients
      # in natural order (not dequantised) and, at index 64, the zigzag index
      # of the last nonzero one. (At scale 8 only the DC is kept: 1 entry.)
      BLOCK_STRIDE = 65

      # Decoded samples are buffered as packed big-endian words. By output
      # block size (8 / scale): samples per word, words per block row, the
      # factor that repeats a sample over a word, and the pack directive.
      SAMPLES_PER_WORD = [nil, 1, 2, nil, 4, nil, nil, nil, 4].freeze
      WORDS = [nil, 1, 1, nil, 1, nil, nil, nil, 2].freeze
      SPREAD = [nil, 1, 0x0101, nil, 0x01010101, nil, nil, nil, 0x01010101].freeze
      PACK = [nil, "C*", "n*", nil, "N*", nil, nil, nil, "N*"].freeze

      # Largest supported output (64 Mi pixels, e.g. 8192 x 8192); bigger
      # images need a larger +scale+. Guards against absurd header sizes.
      MAX_PIXELS = 1 << 26

      # Decoded scans after which the rest of a file is ignored: crafted files
      # with endless refinement scans could otherwise take very long (real
      # progressive files have about 6 to 20 scans).
      MAX_SCANS = 256

      # Standard Huffman tables (ITU T.81 Annex K.3), used when a scan refers
      # to an undefined table 0 or 1 (Motion-JPEG frames omit them), like
      # libjpeg-turbo does. [code counts per length, symbols].
      STD_DC_LUMA = [[0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], (0..11).to_a].freeze
      STD_DC_CHROMA = [[0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], (0..11).to_a].freeze
      STD_AC_LUMA = [
        [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d],
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
        ]
      ].freeze
      STD_AC_CHROMA = [
        [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77],
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

      UNSUPPORTED_SOF = {
        0xC3 => "lossless", 0xC5 => "hierarchical", 0xC6 => "hierarchical progressive",
        0xC7 => "hierarchical lossless", 0xC9 => "arithmetic-coded", 0xCA => "arithmetic-coded progressive",
        0xCB => "arithmetic-coded lossless", 0xCD => "arithmetic-coded hierarchical",
        0xCE => "arithmetic-coded hierarchical progressive", 0xCF => "arithmetic-coded hierarchical lossless"
      }.freeze

      class << self
        # Decodes JPEG +bytes+ to a luminance Image. +scale+ (1, 2, 4 or 8)
        # decodes at reduced size: ceil(width / scale) x ceil(height / scale).
        def decode(bytes, scale: 1)
          Decoder.new(bytes, scale).decode
        end

        # [width, height] from the frame header, without decoding.
        def dimensions(bytes)
          Decoder.new(bytes, 1).dimensions
        end
      end

      # Raised internally when the data ends early; decoding then finishes
      # with what was decoded so far.
      class Truncated < ImageError; end

      # A Huffman table with FAST_BITS lookahead tables.
      #
      # +look+ maps the next FAST_BITS bits to (code length << 8 | symbol), or
      # 0 for longer codes (see #decode_long). +fast+ also folds in the extra
      # bits: (value << 16) | (run << 8) | (total bit length), or 0 when code
      # and extra bits do not fit in FAST_BITS. Zero-valued AC entries are the
      # end-of-block (run EOB_RUN) and ZRL (run 15) symbols.
      class HuffmanTable
        attr_reader :fast, :look

        # +counts+: number of codes of each length 1..16; +symbols+ in code order.
        def initialize(counts, symbols, ac)
          @fast = Array.new(1 << FAST_BITS, 0)
          @look = Array.new(1 << FAST_BITS, 0)
          @maxcode = Array.new(18, 0)
          @valoff = Array.new(17, 0)
          @symbols = symbols
          code = 0
          index = 0
          len = 1
          while len <= 16
            n = counts[len - 1]
            @valoff[len] = index - code
            n.times do
              sym = symbols[index]
              raise ImageError, "corrupt JPEG: bad DC Huffman symbol #{sym}" if !ac && sym > 15

              add_entries(code, len, sym, ac) if len <= FAST_BITS
              code += 1
              index += 1
            end
            # Codes must fit in len bits and may not be all ones (like libjpeg).
            raise ImageError, "corrupt JPEG: bad Huffman table" if n.positive? && code >= (1 << len)

            @maxcode[len] = code << (16 - len)
            code <<= 1
            len += 1
          end
          @maxcode[17] = 1 << 17
        end

        # Decodes a code longer than FAST_BITS from the next 16 bits.
        # Returns (length << 8) | symbol; an invalid code yields symbol 0 and
        # length 16 ("fake a zero", like libjpeg).
        def decode_long(window)
          len = FAST_BITS + 1
          len += 1 while window >= @maxcode[len]
          return 16 << 8 if len > 16

          (len << 8) | @symbols[(window >> (16 - len)) + @valoff[len]]
        end

        private

        def add_entries(code, len, sym, ac)
          shift = FAST_BITS - len
          base = code << shift
          @look.fill((len << 8) | sym, base, 1 << shift)
          if ac
            run = sym >> 4
            size = sym & 15
          else
            run = 0
            size = sym
          end
          if size.zero?
            # DC: difference 0. AC: ZRL, or end of block (libjpeg treats every
            # other zero-size symbol in sequential scans as EOB).
            run = EOB_RUN if ac && run != 15
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
      class Component
        attr_reader :id, :h, :v, :tq, :index
        # Sample size at full scale, blocks covered by a non-interleaved scan,
        # allocated block grid (padded to whole MCUs) and plane size in samples.
        attr_accessor :cw, :ch, :bw, :bh, :abw, :abh, :pw, :ph
        # Whether the component contributes to the luminance output.
        attr_accessor :needed
        # Output plane (binary String, pw x ph), and for progressive JPEGs the
        # coefficients: one Array per block row, allocated on first use, with
        # BLOCK_STRIDE entries per block.
        attr_accessor :plane, :coefs
        # Latched dequantisation table, indexed by (extended) zigzag position.
        attr_accessor :qz

        def initialize(index, id, h, v, tq)
          @index = index
          @id = id
          @h = h
          @v = v
          @tq = tq
        end
      end

      # Inverse DCTs, bit-exact with libjpeg's jidctint.c ("islow", 8x8 output)
      # and jidctred.c (4x4 and 2x2 output for scaled decoding).
      #
      # The methods are generated from libjpeg's 1-D kernels, specialised for
      # blocks whose nonzero coefficients lie in the top-left n x n corner
      # (dropping zero terms changes nothing in integer arithmetic). Rounding
      # and the +128 level shift are folded into the DC term of each pass.
      #
      # Input: coefficients in natural order, either dequantised (#transform)
      # or raw at offset +base+ with dequantisation table +q+
      # (#transform_dequant, for stored progressive coefficients). Output: a
      # bs x bs block written to the Array +out+ as packed big-endian words
      # (WORDS[bs] per block row, see PACK) at word offset +off+ with row
      # stride +stride+ (in words). Writing four samples per Array element
      # instead of one is markedly faster under YJIT.
      #
      # One instance (with a fixed set of instance variables, which keeps
      # YJIT's code monomorphic) serves a whole decode.
      class IDCT
        # Inputs that each reduced IDCT reads (libjpeg skips the others).
        INPUTS = { 8 => [0, 1, 2, 3, 4, 5, 6, 7], 4 => [0, 1, 2, 3, 5, 6, 7], 2 => [0, 1, 3, 5, 7] }.freeze

        # Generated variants per output size: inputs limited to rows/columns 0...n.
        VARIANTS = { 8 => [2, 4, 6, 8], 4 => [2, 4, 8], 2 => [2, 8] }.freeze

        class << self
          # libjpeg islow 1-D kernel for inputs d0...d(n-1) (the rest zero).
          # +t0+ maps an even-part sum to the scaled and rounded DC term.
          # Returns [statements, the 8 outputs before descaling].
          def islow(n, t0)
            pairs = %w[t10+o3 t11+o2 t12+o1 t13+o0 t13-o0 t12-o1 t11-o2 t10-o3]
            case n
            when 2
              [["t0 = #{t0['d0']}", "o3 = d1 * 11_363", "o2 = d1 * 9633", "o1 = d1 * 6437", "o0 = d1 * 2260"],
               %w[t0+o3 t0+o2 t0+o1 t0+o0 t0-o0 t0-o1 t0-o2 t0-o3]]
            when 4
              [["t0 = #{t0['d0']}", "t2 = d2 * 4433", "t3 = d2 * 10_703",
                "t10 = t0 + t3", "t13 = t0 - t3", "t11 = t0 + t2", "t12 = t0 - t2",
                "o0 = d1 * 2260 - d3 * 6436", "o1 = d1 * 6437 - d3 * 11_362",
                "o2 = d1 * 9633 - d3 * 2259", "o3 = d1 * 11_363 + d3 * 9633"], pairs]
            when 6
              [["t0 = #{t0['d0 + d4']}", "t1 = #{t0['d0 - d4']}", "t2 = d2 * 4433", "t3 = d2 * 10_703",
                "t10 = t0 + t3", "t13 = t0 - t3", "t11 = t1 + t2", "t12 = t1 - t2",
                "z2 = d5 + d3", "z4 = d5 + d1", "z5 = (z4 + d3) * 9633",
                "z1 = d1 * -7373", "z2 *= -20_995", "z3 = d3 * -16_069 + z5", "z4 = z4 * -3196 + z5",
                "o0 = z1 + z3", "o1 = d5 * 16_819 + z2 + z4", "o2 = d3 * 25_172 + z2 + z3",
                "o3 = d1 * 12_299 + z1 + z4"], pairs]
            else
              [["z1 = (d2 + d6) * 4433", "t2 = z1 - d6 * 15_137", "t3 = z1 + d2 * 6270",
                "t0 = #{t0['d0 + d4']}", "t1 = #{t0['d0 - d4']}",
                "t10 = t0 + t3", "t13 = t0 - t3", "t11 = t1 + t2", "t12 = t1 - t2",
                "z1 = d7 + d1", "z2 = d5 + d3", "z3 = d7 + d3", "z4 = d5 + d1", "z5 = (z3 + z4) * 9633",
                "z1 *= -7373", "z2 *= -20_995", "z3 = z3 * -16_069 + z5", "z4 = z4 * -3196 + z5",
                "o0 = d7 * 2446 + z1 + z3", "o1 = d5 * 16_819 + z2 + z4",
                "o2 = d3 * 25_172 + z2 + z3", "o3 = d1 * 12_299 + z1 + z4"], pairs]
            end
          end

          # jidctred 1-D kernels with 4 or 2 outputs, for the nonzero +inputs+.
          def reduced(size, inputs, t0)
            sum = lambda do |terms|
              t = terms.select { |i, _| inputs.include?(i) }.map { |i, k| "d#{i} * #{k}" }
              t.empty? ? "0" : t.join(" + ")
            end
            if size == 4
              [["t0 = #{t0['d0']}", "t2 = #{sum[[[2, 15_137], [6, -6270]]]}", "t10 = t0 + t2", "t12 = t0 - t2",
                "o0 = #{sum[[[7, -1730], [5, 11_893], [3, -17_799], [1, 8697]]]}",
                "o2 = #{sum[[[7, -4176], [5, -4926], [3, 7373], [1, 20_995]]]}"],
               %w[t10+o2 t12+o0 t12-o0 t10-o2]]
            else
              [["t10 = #{t0['d0']}", "t0 = #{sum[[[7, -5906], [5, 6967], [3, -10_426], [1, 29_692]]]}"],
               %w[t10+t0 t10-t0]]
            end
          end

          # Source of method [u]idct[q]<size>_<n>: pass 1 transforms the used
          # columns into a workspace, pass 2 its rows into packed output
          # words. +dequant+: read raw coefficients at c[base + i] and multiply
          # by q[i]. +unrolled+: no loops, the workspace lives in locals.
          def method_source(size, n, dequant, unrolled)
            used = INPUTS[size].select { |i| i < n }
            shift = { 8 => 13, 4 => 14, 2 => 15 }[size] # DC scaling of each pass
            pass1 = shift - 2
            pass2 = shift + 5
            kernel = ->(t0) { size == 8 ? islow(n, t0) : reduced(size, used, t0) }
            at = ->(base, k) { k.zero? ? base : "#{base} + #{k}" }
            ac_zero = (used - [0]).map { |k| "d#{k} == 0" }.join(" && ")
            name = "#{'u' if unrolled}idct#{'q' if dequant}#{size}_#{n}"
            src = ["def #{name}(c, #{'base, q, ' if dequant}out, off, stride)", "rl = RANGE_LIMIT"]

            # Pass 1, one column: input index expression and workspace slot per row.
            column = lambda do |input, q_index, slot, dc_q|
              used.each { |r| src << "d#{r} = c[#{input[r]}]" }
              src << "if #{ac_zero}" << "#{(0...size).map { |r| slot[r] }.join(' = ')} = #{dc_q} << 2" << "else"
              used.each { |r| src << "d#{r} *= q[#{q_index[r]}]" } if dequant
              stmts, outs = kernel[->(e) { "((#{e}) << #{shift}) + #{1 << (pass1 - 1)}" }]
              src.concat(stmts)
              outs.each_with_index { |o, r| src << "#{slot[r]} = (#{o}) >> #{pass1}" }
              src << "end"
            end
            # Pass 2, one row from workspace slots to packed words.
            row = lambda do |slot|
              used.each { |k| src << "d#{k} = #{slot[k]}" }
              src << "if #{ac_zero}" << "v = rl[((d0 + 4112) >> 5) & 1023] * #{SPREAD[size]}"
              WORDS[size].times { |w| src << "out[#{at['off', w]}] = v" }
              src << "else"
              stmts, outs = kernel[->(e) { "((#{e}) + 4112) << #{shift}" }]
              src.concat(stmts)
              outs.map { |o| "rl[((#{o}) >> #{pass2}) & 1023]" }.each_slice(SAMPLES_PER_WORD[size]).with_index do |px, w|
                word = px.each_with_index.map { |p, j| (shift8 = 8 * (px.size - 1 - j)).zero? ? p : "(#{p} << #{shift8})" }
                src << "out[#{at['off', w]}] = #{word.join(' | ')}"
              end
              src << "end"
            end

            if unrolled
              used.each do |col|
                input = ->(r) { dequant ? "base + #{8 * r + col}" : (8 * r + col).to_s }
                column.call(input, ->(r) { 8 * r + col }, ->(r) { "w#{r}#{col}" }, dequant ? "(d0 * q[#{col}])" : "d0")
              end
              size.times do |r|
                row.call(->(k) { "w#{r}#{k}" })
                src << "off += stride" if r < size - 1
              end
            else
              gaps = used.each_cons(2).reject { |a, b| b == a + 1 }.map(&:first)
              step = gaps.empty? ? "1" : "(#{gaps.map { |g| "i == #{g}" }.join(' || ')} ? 2 : 1)"
              src << "ws = @ws" << "i = 0" << "while i <= #{used.max}"
              src << "ci = base + i" if dequant
              column.call(->(r) { at[dequant ? "ci" : "i", 8 * r] }, ->(r) { at["i", 8 * r] },
                          ->(r) { "ws[#{at['i', 8 * r]}]" }, dequant ? "(d0 * q[i])" : "d0")
              src << "i += #{step}" << "end" << "i = 0" << "while i < #{8 * size}"
              row.call(->(k) { "ws[#{at['i', k]}]" })
              src << "off += stride" << "i += 8" << "end"
            end
            src << "end"
            src.join("\n")
          end

          # Whether to use the unrolled 8x8 variants: they are ~15% faster in
          # the interpreter, but YJIT compiles them slowly (and gains little),
          # so they are only generated, on first use, when YJIT is off.
          def unrolled?
            return false if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?

            unless method_defined?(:uidct8_8)
              VARIANTS[8].each do |n|
                class_eval(method_source(8, n, false, true), __FILE__, __LINE__)
                class_eval(method_source(8, n, true, true), __FILE__, __LINE__)
              end
            end
            true
          end
        end

        VARIANTS.each do |size, ns|
          ns.each do |n|
            class_eval(method_source(size, n, false, false), __FILE__, __LINE__)
            class_eval(method_source(size, n, true, false), __FILE__, __LINE__)
          end
        end

        # +bs+: output block size 8, 4 or 2 (scale 8 needs no IDCT, only #fill).
        def initialize(bs)
          @bs = bs
          @unrolled = bs == 8 && IDCT.unrolled?
          @ws = Array.new(64, 0)
        end

        # IDCT of the dequantised block +c+ whose last nonzero coefficient
        # has zigzag index +km+ (> 0; DC-only blocks are filled by callers).
        def transform(c, km, out, off, stride)
          case @bs
          when 8
            if @unrolled
              if km <= 2 then uidct8_2(c, out, off, stride)
              elsif km <= 9 then uidct8_4(c, out, off, stride)
              elsif km <= 20 then uidct8_6(c, out, off, stride)
              else uidct8_8(c, out, off, stride)
              end
            elsif km <= 2 then idct8_2(c, out, off, stride)
            elsif km <= 9 then idct8_4(c, out, off, stride)
            elsif km <= 20 then idct8_6(c, out, off, stride)
            else idct8_8(c, out, off, stride)
            end
          when 4
            if km <= 2 then idct4_2(c, out, off, stride)
            elsif km <= 9 then idct4_4(c, out, off, stride)
            else idct4_8(c, out, off, stride)
            end
          else
            km <= 2 ? idct2_2(c, out, off, stride) : idct2_8(c, out, off, stride)
          end
        end

        # Like #transform for the raw block at c[base, 64], dequantised with
        # +q+ (natural order) on the fly.
        def transform_dequant(c, base, q, km, out, off, stride)
          case @bs
          when 8
            if @unrolled
              if km <= 2 then uidctq8_2(c, base, q, out, off, stride)
              elsif km <= 9 then uidctq8_4(c, base, q, out, off, stride)
              elsif km <= 20 then uidctq8_6(c, base, q, out, off, stride)
              else uidctq8_8(c, base, q, out, off, stride)
              end
            elsif km <= 2 then idctq8_2(c, base, q, out, off, stride)
            elsif km <= 9 then idctq8_4(c, base, q, out, off, stride)
            elsif km <= 20 then idctq8_6(c, base, q, out, off, stride)
            else idctq8_8(c, base, q, out, off, stride)
            end
          when 4
            if km <= 2 then idctq4_2(c, base, q, out, off, stride)
            elsif km <= 9 then idctq4_4(c, base, q, out, off, stride)
            else idctq4_8(c, base, q, out, off, stride)
            end
          else
            km <= 2 ? idctq2_2(c, base, q, out, off, stride) : idctq2_8(c, base, q, out, off, stride)
          end
        end

        # Sample of a DC-only block (the same for every IDCT size).
        def dc_sample(dequantised_dc)
          RANGE_LIMIT[((dequantised_dc + 1028) >> 3) & 1023]
        end

        # Fills a bs x bs block of +out+ (packed words) with sample +value+.
        def fill(out, off, stride, value)
          bs = @bs
          v = value * SPREAD[bs]
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
      end

      # Decoder state for one JPEG stream (internal; use JPEG.decode and
      # JPEG.dimensions).
      class Decoder
        STUFFED = "\xFF\x00".b.freeze
        FF = "\xFF".b.freeze
        # End of an entropy-coded segment: 0xFF not followed by a stuffed zero
        # or a restart marker.
        SEGMENT_END = /\xFF[^\x00\xD0-\xD7]/n
        RST_MARKER = /\xFF[\xD0-\xD7]/n
        NOT_FF = /[^\xFF]/n
        FILL_BYTES = /\xFF+(?=[\x00\xD0-\xD7])/n
        DNL_MARKER = "\xFF\xDC\x00\x04".b.freeze
        # Zero words appended to a scan: more than one MCU can consume, so a
        # truncated MCU never reads past the end of the word array.
        TAIL_PADDING = ("\0" * 4096).b.freeze
        WORD_PADDING = ["".b, "\0".b, "\0\0".b, "\0\0\0".b].freeze

        ScanComponent = Struct.new(:comp, :dc, :ac)

        # libjpeg's YCbCr -> RGB tables (jdcolor.c, 16-bit fixed point),
        # indexed by the Cb/Cr sample.
        CR_R = Array.new(256) { |i| (91_881 * (i - 128) + 32_768) >> 16 }.freeze
        CB_B = Array.new(256) { |i| (116_130 * (i - 128) + 32_768) >> 16 }.freeze
        CR_G = Array.new(256) { |i| -46_802 * (i - 128) }.freeze
        CB_G = Array.new(256) { |i| -22_554 * (i - 128) + 32_768 }.freeze

        # Output block size (8 / scale), IDCT, restart interval and MCU grid.
        attr_reader :bs, :idct, :restart_interval, :mcux, :mcuy

        def initialize(bytes, scale)
          raise ArgumentError, "scale must be 1, 2, 4 or 8" unless [1, 2, 4, 8].include?(scale)
          raise ImageError, "JPEG data must be a String" unless bytes.is_a?(String)

          @data = bytes.encoding == Encoding::BINARY ? bytes : bytes.b
          @scale = scale
          @bs = 8 / scale
          @idct = IDCT.new(@bs)
          @qt = Array.new(4)
          @dc_defs = Array.new(4)
          @ac_defs = Array.new(4)
          @dc_tables = Array.new(4)
          @ac_tables = Array.new(4)
          @restart_interval = 0
          @jfif = false
          @adobe_transform = nil
          @components = nil
          @scans_decoded = 0
        end

        def dimensions
          parse(true)
          raise ImageError, "JPEG has no frame header" unless @components

          resolve_height
          [@width, @height]
        rescue Truncated
          raise ImageError, "truncated JPEG header"
        end

        def decode
          begin
            parse(false)
          rescue UnsupportedImageError
            raise
          rescue ImageError
            # Truncation or corruption after complete scans: keep what was decoded.
            raise if @scans_decoded.zero?
          end
          raise ImageError, "JPEG has no image data" if @scans_decoded.zero?

          finish
        rescue NoMethodError, TypeError, ArgumentError, RangeError, IndexError, ZeroDivisionError,
               EncodingError => e
          # Safety net: garbage input must only ever raise ImageError.
          raise ImageError, "corrupt JPEG data (internal #{e.class}: #{e.message})"
        end

        # MCU geometry of a scan: [MCUs per row, MCU rows, [[scan component, bx, by], ...]]
        # (a non-interleaved scan has one block per MCU).
        def scan_layout(scomps)
          if scomps.size == 1
            c = scomps[0].comp
            [c.bw, c.bh, [[scomps[0], 0, 0]]]
          else
            blocks = []
            scomps.each do |s|
              c = s.comp
              c.v.times { |by| c.h.times { |bx| blocks << [s, bx, by] } }
            end
            [@mcux, @mcuy, blocks]
          end
        end

        def huffman_table(ac, id)
          tables = ac ? @ac_tables : @dc_tables
          tables[id] ||= begin
            defn = (ac ? @ac_defs : @dc_defs)[id]
            defn ||= case id
                     when 0 then ac ? STD_AC_LUMA : STD_DC_LUMA
                     when 1 then ac ? STD_AC_CHROMA : STD_DC_CHROMA
                     end
            raise ImageError, "corrupt JPEG: missing Huffman table" unless defn

            HuffmanTable.new(defn[0], defn[1], ac)
          end
        end

        # Latches the component's quantisation table (as libjpeg does at the
        # component's first scan), indexed by extended zigzag position.
        def latch_quant(comp)
          return if comp.qz

          q = @qt[comp.tq] or raise ImageError, "corrupt JPEG: missing quantisation table #{comp.tq}"
          comp.qz = q + [q[63]] * 16 + [0] * (ZIGZAG_EXT.size - 80)
        end

        private

        # ---------------------------------------------------------------
        # Marker parsing

        def parse(header_only)
          data = @data
          raise ImageError, "not a JPEG file" unless data.getbyte(0) == 0xFF && data.getbyte(1) == 0xD8

          pos = 2
          while (marker = next_marker(pos))
            code, pos = marker
            case code
            when 0xC0, 0xC1, 0xC2
              pos = read_frame(pos, code)
              return if header_only
            when 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF
              raise UnsupportedImageError, "#{UNSUPPORTED_SOF[code]} JPEG is not supported" unless header_only

              read_frame(pos, code)
              return
            when 0xC4 then pos = read_dht(pos)
            when 0xDB then pos = read_dqt(pos)
            when 0xDD then pos = read_dri(pos)
            when 0xDA
              raise ImageError, "corrupt JPEG: scan before frame header" if header_only

              pos = read_scan(pos)
            when 0xD9 then break
            when 0xE0 then pos = read_app0(pos)
            when 0xEE then pos = read_app14(pos)
            when 0xD0..0xD8, 0x01 then next # markers without payload
            when 0xDE, 0xDF then raise UnsupportedImageError, "hierarchical JPEG is not supported"
            when 0x02..0xBF then raise ImageError, format("corrupt JPEG: unknown marker 0x%02X", code)
            else pos = segment_end(pos)
            end
          end
        end

        # Finds the next marker at or after +pos+, skipping junk and fill
        # bytes. Returns [code, position after the code] or nil at the end.
        def next_marker(pos)
          data = @data
          loop do
            pos = data.index(FF, pos) or return nil
            pos += 1 while data.getbyte(pos) == 0xFF
            code = data.getbyte(pos) or return nil
            return [code, pos + 1] unless code.zero?
          end
        end

        def u16(pos)
          hi = @data.getbyte(pos)
          lo = @data.getbyte(pos + 1)
          raise Truncated, "truncated JPEG" unless lo

          (hi << 8) | lo
        end

        def byte(pos)
          @data.getbyte(pos) or raise Truncated, "truncated JPEG"
        end

        # Position after the marker segment whose length field is at +pos+.
        def segment_end(pos)
          len = u16(pos)
          raise ImageError, "corrupt JPEG: bad marker length" if len < 2
          raise Truncated, "truncated JPEG" if pos + len > @data.bytesize

          pos + len
        end

        def read_frame(pos, code)
          stop = segment_end(pos)
          raise ImageError, "corrupt JPEG: duplicate frame header" if @components

          @precision = byte(pos + 2)
          @height = u16(pos + 3)
          @width = u16(pos + 5)
          count = byte(pos + 7)
          raise ImageError, "corrupt JPEG: bad image width" if @width.zero?
          raise ImageError, "corrupt JPEG: bad component count" unless count.between?(1, 10)
          raise ImageError, "corrupt JPEG: bad frame header length" if stop - pos != 8 + 3 * count

          @progressive = code == 0xC2
          @components = Array.new(count) do |i|
            p = pos + 8 + 3 * i
            hv = byte(p + 1)
            h = hv >> 4
            v = hv & 15
            tq = byte(p + 2)
            raise ImageError, "corrupt JPEG: bad sampling factors" unless h.between?(1, 4) && v.between?(1, 4)
            raise ImageError, "corrupt JPEG: bad quantisation table id" if tq > 3

            Component.new(i, byte(p), h, v, tq)
          end
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
            raise ImageError, "corrupt JPEG: bad Huffman table id" if klass > 1 || id > 3

            counts = Array.new(16) { |i| byte(p + 1 + i) }
            total = counts.sum
            raise ImageError, "corrupt JPEG: bad Huffman table" if total > 256 || p + 17 + total > stop

            symbols = @data.byteslice(p + 17, total).bytes
            if klass.zero?
              @dc_defs[id] = [counts, symbols]
              @dc_tables[id] = nil
            else
              @ac_defs[id] = [counts, symbols]
              @ac_tables[id] = nil
            end
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
            size = precision.zero? ? 64 : 128
            raise ImageError, "corrupt JPEG: bad quantisation table" if precision > 1 || id > 3 || p + 1 + size > stop

            @qt[id] = @data.byteslice(p + 1, size).unpack(precision.zero? ? "C64" : "n64")
            p += 1 + size
          end
          stop
        end

        def read_dri(pos)
          stop = segment_end(pos)
          raise ImageError, "corrupt JPEG: bad DRI marker" if stop - pos != 4

          @restart_interval = u16(pos + 2)
          stop
        end

        def read_app0(pos)
          stop = segment_end(pos)
          @jfif = true if stop - pos >= 16 && @data.byteslice(pos + 2, 5) == "JFIF\0".b
          stop
        end

        def read_app14(pos)
          stop = segment_end(pos)
          @adobe_transform = byte(pos + 13) if stop - pos >= 14 && @data.byteslice(pos + 2, 5) == "Adobe".b
          stop
        end

        # Height 0 in the frame header means it is given by a DNL marker after
        # the first scan (0xFF 0xDC cannot occur inside scan data).
        def resolve_height
          return unless @height.zero?

          at = @data.index(DNL_MARKER, @frame_end) or raise ImageError, "corrupt JPEG: zero image height"
          @height = u16(at + 4)
          raise ImageError, "corrupt JPEG: zero image height" if @height.zero?
        end

        # ---------------------------------------------------------------
        # Frame setup (at the first scan, when all header markers are known)

        def setup_frame
          return if @hmax

          if @precision != 8
            raise UnsupportedImageError, "#{@precision}-bit JPEG is not supported" if [12, 16].include?(@precision)

            raise ImageError, "corrupt JPEG: bad sample precision #{@precision}"
          end
          resolve_height
          w = @width
          h = @height
          @out_w = (w + @scale - 1) / @scale
          @out_h = (h + @scale - 1) / @scale
          raise UnsupportedImageError, "JPEG too large (#{w}x#{h})" if @out_w * @out_h > MAX_PIXELS

          comps = @components
          @color = color_space
          needed = { rgb: [0, 1, 2], cmyk: [0, 1, 2, 3], ycck: [0, 1, 2, 3] }.fetch(@color, [0])
          @hmax = comps.map(&:h).max
          @vmax = comps.map(&:v).max
          @mcux = (w + 8 * @hmax - 1) / (8 * @hmax)
          @mcuy = (h + 8 * @vmax - 1) / (8 * @vmax)
          comps.each { |c| setup_component(c, needed.include?(c.index), comps.size == 1) }
        end

        def setup_component(c, needed, single)
          c.cw = (@width * c.h + @hmax - 1) / @hmax
          c.ch = (@height * c.v + @vmax - 1) / @vmax
          c.bw = (c.cw + 7) / 8
          c.bh = (c.ch + 7) / 8
          c.abw = single ? c.bw : @mcux * c.h
          c.abh = single ? c.bh : @mcuy * c.v
          c.pw = c.abw * @bs
          c.ph = c.abh * @bs
          c.needed = needed
          return unless needed

          if @progressive
            c.coefs = Array.new(c.abh)
          else
            c.plane = "\x80".b * (c.pw * c.ph)
          end
        end

        # Colour space of the stored components, following libjpeg's rules.
        def color_space
          comps = @components
          case comps.size
          when 1 then :gray
          when 3
            if @jfif then :ycbcr
            elsif @adobe_transform then @adobe_transform.zero? ? :rgb : :ycbcr
            elsif comps.map(&:id) == [82, 71, 66] then :rgb # "RGB"
            else :ycbcr
            end
          when 4 then @adobe_transform.nil? || @adobe_transform.zero? ? :cmyk : :ycck
          else :unknown
          end
        end

        # ---------------------------------------------------------------
        # Scans

        def read_scan(pos)
          raise ImageError, "corrupt JPEG: scan before frame header" unless @components

          stop = segment_end(pos)
          count = byte(pos + 2)
          raise ImageError, "corrupt JPEG: bad scan header" if !count.between?(1, 4) || stop - pos != 6 + 2 * count

          scomps = Array.new(count) do |i|
            id = byte(pos + 3 + 2 * i)
            tables = byte(pos + 4 + 2 * i)
            comp = @components.find { |c| c.id == id } or raise ImageError, "corrupt JPEG: bad scan component"
            raise ImageError, "corrupt JPEG: bad Huffman table id" if (tables >> 4) > 3 || (tables & 15) > 3

            ScanComponent.new(comp, tables >> 4, tables & 15)
          end
          ss = byte(stop - 3)
          se = byte(stop - 2)
          ah = byte(stop - 1) >> 4
          al = byte(stop - 1) & 15

          setup_frame
          if count > 1 && scomps.sum { |s| s.comp.h * s.comp.v } > 10
            raise ImageError, "corrupt JPEG: too many blocks per MCU"
          end

          validate_progression(count, ss, se, ah, al) if @progressive
          seg_end, fill = scan_extent(stop)
          if decode_scan?(scomps, ss)
            raise ImageError, "corrupt JPEG: too many scans" if @scans_decoded >= MAX_SCANS

            words, starts, ends = entropy_words(stop, seg_end, fill)
            @scans_decoded += 1
            if @progressive
              ProgressiveScan.new(self, scomps, ss, se, ah, al, words, starts, ends).run
            else
              SequentialScan.new(self, scomps, words, starts, ends).run
            end
          end
          seg_end
        end

        def validate_progression(count, ss, se, ah, al)
          bad = ss.zero? ? !se.zero? : ss > se || se > 63 || count != 1
          bad ||= ah != 0 && al != ah - 1
          bad ||= al > 13
          raise ImageError, "corrupt JPEG: bad progressive scan parameters" if bad
        end

        # Whether a scan contributes to the output (progressive scans that only
        # carry chroma, or AC data at scale 8, are skipped).
        def decode_scan?(scomps, ss)
          return true unless @progressive
          return false if !ss.zero? && @bs == 1

          scomps.any? { |s| s.comp.needed }
        end

        # End of the entropy-coded data starting at +pos+: the first 0xFF that
        # is neither stuffing nor a restart marker. Fill bytes (0xFF runs)
        # before stuffing or RST are allowed; +fill+ tells whether any occur.
        # Returns [end position, fill].
        def scan_extent(pos)
          data = @data
          fill = false
          while (e = data.index(SEGMENT_END, pos))
            return [e, fill] unless data.getbyte(e + 1) == 0xFF

            r = data.index(NOT_FF, e + 1)
            return [e, fill] unless r

            c = data.getbyte(r)
            return [e, fill] unless c.zero? || c.between?(0xD0, 0xD7)

            fill = true
            pos = r + 1
          end
          [data.bytesize, fill]
        end

        # Splits the entropy-coded segment [pos, stop) at restart markers,
        # removes byte stuffing and unpacks it to big-endian 32-bit words.
        # Each restart interval starts on a word boundary; starts[i] is its
        # first word, ends[i] the bit position just after its data.
        def entropy_words(pos, stop, fill)
          seg = @data.byteslice(pos, stop - pos)
          seg = seg.byteslice(0, seg.bytesize - 1) if seg.end_with?(FF) # dangling half of a stuffed byte
          seg = seg.gsub(FILL_BYTES, FF) if fill
          rst = seg.index(RST_MARKER)
          pieces = if rst.nil? then [seg]
                   elsif @restart_interval.zero? then [seg.byteslice(0, rst)] # a stray RST ends the data, like in libjpeg
                   else seg.split(RST_MARKER, -1)
                   end
          buf = String.new(capacity: seg.bytesize + 4 * pieces.size + TAIL_PADDING.bytesize, encoding: Encoding::BINARY)
          starts = []
          ends = []
          pieces.each do |piece|
            piece = piece.gsub(STUFFED, FF) if piece.include?(STUFFED)
            word = buf.bytesize >> 2
            starts << word
            ends << ((word << 5) + (piece.bytesize << 3))
            buf << piece << WORD_PADDING[-piece.bytesize & 3]
          end
          buf << TAIL_PADDING
          [buf.unpack("N*"), starts, ends]
        end

        # ---------------------------------------------------------------
        # Output

        def finish
          @components.each { |c| render_coefficients(c) if c.needed } if @progressive
          ow = @out_w
          oh = @out_h
          comps = @components
          data = case @color
                 when :rgb then convert(comps[0, 3].map { |c| component_samples(c) }) { |*a| rgb_row(*a) }
                 when :cmyk then convert(comps[0, 4].map { |c| component_samples(c) }) { |*a| cmyk_row(*a) }
                 when :ycck then convert(comps[0, 4].map { |c| component_samples(c) }) { |*a| ycck_row(*a) }
                 else component_samples(comps[0])
                 end
          Image.new(ow, oh, data)
        end

        # IDCTs the stored progressive coefficients of +c+ into its plane.
        def render_coefficients(c)
          latch_quant(c)
          q = Array.new(64, 0)
          64.times { |k| q[ZIGZAG[k]] = c.qz[k] }
          plane = String.new(capacity: c.pw * c.ph, encoding: Encoding::BINARY)
          buf = Array.new(c.pw / SAMPLES_PER_WORD[@bs] * @bs, 0)
          pack = PACK[@bs]
          c.abh.times { |by| render_row(c, by, q, buf).pack(pack, buffer: plane) }
          c.plane = plane
          c.coefs = nil
        end

        # IDCTs block row +by+ of +c+ into +buf+ (packed words).
        def render_row(c, by, q, buf)
          coefs = c.coefs[by]
          return buf.fill(128 * SPREAD[@bs]) unless coefs # no data: all coefficients 0

          idct = @idct
          bs = @bs
          stride = c.pw / SAMPLES_PER_WORD[bs]
          step = WORDS[bs]
          base = 0
          off = 0
          while off < stride
            if bs == 1
              buf[off] = idct.dc_sample(coefs[base] * q[0])
              base += 1
            else
              km = coefs[base + 64]
              if km.zero?
                idct.fill(buf, off, stride, idct.dc_sample(coefs[base] * q[0]))
              else
                idct.transform_dequant(coefs, base, q, km, buf, off, stride)
              end
              base += BLOCK_STRIDE
            end
            off += step
          end
          buf
        end

        # Samples of component +c+ at output size (cropped, or upsampled when
        # the component is subsampled relative to the frame).
        def component_samples(c)
          ow = @out_w
          oh = @out_h
          return crop(c.plane, c.pw, ow, oh) if c.h == @hmax && c.v == @vmax

          # Component size at this scale (libjpeg's downsampled size).
          cw = (@width * c.h * @bs + @hmax * 8 - 1) / (@hmax * 8)
          ch = (@height * c.v * @bs + @vmax * 8 - 1) / (@vmax * 8)
          Upsampler.new(c.plane, c.pw, cw, ch, @hmax, @vmax, c.h, c.v, @bs == 8).run(ow, oh)
        end

        def crop(plane, pw, w, h)
          return plane.byteslice(0, w * h) if pw == w

          out = String.new(capacity: w * h, encoding: Encoding::BINARY)
          h.times { |y| out << plane.byteslice(y * pw, w) }
          out
        end

        # Combines component planes into luminance, one row per block call.
        def convert(planes)
          w = @out_w
          out = "\0".b * (w * @out_h)
          @out_h.times { |y| yield(*planes, out, y * w, w) }
          out
        end

        def rgb_row(r, g, b, out, i, n)
          stop = i + n
          while i < stop
            out.setbyte(i, (306 * r.getbyte(i) + 601 * g.getbyte(i) + 117 * b.getbyte(i) + 0x200) >> 10)
            i += 1
          end
        end

        # Adobe CMYK JPEGs store inverted ink (255 = no ink), so the stored
        # values are 255 - ink: R = C' * K' / 255 and so on.
        def cmyk_row(c, m, y, k, out, i, n)
          stop = i + n
          while i < stop
            kk = k.getbyte(i)
            r = (c.getbyte(i) * kk + 127) / 255
            g = (m.getbyte(i) * kk + 127) / 255
            b = (y.getbyte(i) * kk + 127) / 255
            out.setbyte(i, (306 * r + 601 * g + 117 * b + 0x200) >> 10)
            i += 1
          end
        end

        # YCCK stores YCbCr-encoded CMY plus K; libjpeg converts it to CMYK
        # with its fixed-point YCbCr->RGB tables (C = 255 - R, ...), which
        # then goes through #cmyk_row's formula.
        def ycck_row(y, cb, cr, k, out, i, n)
          cr_r = CR_R
          cb_b = CB_B
          cr_g = CR_G
          cb_g = CB_G
          stop = i + n
          while i < stop
            yy = 255 - y.getbyte(i)
            u = cb.getbyte(i)
            v = cr.getbyte(i)
            kk = k.getbyte(i)
            c = (yy - cr_r[v]).clamp(0, 255)
            m = (yy - ((cb_g[u] + cr_g[v]) >> 16)).clamp(0, 255)
            ye = (yy - cb_b[u]).clamp(0, 255)
            out.setbyte(i, (306 * ((c * kk + 127) / 255) + 601 * ((m * kk + 127) / 255) +
                            117 * ((ye * kk + 127) / 255) + 0x200) >> 10)
            i += 1
          end
        end
      end

      # Decodes one sequential (baseline or extended) scan straight into the
      # component planes. Blocks of components that do not contribute to the
      # luminance are entropy-decoded and dropped.
      class SequentialScan
        def initialize(decoder, scomps, words, starts, ends)
          @bs = decoder.bs
          @idct = decoder.idct
          @ri = decoder.restart_interval
          @words = words
          @starts = starts
          @ends = ends
          @mcux, @mcuy, layout = decoder.scan_layout(scomps)
          @nb = layout.size
          @preds = Array.new(scomps.size, 0)
          @kmax = Array.new(@nb, 0)
          @rows = [] # [component, row buffer, rows per MCU row, words per MCU, words per row]
          setup_blocks(decoder, scomps, layout)
        end

        def run
          total = @mcux * @mcuy
          ri = @ri
          mcu = 0
          interval = 0
          mx = 0
          my = 0
          while mcu < total
            if interval >= @starts.size
              finish_row(mx, my) # no data left: the rest stays gray
              return
            end
            n = total - mcu
            n = ri if ri.positive? && ri < n
            start_interval(interval)
            interval += 1
            dead = false
            while n.positive?
              n -= 1
              mcu += 1
              if dead
                gray_mcu(mx)
              elsif !decode_mcu(mx)
                # Ran past the end of the data: drop this MCU and the rest of
                # the interval (or of the image).
                dead = true
                if ri.zero? || interval >= @starts.size
                  finish_row(mx, my)
                  return
                end
                gray_mcu(mx)
              end
              mx += 1
              next unless mx == @mcux

              flush(my)
              mx = 0
              my += 1
            end
          end
        end

        private

        def setup_blocks(decoder, scomps, layout)
          interleaved = scomps.size > 1
          bs = @bs
          @dc_fast = []
          @dc_look = []
          @dc_table = []
          @ac_fast = []
          @ac_look = []
          @ac_table = []
          @pred = []
          @blk = []
          @q = []
          @out = []
          @off = []
          @step = []
          @stride = []
          buffers = {}
          layout.each do |s, bx, by|
            c = s.comp
            dc = decoder.huffman_table(false, s.dc)
            ac = decoder.huffman_table(true, s.ac)
            @dc_table << dc
            @dc_fast << dc.fast
            @dc_look << dc.look
            @ac_table << ac
            @ac_fast << ac.fast
            @ac_look << ac.look
            @pred << scomps.index { |x| x.equal?(s) }
            unless c.needed
              @blk << nil
              @q << nil
              @out << nil
              @off << 0
              @step << 0
              @stride << 0
              next
            end

            decoder.latch_quant(c)
            stride = c.pw / SAMPLES_PER_WORD[bs] # row buffers hold packed words
            step = (interleaved ? c.h : 1) * WORDS[bs]
            buffers[c] ||= begin
              nrows = (interleaved ? c.v : 1) * bs
              buf = Array.new(stride * nrows, 0)
              @rows << [c, buf, nrows, step, stride]
              buf
            end
            @blk << Array.new(65, 0)
            @q << c.qz
            @out << buffers[c]
            @off << (by * bs * stride) + (bx * WORDS[bs])
            @step << step
            @stride << stride
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
          zz = ZIGZAG_EXT
          dc_only = @bs == 1
          nb = @nb
          b = 0
          while b < nb
            # DC coefficient (bits >= 31 after a refill covers any code + extra bits)
            if bits < 31
              acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
              wi += 1
              bits += 32
            end
            e = @dc_fast[b][(acc >> (bits - FAST_BITS)) & FAST_MASK]
            if e != 0
              bits -= e & 255
              diff = e >> 16
            else
              e = @dc_look[b][(acc >> (bits - FAST_BITS)) & FAST_MASK]
              e = @dc_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e.zero?
              bits -= e >> 8
              s = e & 255
              if s.zero?
                diff = 0
              else
                diff = (acc >> (bits - s)) & ((1 << s) - 1)
                bits -= s
                diff -= (1 << s) - 1 if diff < (1 << (s - 1))
              end
            end
            ci = @pred[b]
            pred = ((preds[ci] + diff + 32_768) & 0xFFFF) - 32_768 # JCOEF wraps to 16 bits
            preds[ci] = pred

            # AC coefficients
            fast = @ac_fast[b]
            blk = @blk[b]
            k = 1
            if blk && !dc_only
              q = @q[b]
              blk[0] = pred * q[0]
              while k < 64
                if bits < 31
                  acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
                  wi += 1
                  bits += 32
                end
                e = fast[(acc >> (bits - FAST_BITS)) & FAST_MASK]
                if e != 0
                  bits -= e & 255
                  k += (e >> 8) & 255
                  blk[zz[k]] = (e >> 16) * q[k]
                  k += 1
                else
                  e = @ac_look[b][(acc >> (bits - FAST_BITS)) & FAST_MASK]
                  e = @ac_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e.zero?
                  bits -= e >> 8
                  s = e & 15
                  if s != 0
                    k += (e >> 4) & 15
                    v = (acc >> (bits - s)) & ((1 << s) - 1)
                    bits -= s
                    v -= (1 << s) - 1 if v < (1 << (s - 1))
                    blk[zz[k]] = v * q[k]
                    k += 1
                  elsif (e & 0xF0) == 0xF0
                    k += 16
                  else
                    k += EOB_RUN + 1
                  end
                end
              end
              kmaxes[b] = k > EOB_RUN ? k - EOB_RUN - 2 : 63
            else
              if blk
                blk[0] = pred * @q[b][0]
                kmaxes[b] = 0
              end
              # Skip the AC coefficients.
              while k < 64
                if bits < 31
                  acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
                  wi += 1
                  bits += 32
                end
                e = fast[(acc >> (bits - FAST_BITS)) & FAST_MASK]
                if e != 0
                  bits -= e & 255
                  k += ((e >> 8) & 255) + 1
                else
                  e = @ac_look[b][(acc >> (bits - FAST_BITS)) & FAST_MASK]
                  e = @ac_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e.zero?
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
          end

          if (wi << 5) - bits > @endbit
            @blk.each { |x| x&.fill(0) }
            return false
          end

          @acc = acc
          @bits = bits
          @wi = wi
          idct = @idct
          b = 0
          while b < nb
            blk = @blk[b]
            if blk
              off = @off[b] + mx * @step[b]
              km = kmaxes[b]
              if km.zero?
                idct.fill(@out[b], off, @stride[b], idct.dc_sample(blk[0]))
                blk[0] = 0
              else
                idct.transform(blk, km, @out[b], off, @stride[b])
                blk.fill(0)
              end
            end
            b += 1
          end
          true
        end

        # Fills the MCU at column +mx+ of the row buffers with mid-gray.
        def gray_mcu(mx)
          @nb.times do |b|
            @idct.fill(@out[b], @off[b] + mx * @step[b], @stride[b], 128) if @blk[b]
          end
        end

        # Copies MCU row +my+ from the row buffers into the planes.
        def flush(my)
          pack = PACK[@bs]
          @rows.each do |c, buf, nrows, _, _|
            len = c.pw * nrows
            start = my * len
            c.plane.bytesplice(start, len, buf.pack(pack)) if start + len <= c.plane.bytesize
          end
        end

        # Grays MCUs +mx+.. of the current row and flushes it; rows below
        # keep their (initially gray) content.
        def finish_row(mx, my)
          gray = 128 * SPREAD[@bs]
          @rows.each do |_, buf, nrows, step, stride|
            from = mx * step
            nrows.times { |r| buf.fill(gray, r * stride + from, stride - from) } if from < stride
          end
          flush(my) if my < @mcuy
        end
      end

      # Decodes one progressive scan into the stored coefficients: DC first or
      # refinement (possibly interleaved), or AC first or refinement of one
      # spectral band of one component.
      class ProgressiveScan
        def initialize(decoder, scomps, ss, se, ah, al, words, starts, ends)
          @ri = decoder.restart_interval
          @words = words
          @starts = starts
          @ends = ends
          @ss = ss
          @se = se
          @al = al
          @units_x, @units_y, layout = decoder.scan_layout(scomps)
          if ss.zero?
            @kind = ah.zero? ? :dc_first : :dc_refine
            setup_dc(decoder, scomps, layout)
          else
            @kind = ah.zero? ? :ac_first : :ac_refine
            c = scomps[0].comp
            decoder.latch_quant(c)
            @table = decoder.huffman_table(true, scomps[0].ac)
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
            n = ri if ri.positive? && ri < n
            @wi = @starts[interval]
            @endbit = @ends[interval]
            @acc = 0
            @bits = 0
            @eobrun = 0
            @preds&.fill(0)
            interval += 1
            stop = u + n
            while u < stop
              y = u / ux
              x0 = u - y * ux
              x1 = x0 + stop - u
              x1 = ux if x1 > ux
              ok = case @kind
                   when :dc_first, :dc_refine then dc_row(y, x0, x1)
                   when :ac_first then ac_first_row(y, x0, x1)
                   else ac_refine_row(y, x0, x1)
                   end
              # On running out of data, skip the rest of the interval.
              u = ok ? u + x1 - x0 : stop
            end
          end
        end

        private

        def setup_dc(decoder, scomps, layout)
          interleaved = scomps.size > 1
          @stride = decoder.bs == 1 ? 1 : BLOCK_STRIDE
          @nb = layout.size
          @preds = Array.new(scomps.size, 0)
          @b_rows = []
          @b_width = []
          @b_row = []
          @b_col = []
          @b_colstep = []
          @b_rowstep = []
          @b_pred = []
          @b_fast = []
          @b_look = []
          @b_table = []
          layout.each do |s, bx, by|
            c = s.comp
            decoder.latch_quant(c) if c.needed
            @b_rows << (c.needed ? c.coefs : nil)
            @b_width << c.abw * @stride
            @b_row << by
            @b_col << bx
            @b_colstep << (interleaved ? c.h : 1)
            @b_rowstep << (interleaved ? c.v : 1)
            @b_pred << scomps.index { |x| x.equal?(s) }
            next if @kind == :dc_refine

            t = decoder.huffman_table(false, s.dc)
            @b_table << t
            @b_fast << t.fast
            @b_look << t.look
          end
        end

        # DC first / refinement scan, MCUs mx0...mx1 of MCU row my.
        def dc_row(my, mx0, mx1)
          words = @words
          acc = @acc
          bits = @bits
          wi = @wi
          preds = @preds
          refine = @kind == :dc_refine
          al = @al
          bit = 1 << al
          stride = @stride
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
              if (rows = @b_rows[b])
                r = @b_row[b] + my * @b_rowstep[b]
                coefs = rows[r] || (rows[r] = Array.new(@b_width[b], 0))
                idx = (@b_col[b] + mx * @b_colstep[b]) * stride
              else
                coefs = nil
              end
              if refine
                bits -= 1
                coefs[idx] |= bit if coefs && ((acc >> bits) & 1) == 1
              else
                e = @b_fast[b][(acc >> (bits - FAST_BITS)) & FAST_MASK]
                if e != 0
                  bits -= e & 255
                  diff = e >> 16
                else
                  e = @b_look[b][(acc >> (bits - FAST_BITS)) & FAST_MASK]
                  e = @b_table[b].decode_long((acc >> (bits - 16)) & 0xFFFF) if e.zero?
                  bits -= e >> 8
                  s = e & 255
                  if s.zero?
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
                coefs[idx] = (((pred << al) + 32_768) & 0xFFFF) - 32_768 if coefs
              end
              b += 1
            end
            if (wi << 5) - bits > @endbit
              # Out of data: undo this MCU of a first scan.
              unless refine
                nb.times do |i|
                  next unless (rows = @b_rows[i])

                  rows[@b_row[i] + my * @b_rowstep[i]][(@b_col[i] + mx * @b_colstep[i]) * stride] = 0
                end
              end
              return false
            end
            mx += 1
          end
          @acc = acc
          @bits = bits
          @wi = wi
          true
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
          coefs = @rows[by] || (@rows[by] = Array.new(@abw * BLOCK_STRIDE, 0))
          ss = @ss
          se = @se
          al = @al
          zz = ZIGZAG_EXT
          bx = bx0
          while bx < bx1
            if eobrun.positive?
              # Blocks inside an end-of-band run have nothing in this band.
              skip = bx1 - bx
              skip = eobrun if eobrun < skip
              eobrun -= skip
              bx += skip
              next
            end
            base = bx * BLOCK_STRIDE
            k = ss
            last = 0
            while k <= se
              if bits < 31
                acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
                wi += 1
                bits += 32
              end
              peek = (acc >> (bits - FAST_BITS)) & FAST_MASK
              e = fast[peek]
              if e != 0 && (v = e >> 16) != 0
                bits -= e & 255
                k += (e >> 8) & 255
                coefs[base + zz[k]] = v << al
                last = k
                k += 1
              else
                e = look[peek]
                e = table.decode_long((acc >> (bits - 16)) & 0xFFFF) if e.zero?
                bits -= e >> 8
                s = e & 15
                r = (e >> 4) & 15
                if s != 0
                  k += r
                  v = (acc >> (bits - s)) & ((1 << s) - 1)
                  bits -= s
                  v -= (1 << s) - 1 if v < (1 << (s - 1))
                  coefs[base + zz[k]] = v << al
                  last = k
                  k += 1
                elsif r == 15
                  k += 16
                else
                  # End of band: this block and 2^r - 1 + (r extra bits) more.
                  eobrun = (1 << r) - 1
                  if r.positive?
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
          coefs = @rows[by] || (@rows[by] = Array.new(@abw * BLOCK_STRIDE, 0))
          ss = @ss
          se = @se
          p1 = 1 << @al
          m1 = -1 << @al
          zz = ZIGZAG_EXT
          bx = bx0
          while bx < bx1
            base = bx * BLOCK_STRIDE
            last = coefs[base + 64]
            if eobrun.positive? && last < ss
              # Inside an end-of-band run with nothing to refine in this band.
              eobrun -= 1
              bx += 1
              next
            end
            k = ss
            if eobrun.zero?
              while k <= se
                if bits < 31
                  acc = ((acc & ((1 << bits) - 1)) << 32) | words[wi]
                  wi += 1
                  bits += 32
                end
                e = look[(acc >> (bits - FAST_BITS)) & FAST_MASK]
                e = table.decode_long((acc >> (bits - 16)) & 0xFFFF) if e.zero?
                bits -= e >> 8
                s = e & 15
                r = (e >> 4) & 15
                if s != 0
                  # A new coefficient of magnitude 1 (its size should be 1).
                  bits -= 1
                  s = ((acc >> bits) & 1) == 1 ? p1 : m1
                elsif r != 15
                  eobrun = 1 << r
                  if r.positive?
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
                    coefs[pos] = cv >= 0 ? cv + p1 : cv + m1 if ((acc >> bits) & 1) == 1 && (cv & p1).zero?
                  else
                    r -= 1
                    break if r.negative?
                  end
                  k += 1
                end
                if s != 0
                  coefs[base + zz[k]] = s
                  last = k if k > last
                end
                k += 1
              end
            end
            if eobrun.positive?
              # Refine the band's remaining nonzero coefficients; none lie
              # beyond the block's last nonzero position.
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
                  coefs[pos] = cv >= 0 ? cv + p1 : cv + m1 if ((acc >> bits) & 1) == 1 && (cv & p1).zero?
                end
                k += 1
              end
              eobrun -= 1
            end
            return false if (wi << 5) - bits > @endbit

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

      # Upsamples a subsampled component plane to the output size. At full
      # scale, 2x ratios use libjpeg's "fancy" triangle filters (h2v1, h1v2,
      # h2v2); other integer ratios replicate samples, and fractional ratios
      # (which libjpeg rejects) use the nearest sample.
      class Upsampler
        # +plane+ has row stride +stride+; the component's valid size is
        # +cw+ x +ch+ samples.
        def initialize(plane, stride, cw, ch, hmax, vmax, h, v, fancy)
          @plane = plane
          @stride = stride
          @cw = cw
          @ch = ch
          @hmax = hmax
          @vmax = vmax
          @h = h
          @v = v
          rh = (hmax % h).zero? ? hmax / h : 0
          rv = (vmax % v).zero? ? vmax / v : 0
          @fancy = fancy && rh.between?(1, 2) && rv.between?(1, 2)
          @rh = rh
          @rv = rv
        end

        def run(ow, oh)
          out = String.new(capacity: ow * oh, encoding: Encoding::BINARY)
          oh.times do |y|
            line = @fancy ? fancy_row(y) : nearest_row(y, ow)
            line.fill(line[-1], line.size, ow - line.size) if line.size < ow
            line.pack("C#{ow}", buffer: out)
          end
          out
        end

        private

        # Samples of component row +y+ (clamped to the valid rows), including
        # the padding columns after the valid width.
        def row(y)
          y = y.clamp(0, @ch - 1)
          @plane.byteslice(y * @stride, @stride).bytes
        end

        def nearest_row(y, ow)
          src = row(y * @v / @vmax)
          last = @cw - 1
          Array.new(ow) do |x|
            sx = x * @h / @hmax
            src[sx > last ? last : sx]
          end
        end

        def fancy_row(y)
          if @rv == 2
            cy = y >> 1
            lower = y.odd?
            near = row(cy)
            far = row(lower ? cy + 1 : cy - 1)
            return h2v2(near, far) if @rh == 2

            bias = lower ? 2 : 1
            Array.new(@cw) { |x| (near[x] * 3 + far[x] + bias) >> 2 }
          else
            h2v1(row(y))
          end
        end

        # libjpeg h2v1_fancy_upsample: 3/4 nearer + 1/4 further sample. (With a
        # single valid column, the second output uses the padding column, as
        # in libjpeg.)
        def h2v1(s)
          n = @cw
          line = Array.new(2 * n, 0)
          line[0] = s[0]
          line[1] = (s[0] * 3 + s[1] + 2) >> 2
          return line if n == 1

          x = 1
          while x < n - 1
            t = s[x] * 3
            line[2 * x] = (t + s[x - 1] + 1) >> 2
            line[2 * x + 1] = (t + s[x + 1] + 2) >> 2
            x += 1
          end
          line[2 * n - 2] = (s[n - 1] * 3 + s[n - 2] + 1) >> 2
          line[2 * n - 1] = s[n - 1]
          line
        end

        # libjpeg h2v2_fancy_upsample on column sums 3 * near + far.
        def h2v2(near, far)
          n = @cw
          sums = Array.new(n < 2 ? 2 : n) { |x| near[x] * 3 + far[x] }
          line = Array.new(2 * n, 0)
          line[0] = (sums[0] * 4 + 8) >> 4
          line[1] = (sums[0] * 3 + sums[1] + 7) >> 4
          return line if n == 1

          x = 1
          while x < n - 1
            t = sums[x] * 3
            line[2 * x] = (t + sums[x - 1] + 8) >> 4
            line[2 * x + 1] = (t + sums[x + 1] + 7) >> 4
            x += 1
          end
          line[2 * n - 2] = (sums[n - 1] * 3 + sums[n - 2] + 8) >> 4
          line[2 * n - 1] = (sums[n - 1] * 4 + 7) >> 4
          line
        end
      end

      private_constant :Truncated, :HuffmanTable, :Component, :IDCT, :Decoder, :SequentialScan,
                       :ProgressiveScan, :Upsampler
    end
  end
end
