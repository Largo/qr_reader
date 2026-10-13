# frozen_string_literal: true

require_relative "../kernels/ccitt"

module QrReader
  module Formats
    # CCITT fax decoder: Group 3 (ITU-T T.4: 1-D Modified Huffman and 2-D
    # Modified READ) and Group 4 (T.6, MMR), the bilevel codings that scanners
    # and fax machines write into TIFF files (compression 2, 3 and 4) and PDFs
    # embed as CCITTFaxDecode streams.
    #
    #   CCITT.decode(g4_data, columns: 2480, rows: 3508)     # => #<QrReader::Image 2480x3508>
    #   CCITT.decode(g3_data, columns: 1728, k: 0)           # rows until RTC / end of data
    #
    # Parameters follow PDF's CCITTFaxDecode filter:
    # * +k+ < 0: Group 4; 0: Group 3 1-D; > 0: Group 3 2-D (each row's tag
    #   bit selects 1-D or 2-D coding).
    # * +rows+ nil or 0: decode until EOFB / RTC or the end of the data.
    #   Missing rows (truncated data) are white.
    # * +black_is_1+ false: coded white is 255 and coded black 0 (what a PDF
    #   shows with the default Decode array); true inverts the image (also
    #   what TIFF's BlackIsZero photometric means for fax data).
    # * +encoded_byte_align+: every row starts on a byte boundary (TIFF
    #   compression 2 rows, PDF EncodedByteAlign).
    # * +fill_order+ 2: bits are stored least significant first (TIFF FillOrder).
    # * +end_of_line+: EOL codes precede the rows. EOLs, fill bits before
    #   them and EOFB/RTC are recognised either way, so the flag only
    #   decides whether an unaligned EOL may stand before a byte-aligned row.
    # * +end_of_block+ and +damaged_rows_before_error+ are accepted for PDF
    #   compatibility. Decoding is always lenient: rows stop at EOFB/RTC or
    #   after +rows+ rows, and damaged rows never raise.
    #
    # Damaged rows of EOL-delimited (Group 3) data are replaced by the row
    # above and decoding resumes at the next EOL. Group 4 cannot
    # resynchronise, so an error ends the image there (the rest stays
    # white). Only data in which not even the first row decodes raises
    # ImageError. Uncompressed-mode extensions count as damage.
    #
    # The decoding itself is the kernel QrReaderKernels.ccitt_decode.
    module CCITT
      # Byte -> byte with its bits reversed (FillOrder 2), as String#tr tables.
      REVERSE_FROM = Image::TR_ESCAPE.call((0..255).to_a)
      REVERSE_TO = Image::TR_ESCAPE.call((0..255).map { |b| format("%08b", b).reverse.to_i(2) })

      class << self
        # Decodes a CCITT stream to an Image (see the module documentation
        # for the parameters). end_of_block and damaged_rows_before_error
        # are accepted for PDF compatibility; decoding is always lenient.
        # rubocop:disable Lint/UnusedMethodArgument
        def decode(data, columns:, rows: nil, k: -1, black_is_1: false, encoded_byte_align: false, fill_order: 1,
                   end_of_line: false, end_of_block: true, damaged_rows_before_error: 0)
          raise ImageError, "CCITT data must be a String" unless data.is_a?(String)

          rows = nil if rows.is_a?(Integer) && rows.zero?
          check_size(columns, rows)
          data = data.b unless data.encoding == Encoding::BINARY
          data = data.tr(REVERSE_FROM, REVERSE_TO) if fill_order == 2
          k = -1 unless k.is_a?(Integer)
          pixels = QrReaderKernels.ccitt_decode(data, columns, rows || 0, k.clamp(-1, 1), encoded_byte_align ? true : false,
                                                end_of_line ? true : false, black_is_1 ? true : false,
                                                MAX_PIXELS / columns)
          Image.new(columns, pixels.bytesize / columns, pixels)
        end
        # rubocop:enable Lint/UnusedMethodArgument

        private

        def check_size(columns, rows)
          unless columns.is_a?(Integer) && columns.positive? && (rows.nil? || (rows.is_a?(Integer) && rows.positive?))
            raise ImageError, "invalid CCITT dimensions #{columns.inspect}x#{rows.inspect}"
          end
          return if columns * (rows || 1) <= MAX_PIXELS

          raise UnsupportedImageError, "CCITT image too large (#{columns}x#{rows}, limit #{MAX_PIXELS} pixels)"
        end
      end

      private_constant :REVERSE_FROM, :REVERSE_TO
    end
  end
end
