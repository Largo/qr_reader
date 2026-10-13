# frozen_string_literal: true

# Enumerates the ZXing blackbox QR corpus (test/corpus/zxing/qrcode-N/*.png,
# each with the expected content in a matching .txt file, UTF-8).
#
#   QrCorpus.available?                     # => true once `rake corpus:fetch` ran
#   QrCorpus.cases(only: "qrcode-3")        # => [#<data QrCorpus::Case ...>, ...]
#   QrCorpus.cases.each { |c| c.id; c.path; c.expected }
module QrCorpus
  ROOT = File.expand_path("../corpus/zxing", __dir__)
  IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .gif .bmp .pgm .ppm .pbm .pnm].freeze

  # One corpus image. +dir+ is e.g. "qrcode-1", +name+ the image file name,
  # +expected+ the expected text (UTF-8, compared verbatim like ZXing does).
  Case = Data.define(:dir, :name, :path, :expected) do
    # Stable identifier, e.g. "qrcode-1/12.png".
    def id
      "#{dir}/#{name}"
    end

    # Expected properties from the optional N.metadata.txt (KEY=VALUE lines),
    # e.g. {"SYMBOLOGY_IDENTIFIER" => "]Q1"}.
    def metadata
      file = path.sub(/\.[^.]+\z/, ".metadata.txt")
      return {} unless File.exist?(file)

      File.readlines(file, chomp: true).filter_map { |line| line.split("=", 2) if line.include?("=") }.to_h
    end
  end

  module_function

  def available?
    !directories.empty?
  end

  # Corpus sub-directories in natural order ("qrcode-1", "qrcode-2", ...).
  def directories(root: ROOT)
    Dir.children(root).select { |d| File.directory?(File.join(root, d)) && d.start_with?("qrcode-") }
       .sort_by { |d| natural_key(d) }
  rescue Errno::ENOENT
    []
  end

  # All cases with an expected .txt, in natural order. +only+ restricts the
  # selection: a String or an Array of directory names ("qrcode-3" or just
  # "3"), single images ("qrcode-3/12.png" or "qrcode-3/12") or globs.
  def cases(only: nil, root: ROOT)
    filters = Array(only).flat_map { |f| f.to_s.split(",") }.map(&:strip).reject(&:empty?)
    directories(root: root).flat_map do |dir|
      Dir.children(File.join(root, dir))
         .select { |f| IMAGE_EXTENSIONS.include?(File.extname(f).downcase) }
         .sort_by { |f| natural_key(f) }
         .filter_map do |name|
           path = File.join(root, dir, name)
           txt = path.sub(/\.[^.]+\z/, ".txt")
           next unless File.exist?(txt)
           next unless filters.empty? || filters.any? { |f| match?(f, dir, name) }

           Case.new(dir: dir, name: name, path: path, expected: File.binread(txt).force_encoding(Encoding::UTF_8).freeze)
         end
    end
  end

  def match?(filter, dir, name)
    filter = "qrcode-#{filter}" if filter.match?(/\A\d+\z/)
    id = "#{dir}/#{name}"
    return true if filter == dir || filter == id || filter == id.sub(/\.[^.]+\z/, "")

    File.fnmatch?(filter, id) || File.fnmatch?(filter, dir)
  end

  # Sort key that orders embedded numbers numerically ("2.png" < "10.png").
  def natural_key(string)
    string.scan(/\d+|\D+/).map { |part| part.match?(/\A\d/) ? [0, part.to_i] : [1, part] }
  end
end
