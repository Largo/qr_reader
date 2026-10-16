# frozen_string_literal: true

module QrReader
  class Error < StandardError; end

  # The input could not be turned into an image (unknown or corrupt format).
  class ImageError < Error; end

  # The image format was recognised but is not supported (e.g. arithmetic-coded JPEG).
  class UnsupportedImageError < ImageError; end

  # Raised by QrReader.decode! when no QR code could be read.
  class NotFoundError < Error; end
end
