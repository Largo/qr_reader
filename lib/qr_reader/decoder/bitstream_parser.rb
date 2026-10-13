# frozen_string_literal: true

module QrReader
  module Decoder
    # Raised by BitstreamParser for data that violates the bit stream syntax.
    # Decoder.decode turns it into a nil result.
    class FormatError < Error; end

    # Decoded data of one symbol, before it is wrapped into a Result.
    Content = Data.define(:text, :bytes, :segments, :eci, :fnc1, :structured_append, :symbology_identifier)

    # Parses the data codewords of a symbol (ISO/IEC 18004 §7.4): a sequence
    # of segments, each a 4-bit mode indicator followed by mode-specific data,
    # ended by the terminator 0000 or by running out of bits (fewer than 4 left).
    #
    #   BitstreamParser.parse("\x40\x24\x86\x90\xec".b, 1).text  # => "Hi" (byte mode, 2 chars)
    class BitstreamParser
      TERMINATOR = 0x0
      NUMERIC = 0x1
      ALPHANUMERIC = 0x2
      STRUCTURED_APPEND = 0x3
      BYTE = 0x4
      FNC1_FIRST = 0x5
      ECI = 0x7
      KANJI = 0x8
      FNC1_SECOND = 0x9
      HANZI = 0xD

      # Character count indicator lengths for versions 1-9, 10-26 and 27-40.
      COUNT_BITS = {
        NUMERIC => [10, 12, 14], ALPHANUMERIC => [9, 11, 13], BYTE => [8, 16, 16],
        KANJI => [8, 10, 12], HANZI => [8, 10, 12]
      }.freeze

      ALPHANUMERIC_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".b.freeze
      # Decoded text for every valid 10-bit numeric group ("000".."999").
      DIGIT_TRIPLES = ("000".."999").map(&:freeze).freeze
      GB2312_SUBSET = 1
      GROUP_SEPARATOR = "\x1D".b.freeze
      ASCII = Encoding::US_ASCII

      # Parses +data+ (binary String of data codewords) of a symbol of version
      # +version+ (1..40). Returns a Content; raises FormatError.
      def self.parse(data, version)
        new(data, version).parse
      end

      def initialize(data, version)
        raise ArgumentError, "version must be 1..40" unless version.is_a?(Integer) && version.between?(1, 40)

        @data = data.b + "\0\0" # padding so a 24-bit window never reads past the end
        @limit = data.bytesize * 8
        @pos = 0
        @size_class = if version <= 9 then 0
                      elsif version <= 26 then 1
                      else 2
                      end
      end

      def parse
        segments = [] # [mode, bytes, eci designator or nil]
        eci = nil
        first_eci = nil
        fnc1 = nil
        structured_append = nil
        while @limit - @pos >= 4
          mode = read_bits(4)
          case mode
          when TERMINATOR
            break
          when NUMERIC
            segments << [:numeric, numeric(read_count(mode)), eci]
          when ALPHANUMERIC
            segments << [:alphanumeric, alphanumeric(read_count(mode), fnc1), eci]
          when BYTE
            segments << [:byte, byte(read_count(mode)), eci]
          when KANJI
            segments << [:kanji, kanji(read_count(mode)), eci]
          when HANZI
            subset = read_bits(4)
            count = read_count(mode)
            raise FormatError, "unsupported Hanzi subset #{subset}" unless subset == GB2312_SUBSET

            segments << [:hanzi, hanzi(count), eci]
          when ECI
            eci = read_eci
            first_eci ||= eci
          when FNC1_FIRST
            fnc1 = :first
          when FNC1_SECOND
            fnc1 = [:second, application_indicator]
          when STRUCTURED_APPEND
            sequence = read_bits(8)
            structured_append = StructuredAppend.new(index: sequence >> 4, count: (sequence & 0x0F) + 1,
                                                     parity: read_bits(8))
          else
            raise FormatError, format("invalid mode indicator %04b", mode)
          end
        end
        build_content(segments, first_eci, fnc1, structured_append)
      end

      private

      def available
        @limit - @pos
      end

      # Next +count+ (<= 17) bits as an Integer, most significant first.
      def read_bits(count)
        pos = @pos
        raise FormatError, "bit stream ends early" if pos + count > @limit

        data = @data
        index = pos >> 3
        window = (data.getbyte(index) << 16) | (data.getbyte(index + 1) << 8) | data.getbyte(index + 2)
        @pos = pos + count
        (window >> (24 - (pos & 7) - count)) & ((1 << count) - 1)
      end

      def read_count(mode)
        read_bits(COUNT_BITS[mode][@size_class])
      end

      def require_bits(count)
        raise FormatError, "segment longer than the remaining data" if count > available
      end

      # 3 digits per 10 bits; a remainder of 2 digits takes 7 bits, 1 digit 4 bits.
      def numeric(count)
        require_bits(count / 3 * 10 + [0, 4, 7][count % 3])
        out = String.new(capacity: count, encoding: Encoding::BINARY)
        while count >= 3
          value = read_bits(10)
          raise FormatError, "invalid numeric group #{value}" if value >= 1000

          out << DIGIT_TRIPLES[value]
          count -= 3
        end
        if count == 2
          value = read_bits(7)
          raise FormatError, "invalid numeric group #{value}" if value >= 100

          out << DIGIT_TRIPLES[value].byteslice(1, 2)
        elsif count == 1
          value = read_bits(4)
          raise FormatError, "invalid numeric digit #{value}" if value >= 10

          out << DIGIT_TRIPLES[value].byteslice(2, 1)
        end
        out
      end

      # 2 characters per 11 bits, a final odd character in 6 bits. With FNC1
      # in effect, "%%" stands for "%" and a lone "%" for the GS separator.
      def alphanumeric(count, fnc1)
        require_bits(count / 2 * 11 + (count.odd? ? 6 : 0))
        out = String.new(capacity: count, encoding: Encoding::BINARY)
        while count >= 2
          value = read_bits(11)
          raise FormatError, "invalid alphanumeric pair #{value}" if value >= 2025

          out << ALPHANUMERIC_CHARS.getbyte(value / 45) << ALPHANUMERIC_CHARS.getbyte(value % 45)
          count -= 2
        end
        if count == 1
          value = read_bits(6)
          raise FormatError, "invalid alphanumeric character #{value}" if value >= 45

          out << ALPHANUMERIC_CHARS.getbyte(value)
        end
        out = out.gsub(/%%?/n) { |m| m.bytesize == 2 ? "%" : GROUP_SEPARATOR } if fnc1 && out.include?("%")
        out
      end

      def byte(count)
        require_bits(count * 8)
        start = @pos
        shift = start & 7
        @pos = start + count * 8
        return @data.byteslice(start >> 3, count) if shift.zero?

        # Unaligned: re-pack through a "0101..." string, at C speed.
        [@data.byteslice(start >> 3, count + 1).unpack1("B*").byteslice(shift, count * 8)].pack("B*")
      end

      # 13 bits per character: the Shift_JIS code minus 0x8140 or 0xC140,
      # high byte times 0xC0 plus low byte.
      def kanji(count)
        require_bits(count * 13)
        out = String.new(capacity: count * 2, encoding: Encoding::BINARY)
        count.times do
          value = read_bits(13)
          code = ((value / 0xC0) << 8) | (value % 0xC0)
          code += code < 0x1F00 ? 0x8140 : 0xC140
          out << (code >> 8) << (code & 0xFF)
        end
        out
      end

      # 13 bits per character: the GB 2312 code minus 0xA1A1 or 0xA6A1,
      # high byte times 0x60 plus low byte.
      def hanzi(count)
        require_bits(count * 13)
        out = String.new(capacity: count * 2, encoding: Encoding::BINARY)
        count.times do
          value = read_bits(13)
          code = ((value / 0x60) << 8) | (value % 0x60)
          code += code < 0x0A00 ? 0xA1A1 : 0xA6A1
          out << ((code >> 8) & 0xFF) << (code & 0xFF)
        end
        out
      end

      # ECI designator in 1, 2 or 3 bytes (0xxxxxxx, 10xxxxxx +8, 110xxxxx +16).
      def read_eci
        first = read_bits(8)
        value = if (first & 0x80).zero?
                  first
                elsif (first & 0xC0) == 0x80
                  ((first & 0x3F) << 8) | read_bits(8)
                elsif (first & 0xE0) == 0xC0
                  ((first & 0x1F) << 16) | read_bits(16)
                else
                  raise FormatError, "invalid ECI designator"
                end
        raise FormatError, "ECI designator #{value} out of range" if value > 999_999

        value
      end

      # FNC1 in second position is followed by an application indicator:
      # two digits (00-99) or one letter (encoded as its ASCII value + 100).
      def application_indicator
        value = read_bits(8)
        return format("%02d", value) if value < 100
        return (value - 100).chr if value.between?(165, 190) || value.between?(197, 222)

        raise FormatError, "invalid FNC1 application indicator #{value}"
      end

      def build_content(segments, first_eci, fnc1, structured_append)
        guessed = guess_encoding(segments) unless first_eci
        resolved = segments.map do |mode, bytes, eci|
          [mode, bytes, eci, segment_encoding(mode, eci, first_eci, guessed)]
        end
        text = +""
        bytes = String.new(encoding: Encoding::BINARY)
        segment_list = []
        run_start = 0
        resolved.each_with_index do |(mode, data, eci, encoding), i|
          bytes << data
          segment_list << Segment.new(mode: mode, text: CharacterSet.to_utf8(data, encoding), eci: eci)
          next_encoding = resolved[i + 1]&.last
          next if next_encoding == encoding

          # Convert runs of segments in the same encoding together, so a
          # character split across segments survives.
          text << if run_start == i
                    segment_list[i].text
                  else
                    CharacterSet.to_utf8(resolved[run_start..i].map { |s| s[1] }.join, encoding)
                  end
          run_start = i + 1
        end
        Content.new(text: text, bytes: bytes, segments: segment_list.freeze, eci: first_eci, fnc1: fnc1,
                    structured_append: structured_append,
                    symbology_identifier: "]Q#{symbology_modifier(first_eci, fnc1)}")
      end

      # ISO/IEC 18004 Table F.1: 1 plain, 3 FNC1 first, 5 FNC1 second;
      # one more when an ECI is present.
      def symbology_modifier(eci, fnc1)
        base = if fnc1 == :first then 3
               elsif fnc1 then 5
               else 1
               end
        eci ? base + 1 : base
      end

      # Without any ECI, all byte segments share one guessed encoding.
      def guess_encoding(segments)
        data = segments.filter_map { |mode, bytes, _| bytes if mode == :byte }
        data.empty? ? nil : CharacterSet.guess(data.join)
      end

      def segment_encoding(mode, eci, first_eci, guessed)
        case mode
        when :numeric, :alphanumeric then ASCII
        when :kanji then CharacterSet::SHIFT_JIS
        when :hanzi then CharacterSet::GB18030
        else
          if eci
            CharacterSet.for_eci(eci) || CharacterSet::ISO_8859_1
          elsif first_eci
            CharacterSet::ISO_8859_1 # default ECI 000003 before the first ECI
          else
            guessed
          end
        end
      end
    end
  end
end
