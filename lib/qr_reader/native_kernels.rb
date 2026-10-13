# frozen_string_literal: true

module QrReader
  # Optional native kernels from the qr_reader-native gem.
  #
  # qr_reader-native contains the files under lib/qr_reader/kernels compiled
  # to C by Spinel. When it is installed (and QR_READER_NATIVE is not "0"),
  # its entry points replace the pure-Ruby QrReaderKernels methods - but only
  # if it was built from exactly the kernel sources of this qr_reader version
  # (compared by digest). Otherwise everything keeps running as pure Ruby.
  module NativeKernels
    # Which native entries are used (measured with tmp/kernel_bench-style
    # comparisons on real inputs; entries not listed stay pure Ruby):
    # faster in every mode,
    ALWAYS = %i[binarize_hybrid binarize_local_mean finder_scan ccitt_decode lzw_decode downscale
                jpeg_render jpeg_info].freeze
    # only faster than Ruby without YJIT (on par or slower with it),
    WITHOUT_YJIT = %i[png_rows png_adam7 png_unpack_rows pixels_luma].freeze
    # not used: JPEG entropy decoding compiled by the current Spinel slows
    # down superlinearly with image size (native/README.md).
    NEVER = %i[jpeg_luma jpeg_luma_keep].freeze

    @active = false
    @pure = {}

    class << self
      # True when native kernels are in use.
      def active?
        @active
      end

      # Why native kernels are not in use (nil when they are).
      attr_reader :reason

      # The original pure-Ruby kernel methods, by name (for comparisons).
      def pure(name)
        @pure.fetch(name.to_sym) { QrReaderKernels.method(name) }
      end

      # Loads and installs the native kernels if available; returns active?.
      def install
        return @active if @active

        if ENV["QR_READER_NATIVE"] == "0"
          @reason = "disabled by QR_READER_NATIVE=0"
          return false
        end
        begin
          require "qr_reader_native/qr_reader_native"
        rescue LoadError => e
          @reason = "qr_reader-native is not installed (#{e.message})"
          return false
        end

        expected = digest(QrReaderNative.kernel_files)
        if expected != QrReaderNative.kernels_digest
          @reason = "qr_reader-native #{QrReaderNative.kernels_digest[0, 12]} was built from other kernel " \
                    "sources than qr_reader #{VERSION} (#{expected[0, 12] if expected}); using pure Ruby"
          warn "qr_reader: #{@reason}" if $VERBOSE || ENV["QR_READER_NATIVE"] == "1"
          return false
        end

        names = QrReaderNative.singleton_methods(false) - %i[kernels_digest kernel_files]
        names.each do |name|
          next unless QrReaderKernels.respond_to?(name)

          if ALWAYS.include?(name) then replace(name)
          elsif WITHOUT_YJIT.include?(name) then replace(name, unless_yjit: true)
          end
        end
        @reason = nil
        @active = true
      end

      private

      def replace(name, unless_yjit: false)
        pure = @pure[name] = QrReaderKernels.method(name)
        native = QrReaderNative.method(name)
        # Strings come back from the extension tagged UTF-8; kernels work on bytes.
        if unless_yjit
          QrReaderKernels.define_singleton_method(name) do |*args|
            # YJIT may be enabled after loading (e.g. by Rails), so check per call.
            NativeKernels.yjit? ? pure.call(*args) : NativeKernels.binary(native.call(*args))
          end
        else
          QrReaderKernels.define_singleton_method(name) do |*args|
            NativeKernels.binary(native.call(*args))
          end
        end
      end

      public

      def yjit?
        defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? true : false
      end

      # Result of a native entry with Strings re-tagged as binary (internal).
      def binary(value)
        case value
        when String then value.force_encoding(Encoding::BINARY)
        when Array then value.each { |v| v.force_encoding(Encoding::BINARY) if v.is_a?(String) }
        else value
        end
      end

      private

      # SHA-256 over the given files (paths relative to lib/), nil if one is missing.
      def digest(files)
        require "digest"
        lib = File.expand_path("..", __dir__)
        sha = Digest::SHA256.new
        files.each do |rel|
          path = File.join(lib, rel)
          return nil unless File.file?(path)

          sha << rel << "\0" << File.binread(path) << "\0"
        end
        sha.hexdigest
      end
    end
  end

  # True when the native kernels of the qr_reader-native gem are in use.
  def self.native?
    NativeKernels.active?
  end
end
