# frozen_string_literal: true

module QrReader
  # Structured Append header (ISO/IEC 18004 §8.3.12): this symbol is
  # +index+ (0-based) of +count+ symbols; +parity+ is the XOR of all data bytes.
  StructuredAppend = Data.define(:index, :count, :parity)

  # One decoded data segment. +mode+ is :numeric, :alphanumeric, :byte,
  # :kanji or :hanzi; +text+ is the decoded UTF-8 string; +eci+ the ECI
  # designator in effect (nil if none).
  Segment = Data.define(:mode, :text, :eci)

  # A decoded QR code.
  #
  # text                 - decoded content as a UTF-8 String
  # raw_bytes            - raw payload bytes (binary String) before character set decoding
  # version              - symbol version, 1..40
  # ec_level             - error correction level: :l, :m, :q or :h (as in rqrcode)
  # mask                 - data mask pattern, 0..7
  # points               - [[x, y], ...] corners in image pixel coordinates:
  #                        top-left, top-right, bottom-right, bottom-left (nil if unknown)
  # mirrored             - true if the symbol was read mirrored
  # errors_corrected     - number of codewords repaired by Reed-Solomon
  # eci                  - first ECI designator found, or nil
  # fnc1                 - nil, :first or [:second, application_indicator]
  # structured_append    - StructuredAppend or nil
  # symbology_identifier - AIM identifier, e.g. "]Q1"
  # segments             - Array of Segment
  # page                 - 0-based page/image index for multi-page inputs (TIFF, PDF), else nil
  Result = Data.define(:text, :raw_bytes, :version, :ec_level, :mask, :points, :mirrored,
                       :errors_corrected, :eci, :fnc1, :structured_append,
                       :symbology_identifier, :segments, :page) do
    def initialize(text:, raw_bytes:, version:, ec_level:, mask:, points: nil, mirrored: false,
                   errors_corrected: 0, eci: nil, fnc1: nil, structured_append: nil,
                   symbology_identifier: "]Q1", segments: [], page: nil)
      super
    end

    alias_method :to_s, :text

    def mirrored?
      mirrored
    end

    def structured_append?
      !structured_append.nil?
    end
  end
end
