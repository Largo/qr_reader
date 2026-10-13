# frozen_string_literal: true

require_relative "qr_reader/version"
require_relative "qr_reader/errors"
require_relative "qr_reader/image"
require_relative "qr_reader/bit_matrix"
require_relative "qr_reader/result"
require_relative "qr_reader/symbol_version"
require_relative "qr_reader/format_information"
require_relative "qr_reader/formats"
require_relative "qr_reader/formats/ccitt"
require_relative "qr_reader/formats/tiff"
require_relative "qr_reader/formats/pdf"
require_relative "qr_reader/decoder"
require_relative "qr_reader/detector"
require_relative "qr_reader/reader"

# Pure-Ruby QR code reader.
#
#   QrReader.decode("photo.jpg")          # => "https://example.com" or nil
#   QrReader.decode_all("scan.pdf")       # => ["first code", "second code"]
#   QrReader.read("label.png")            # => #<data QrReader::Result text=..., version=3, ...>
#   QrReader.scan("scans.tiff") { |code| puts "page #{code.page}: #{code.text}" }
#
# Every method accepts a file path (String or Pathname), an IO, encoded image
# bytes (PNG, JPEG, GIF, BMP, PNM, TIFF, PDF), a QrReader::Image, or a
# ChunkyPNG-style canvas (#width, #height, #pixels), plus these options:
#
#   try_harder: true    - fall back to slower strategies when the fast ones find nothing
#   inverted:   :auto   - also look for light-on-dark codes (true: only those, false: never)
module QrReader
  class << self
    # Text of the first QR code found, or nil.
    def decode(input, **options)
      read(input, **options)&.text
    end

    # Like #decode, but raises NotFoundError when no code can be read.
    def decode!(input, **options)
      decode(input, **options) or raise NotFoundError, "no QR code found"
    end

    # Texts of all QR codes found (on all pages), possibly empty.
    def decode_all(input, **options)
      read_all(input, **options).map(&:text)
    end

    # First QR code found as a Result (text plus metadata), or nil.
    def read(input, **options)
      Reader.new(**options).read(input)
    end

    # All QR codes found (on all pages) as Results, possibly empty.
    def read_all(input, **options)
      Reader.new(**options).read_all(input)
    end

    # Yields each QR code (a Result) as soon as it is decoded, page by page;
    # +break+ out to stop early. Returns an Enumerator when no block is given.
    def scan(input, **options, &block)
      return enum_for(:scan, input, **options) unless block

      Reader.new(**options).scan(input, &block)
      nil
    end

    # Loads an image (path, IO, encoded bytes, Image or ChunkyPNG-style canvas)
    # as a grayscale QrReader::Image; multi-page documents yield their first page.
    def load_image(input)
      Reader.load_image(input)
    end
  end
end
