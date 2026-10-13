# frozen_string_literal: true

require_relative "test_helper"

# Native kernels (qr_reader-native): when they are loaded, every entry must
# give exactly the pure-Ruby result. `rake native:compile native:test` runs
# the whole suite this way; QR_READER_NATIVE=1 makes their absence a failure.
class TestNative < Minitest::Test
  def setup
    return if QrReader.native?

    if ENV["QR_READER_NATIVE"] == "1"
      flunk "native kernels expected but not active: #{QrReader::NativeKernels.reason}"
    else
      skip "native kernels not active (#{QrReader::NativeKernels.reason})"
    end
  end

  def test_downscale_matches_pure_ruby
    rng = Random.new(5)
    [[7, 5, 2], [640, 481, 2], [97, 101, 3], [255, 129, 4]].each do |w, h, f|
      gray = rng.bytes(w * h)
      native = QrReaderKernels.downscale(gray, w, h, f)
      assert_equal Encoding::BINARY, native.encoding
      assert_equal QrReader::NativeKernels.pure(:downscale).call(gray, w, h, f), native, "#{w}x#{h}/#{f}"
    end
  end

  def test_reads_a_code_with_native_kernels
    assert_equal "MECARD:N:Google 411,;TEL:18665881077;;",
                 QrReader.decode(File.expand_path("corpus/zxing/qrcode-3/10.png", __dir__))
  end
end
