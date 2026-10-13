# frozen_string_literal: true

# QrReaderKernels: the hot loops of qr_reader as plain-Ruby module functions
# over Strings, Integers and Arrays. They run as they are on any Ruby; the
# optional qr_reader-native gem compiles the same files with Spinel and
# swaps in the native versions (see DESIGN.md, "Kernels").
require_relative "kernels/image"
