# frozen_string_literal: true

# STUB - owned by the "jpeg" agent (see DESIGN.md).
module QrReader
  module Formats
    module JPEG
      def self.decode(_bytes, scale: 1)
        raise UnsupportedImageError, "JPEG support not implemented yet"
      end

      def self.dimensions(_bytes)
        raise UnsupportedImageError, "JPEG support not implemented yet"
      end
    end
  end
end
