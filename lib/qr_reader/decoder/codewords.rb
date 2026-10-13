# frozen_string_literal: true

module QrReader
  module Decoder
    # Codeword placement (ISO/IEC 18004 §7.7.3) and block structure.
    #
    # Everything that depends only on the version is computed once and cached
    # in a Layout: the module indices of all data bits in zig-zag placement
    # order, the data mask as one XOR value per codeword, and per EC level
    # the raw codeword indices of every RS block. Reading a block is then a
    # tight loop of getbyte calls on the module grid.
    module Codewords
      # Precomputed tables for one symbol version.
      class Layout
        # +order+: module indices of the data bits in placement order, 8 per
        # codeword. +mirrored_order+: the same for a symbol stored transposed
        # (mirrored), where module (x, y) lives at x * n + y.
        attr_reader :version, :dimension, :order, :mirrored_order

        def initialize(version)
          @version = version
          @dimension = version.dimension
          @order, @mirrored_order = build_orders
          @mask_codewords = Array.new(8)
          @blocks = {}
        end

        # One Integer per codeword: the bits that data mask +mask+ flips,
        # read from the mask's module grid like the data itself.
        def mask_codewords(mask)
          @mask_codewords[mask] ||= begin
            count = @order.size / 8
            Codewords.read_block(DataMask.grid(mask, @dimension), @order, Array.new(count, 0),
                                 Array.new(count) { |k| k }).freeze
          end
        end

        # RS blocks for EC level +level+ in block order: Array of
        # [data_codeword_count, raw_codeword_indices] (data then EC codewords).
        # Undoes the interleaving of §7.6: data codewords are taken from every
        # block in turn (shorter blocks run out first), then EC codewords.
        def blocks(level)
          @blocks[level] ||= build_blocks(@version.ec_blocks(level))
        end

        private

        # Undoes the interleaving of §7.6 (plain loops: runs once per level).
        def build_blocks(ec_blocks)
          data_counts = ec_blocks.data_codewords_per_block
          count = data_counts.size
          indices = Array.new(count) { [] }
          raw = 0
          longest = data_counts.max
          i = 0
          while i < longest
            b = 0
            while b < count
              if i < data_counts[b]
                indices[b] << raw
                raw += 1
              end
              b += 1
            end
            i += 1
          end
          i = 0
          while i < ec_blocks.ec_codewords_per_block
            b = 0
            while b < count
              indices[b] << raw
              raw += 1
              b += 1
            end
            i += 1
          end
          blocks = []
          b = 0
          while b < count
            blocks << [data_counts[b], indices[b].freeze].freeze
            b += 1
          end
          blocks.freeze
        end

        # Zig-zag over column pairs from the right, alternately upwards and
        # downwards, skipping the vertical timing column and function modules
        # (same traversal as ZXing's BitMatrixParser#readCodewords). Returns
        # the normal and the mirrored order; remainder bits are dropped.
        def build_orders
          n = @dimension
          function = FunctionPatterns.for_version(@version.number)
          order = []
          mirrored = []
          upward = true
          x = n - 1
          while x.positive?
            x -= 1 if x == 6
            count = 0
            while count < n
              y = upward ? n - 1 - count : count
              index = y * n + x
              if function.getbyte(index).zero?
                order << index
                mirrored << x * n + y
              end
              if function.getbyte(index - 1).zero?
                order << index - 1
                mirrored << (x - 1) * n + y
              end
              count += 1
            end
            upward = !upward
            x -= 2
          end
          limit = @version.total_codewords * 8
          [order.first(limit).freeze, mirrored.first(limit).freeze]
        end
      end

      @layouts = Array.new(41)

      class << self
        # Layout for version +number+ (1..40), built on first use.
        def layout(number)
          @layouts[number] ||= Layout.new(SymbolVersion[number])
        end

        # Reads and unmasks the codewords with the given raw indices from
        # +bits+ (a symbol's module String with only 0/1 bytes).
        def read_block(bits, order, mask_codewords, indices)
          count = indices.size
          out = Array.new(count)
          k = 0
          while k < count
            raw = indices[k]
            i = raw << 3
            out[k] = ((bits.getbyte(order[i]) << 7) | (bits.getbyte(order[i + 1]) << 6) |
                      (bits.getbyte(order[i + 2]) << 5) | (bits.getbyte(order[i + 3]) << 4) |
                      (bits.getbyte(order[i + 4]) << 3) | (bits.getbyte(order[i + 5]) << 2) |
                      (bits.getbyte(order[i + 6]) << 1) | bits.getbyte(order[i + 7])) ^ mask_codewords[raw]
            k += 1
          end
          out
        end

        # All codewords of a symbol in transmission (interleaved) order,
        # unmasked. Mainly for tests and diagnostics; the decoder reads block
        # by block so that garbage fails after the first block.
        def read(bit_matrix, version, mask, mirrored: false)
          layout = layout(version)
          order = mirrored ? layout.mirrored_order : layout.order
          mask_codewords = layout.mask_codewords(mask)
          read_block(bit_matrix.bits, order, mask_codewords, (0...mask_codewords.size).to_a)
        end

        # Splits interleaved codewords into RS blocks (Arrays of Integers).
        def deinterleave(codewords, version, level)
          layout(version).blocks(level).map { |_, indices| codewords.values_at(*indices) }
        end
      end
    end
  end
end
