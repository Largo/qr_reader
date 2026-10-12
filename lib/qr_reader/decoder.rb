# frozen_string_literal: true

# STUB - owned by the "decoder" agent (see DESIGN.md).
module QrReader
  module Decoder
    def self.decode(_bit_matrix, try_mirrored: true)
      raise NotImplementedError, "QrReader::Decoder.decode not implemented yet"
    end
  end
end
