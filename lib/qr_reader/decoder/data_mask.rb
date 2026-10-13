# frozen_string_literal: true

module QrReader
  module Decoder
    # The eight data mask patterns of ISO/IEC 18004 Table 10. Only used to
    # precompute per-version tables, so clarity beats speed in masked?.
    module DataMask
      # Every pattern repeats after 12 rows and 12 columns (lcm of the 2-, 3-,
      # 4- and 6-periodic conditions).
      PERIOD = 12

      module_function

      # True if mask pattern +mask+ (0..7) inverts the module in column +x+,
      # row +y+ (ISO's j and i).
      def masked?(mask, x, y)
        case mask
        when 0 then (y + x).even?
        when 1 then y.even?
        when 2 then (x % 3).zero?
        when 3 then ((y + x) % 3).zero?
        when 4 then ((y / 2) + (x / 3)).even?
        when 5 then ((y * x) % 6).zero?          # (ij mod 2) + (ij mod 3) == 0
        when 6 then ((y * x) % 6) < 3            # ((ij mod 2) + (ij mod 3)) mod 2 == 0
        when 7 then (((y + x) % 2) + ((y * x) % 3)).even?
        else raise ArgumentError, "mask must be 0..7, got #{mask.inspect}"
        end
      end

      # The whole pattern for an n x n symbol as a binary String of n * n
      # bytes, row-major, "\x01" where the mask inverts the module. Built
      # from the 12 distinct rows, so it costs O(n) String operations.
      def grid(mask, n)
        repeat = n / PERIOD + 1
        rows = Array.new(PERIOD)
        y = 0
        while y < PERIOD
          unit = "\0".b * PERIOD
          x = 0
          while x < PERIOD
            unit.setbyte(x, 1) if masked?(mask, x, y)
            x += 1
          end
          rows[y] = (unit * repeat).byteslice(0, n)
          y += 1
        end
        out = "".b
        y = 0
        while y < n
          out << rows[y % PERIOD]
          y += 1
        end
        out
      end
    end
  end
end
