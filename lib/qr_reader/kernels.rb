# frozen_string_literal: true

# QrReaderKernels: the hot loops of qr_reader as plain-Ruby module functions
# over Strings, Integers and Arrays. They run as they are on any Ruby; the
# optional qr_reader-native gem compiles the same files with Spinel and
# swaps in the native versions (see DESIGN.md, "Kernels").
require_relative "kernels/image"
require_relative "kernels/pixels"
require_relative "kernels/png"
require_relative "kernels/jpeg"
require_relative "kernels/ccitt"
require_relative "kernels/lzw"
require_relative "kernels/binarizer"
require_relative "kernels/detector"
