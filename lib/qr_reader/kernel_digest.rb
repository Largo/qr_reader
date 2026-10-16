# frozen_string_literal: true

module QrReader
  # Fingerprint of the kernel sources that qr_reader-native was compiled from
  # (stored in the native gem by script/native_generate.rb, compared by
  # NativeKernels at load time).
  #
  # It hashes the Ruby tokens rather than the file bytes, so comments, blank
  # lines and spacing can change without switching the native kernels off;
  # any change to the code itself still does. "# spinel-sample:" comments
  # count as code: they give Spinel the argument types.
  module KernelDigest
    # Tokens that carry no code: spacing, comments, =begin/=end blocks.
    SKIPPED = %i[on_sp on_ignored_sp on_comment on_embdoc_beg on_embdoc on_embdoc_end].freeze
    # A newline, whether Ruby treats it as a statement end or not.
    LINE_BREAKS = %i[on_nl on_ignored_nl].freeze
    SPINEL_COMMENT = /\A#\s*spinel-/
    LINE_BREAK = "\n"

    module_function

    # SHA-256 over +files+ (paths relative to +lib+), nil if one is missing.
    def digest(files, lib)
      require "digest"
      sha = Digest::SHA256.new
      files.each do |rel|
        path = File.join(lib, rel)
        return nil unless File.file?(path)

        sha << rel << "\0"
        tokens(File.read(path, encoding: Encoding::UTF_8)).each { |token| sha << token << "\0" }
      end
      sha.hexdigest
    end

    # The code tokens of +source+ as "type\0text" Strings. Every run of line
    # breaks (newlines, blank lines, comments, which end in the newline they
    # take from Ripper) becomes one LINE_BREAK, so a trailing comment or an
    # extra blank line does not change the result but joining two
    # statements into one line does.
    def tokens(source)
      require "ripper"
      out = []
      Ripper.lex(source).each do |_position, type, text, _state|
        if type == :on_comment && text.match?(SPINEL_COMMENT)
          out << "spinel\0#{text.strip}"
          line_break(out)
        elsif LINE_BREAKS.include?(type) || (SKIPPED.include?(type) && text.end_with?("\n"))
          line_break(out)
        elsif !SKIPPED.include?(type)
          out << "#{type}\0#{text}"
        end
      end
      out.pop if out.last == LINE_BREAK
      out
    end

    def line_break(out)
      out << LINE_BREAK unless out.empty? || out.last == LINE_BREAK
    end
  end
end
