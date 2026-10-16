# frozen_string_literal: true

require_relative "test_helper"
require "qr_reader/kernel_digest"
require "tmpdir"

# QrReader::KernelDigest: comments and layout do not count, code does.
class TestKernelDigest < Minitest::Test
  BASE = <<~RUBY
    # frozen_string_literal: true

    module QrReaderKernels
      # Sums the bytes.
      # spinel-sample: QrReaderKernels.sum("ab")
      def self.sum(data)
        total = 0
        data.each_byte { |b| total += b }
        total
      end
    end
  RUBY

  def tokens(source) = QrReader::KernelDigest.tokens(source)

  def test_comments_and_layout_do_not_count
    same = [
      BASE.sub("# Sums the bytes.", "# Adds up every byte of +data+."),
      BASE.sub("    total = 0\n", "    total = 0 # running sum\n"),
      BASE.sub("    total\n", "\n\n    total\n"),
      BASE.sub("total += b", "total  +=  b"),
      BASE.sub("module QrReaderKernels\n", "module QrReaderKernels\n=begin\nnotes\n=end\n"),
      "#{BASE}\n# trailing comment\n",
    ]
    same.each do |variant|
      refute_equal BASE, variant
      assert_equal tokens(BASE), tokens(variant), variant
    end
  end

  def test_code_and_spinel_samples_count
    different = [
      BASE.sub("total = 0", "total = 1"),
      BASE.sub("each_byte", "each_char"),
      BASE.sub(%(sum("ab")), %(sum("abc"))),
      BASE.sub("    total\n", "    total; total\n"),
      "foo\nbar\n" => "foo bar\n",
    ]
    different.each do |variant|
      a, b = variant.is_a?(Hash) ? variant.first : [BASE, variant]
      refute_equal a, b
      refute_equal tokens(a), tokens(b), b
    end
  end

  def test_digest_of_files
    Dir.mktmpdir do |lib|
      File.write(File.join(lib, "a.rb"), BASE)
      digest = QrReader::KernelDigest.digest(["a.rb"], lib)
      assert_match(/\A\h{64}\z/, digest)
      File.write(File.join(lib, "a.rb"), BASE.sub("# Sums the bytes.", "# Changed comment."))
      assert_equal digest, QrReader::KernelDigest.digest(["a.rb"], lib)
      File.write(File.join(lib, "a.rb"), BASE.sub("total = 0", "total = 2"))
      refute_equal digest, QrReader::KernelDigest.digest(["a.rb"], lib)
      assert_nil QrReader::KernelDigest.digest(["a.rb", "missing.rb"], lib)
    end
  end
end
