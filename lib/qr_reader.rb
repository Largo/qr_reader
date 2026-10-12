# frozen_string_literal: true

require_relative "qr_reader/version"
require_relative "qr_reader/errors"
require_relative "qr_reader/image"
require_relative "qr_reader/bit_matrix"
require_relative "qr_reader/result"
require_relative "qr_reader/symbol_version"
require_relative "qr_reader/format_information"
require_relative "qr_reader/formats"
require_relative "qr_reader/decoder"
require_relative "qr_reader/detector"

# Pure-Ruby QR code reader.
#
#   QrReader.decode("photo.jpg")        # => "https://example.com" or nil
#   QrReader.decode_all(png_bytes)      # => [#<data QrReader::Result text=...>, ...]
module QrReader
  class << self
    # Text of the first QR code found, or nil.
    def decode(input, **options)
      read(input, **options)&.text
    end

    # Like decode, but raises NotFoundError when nothing is found.
    def decode!(input, **options)
      decode(input, **options) or raise NotFoundError, "no QR code found"
    end

    # First Result found, or nil.
    def read(input, **options)
      raise NotImplementedError, "QrReader.read not implemented yet (integration pending)"
    end

    # All QR codes in the image as an Array of Result (possibly empty).
    def decode_all(input, **options)
      raise NotImplementedError, "QrReader.decode_all not implemented yet (integration pending)"
    end
  end
end
