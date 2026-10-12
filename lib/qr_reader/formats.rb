# frozen_string_literal: true

# STUB - owned by the "formats" agent (see DESIGN.md).
module QrReader
  module Formats
    def self.decode(_bytes, scale: 1)
      raise NotImplementedError, "QrReader::Formats.decode not implemented yet"
    end
  end
end
