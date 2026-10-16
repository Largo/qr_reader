# frozen_string_literal: true

module QrReader
  module Decoder
    # Character sets: ECI designators to Ruby encodings, the encoding guess
    # for byte segments without ECI, and conversion to valid UTF-8.
    module CharacterSet
      UTF_8 = Encoding::UTF_8
      BINARY = Encoding::BINARY
      ISO_8859_1 = Encoding::ISO_8859_1
      SHIFT_JIS = Encoding::Shift_JIS
      # Superset of Shift_JIS (NEC/IBM extensions); used when strict Shift_JIS
      # cannot represent a character.
      WINDOWS_31J = Encoding::Windows_31J
      # Superset of GB 2312 (EUC-CN), used for Hanzi mode.
      GB18030 = Encoding::GB18030

      # ECI designator => Encoding (ISO/IEC 18004 / AIM ECI assignments as used
      # by ZXing). 899 is "binary": the bytes are shown as ISO-8859-1.
      ECI_ENCODINGS = {
        0 => Encoding::IBM437, 2 => Encoding::IBM437,
        1 => ISO_8859_1, 3 => ISO_8859_1,
        4 => Encoding::ISO_8859_2, 5 => Encoding::ISO_8859_3, 6 => Encoding::ISO_8859_4,
        7 => Encoding::ISO_8859_5, 8 => Encoding::ISO_8859_6, 9 => Encoding::ISO_8859_7,
        10 => Encoding::ISO_8859_8, 11 => Encoding::ISO_8859_9, 12 => Encoding::ISO_8859_10,
        13 => Encoding::ISO_8859_11, 15 => Encoding::ISO_8859_13, 16 => Encoding::ISO_8859_14,
        17 => Encoding::ISO_8859_15, 18 => Encoding::ISO_8859_16,
        20 => SHIFT_JIS,
        21 => Encoding::Windows_1250, 22 => Encoding::Windows_1251,
        23 => Encoding::Windows_1252, 24 => Encoding::Windows_1256,
        25 => Encoding::UTF_16BE, 26 => UTF_8,
        27 => Encoding::US_ASCII, 170 => Encoding::US_ASCII,
        28 => Encoding::Big5, 29 => GB18030, 30 => Encoding::EUC_KR,
        899 => BINARY
      }.freeze

      # Decodes one character that Shift_JIS cannot map, via Windows-31J.
      WINDOWS_31J_FALLBACK = lambda do |char|
        char.dup.force_encoding(WINDOWS_31J).encode(UTF_8, invalid: :replace, undef: :replace)
      end

      # GB 18030-2000 private-use code points (from the 2-byte codes A6D9..A6DF,
      # A6EC, A6ED, A6F3 and A8BC) and their GB 18030-2005 replacements.
      GB18030_PUA = "\uE78D\uE78E\uE78F\uE790\uE791\uE792\uE793\uE794\uE795\uE796\uE7C7"
      GB18030_2005 = "\uFE10\uFE12\uFE11\uFE13\uFE14\uFE15\uFE16\uFE17\uFE18\uFE19\u1E3F"

      module_function

      # Encoding for an ECI designator, or nil if it names no known character set.
      def for_eci(designator)
        ECI_ENCODINGS[designator]
      end

      # Guesses the encoding of byte-mode data without ECI, following ZXing's
      # StringUtils.guessCharset: UTF-16 with BOM; UTF-8 if the bytes are valid
      # UTF-8 (strictly) containing multibyte characters; Shift_JIS if the bytes
      # look like it (runs of 3+ double-byte or half-width katakana characters,
      # or many Latin-1 symbols); else ISO-8859-1. Like zxing-cpp, control
      # characters other than CR/LF mark the data as binary, not Shift_JIS,
      # so that it decodes losslessly as ISO-8859-1.
      def guess(bytes)
        return ISO_8859_1 if bytes.ascii_only?

        if bytes.bytesize > 2
          b0 = bytes.getbyte(0)
          b1 = bytes.getbyte(1)
          return Encoding::UTF_16BE if b0 == 0xFE && b1 == 0xFF
          return Encoding::UTF_16LE if b0 == 0xFF && b1 == 0xFE
        end
        return UTF_8 if bytes.dup.force_encoding(UTF_8).valid_encoding?

        guess_latin1_or_shift_jis(bytes)
      end

      # Converts +bytes+ in +encoding+ to a valid UTF-8 String (invalid or
      # unmappable sequences become U+FFFD).
      def to_utf8(bytes, encoding)
        return bytes.dup.force_encoding(UTF_8) if bytes.ascii_only? && encoding.ascii_compatible?

        case encoding
        when UTF_8
          bytes.dup.force_encoding(UTF_8).scrub
        when BINARY
          bytes.encode(UTF_8, ISO_8859_1)
        when SHIFT_JIS
          # Characters Shift_JIS lacks (NEC/IBM extensions) are taken from
          # Windows-31J one by one, so the rest keep their JIS X 0208 mapping.
          # Ruby maps 0x815C to U+2014 EM DASH; ZXing and zxing-cpp (like
          # Unicode's SHIFTJIS.TXT and Windows-31J) to U+2015 HORIZONTAL BAR.
          by_char(bytes, SHIFT_JIS, WINDOWS_31J_FALLBACK).tr("\u2014", "\u2015")
        when Encoding::EUC_KR
          by_char(bytes, Encoding::EUC_KR)
        when GB18030
          # Ruby uses the GB 18030-2000 private-use mappings for 11 GBK codes
          # that GB 18030-2005 (and zxing-cpp) map to standard characters.
          bytes.encode(UTF_8, GB18030, invalid: :replace, undef: :replace).tr(GB18030_PUA, GB18030_2005)
        when Encoding::UTF_16BE, Encoding::UTF_16LE
          text = bytes.encode(UTF_8, encoding, invalid: :replace, undef: :replace)
          text.delete_prefix("\uFEFF")
        else
          bytes.encode(UTF_8, encoding, invalid: :replace, undef: :replace)
        end
      end

      # Converts +bytes+ to UTF-8 one character at a time; invalid characters
      # become U+FFFD, characters +encoding+ cannot map go to +fallback+ (or
      # U+FFFD). For Shift_JIS and EUC-KR this gives exactly what String#encode
      # with invalid/undef: :replace gives on MRI, but String#encode on the
      # whole string mis-converts some of their input on TruffleRuby 25
      # (Shift_JIS even when valid, and it can return invalid UTF-8).
      def by_char(bytes, encoding, fallback = nil)
        bytes.dup.force_encoding(encoding).each_char.map do |char|
          next "\uFFFD" unless char.valid_encoding?

          char.encode(UTF_8)
        rescue Encoding::UndefinedConversionError
          fallback ? fallback.call(char) : "\uFFFD"
        end.join
      end

      # ZXing's Latin-1 vs. Shift_JIS heuristics (bytes known not to be UTF-8).
      def guess_latin1_or_shift_jis(bytes)
        can_be_latin1 = true
        can_be_sjis = true
        sjis_bytes_left = 0
        katakana_chars = 0
        katakana_run = 0
        double_byte_run = 0
        max_katakana_run = 0
        max_double_byte_run = 0
        latin1_high_other = 0
        bytes.each_byte do |v|
          if can_be_latin1
            if v > 0x7F && v < 0xA0
              can_be_latin1 = false
            elsif v > 0x9F && (v < 0xC0 || v == 0xD7 || v == 0xF7)
              latin1_high_other += 1
            end
          end
          if can_be_sjis
            if sjis_bytes_left.positive?
              if v < 0x40 || v == 0x7F || v > 0xFC
                can_be_sjis = false
              else
                sjis_bytes_left -= 1
              end
            elsif v == 0x80 || v == 0xA0 || v > 0xEF || (v < 0x20 && v != 0x0A && v != 0x0D)
              can_be_sjis = false
            elsif v > 0xA0 && v < 0xE0
              katakana_chars += 1
              double_byte_run = 0
              katakana_run += 1
              max_katakana_run = katakana_run if katakana_run > max_katakana_run
            elsif v > 0x7F
              sjis_bytes_left += 1
              katakana_run = 0
              double_byte_run += 1
              max_double_byte_run = double_byte_run if double_byte_run > max_double_byte_run
            else
              katakana_run = 0
              double_byte_run = 0
            end
          end
          break unless can_be_latin1 || can_be_sjis
        end
        can_be_sjis = false if sjis_bytes_left.positive?

        return SHIFT_JIS if can_be_sjis && (max_katakana_run >= 3 || max_double_byte_run >= 3)

        if can_be_latin1 && can_be_sjis
          return SHIFT_JIS if (max_katakana_run == 2 && katakana_chars == 2) || latin1_high_other * 10 >= bytes.bytesize

          return ISO_8859_1
        end
        return SHIFT_JIS if can_be_sjis && !can_be_latin1

        ISO_8859_1
      end
    end
  end
end
