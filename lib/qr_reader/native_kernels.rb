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
        names.each { |name| replace(name) if QrReaderKernels.respond_to?(name) }
        @reason = nil
        @active = true
      end

      private

      def replace(name)
        @pure[name] = QrReaderKernels.method(name)
        native = QrReaderNative.method(name)
        # Strings come back from the extension tagged UTF-8; kernels work on bytes.
        QrReaderKernels.define_singleton_method(name) do |*args|
          NativeKernels.binary(native.call(*args))
        end
      end

      public

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
