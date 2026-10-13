# frozen_string_literal: true

# Development-only fixture generator: zxing_cpp_damaged.jsonl.
#
# Builds damaged symbols with the test-side SymbolBuilder (not the library):
# corrupted codewords (up to one more than the correction capacity in up to
# three blocks), bit errors in the format and version information copies,
# some mirrored. Each one is rendered to PNG and read by zxing-cpp
# (bench/reference/zxcpp.py --pure); the fixture records the exact
# modifications, a CRC of the resulting grid and zxing-cpp's text (null if
# it could not read the symbol). test_decoder_adversarial.rb rebuilds the
# grids and checks that we read everything zxing-cpp reads, identically.
#
#   bundle exec ruby -Itest test/decoder/fixtures/generate_zxing_cpp_damaged.rb [COUNT]
#
# ZXCPP_PYTHON overrides the Python interpreter (a venv with zxing-cpp and Pillow).

require "json"
require "tmpdir"
require "zlib"
require_relative "../decoder_test_helper"

module ZxingCppDamaged
  ROOT = File.expand_path("../../..", __dir__)
  OUTPUT = File.join(__dir__, "zxing_cpp_damaged.jsonl")
  PYTHON = ENV.fetch("ZXCPP_PYTHON",
                     "/tmp/claude-1000/-home-andi-workspace/024a2597-ef40-4f4c-a25b-3210b1b14972/scratchpad/venv/bin/python")
  VERSIONS = [1, 2, 3, 5, 7, 8, 10, 14, 20].freeze

  module_function

  # Raw (interleaved) codeword indices of each RS block, straight from the
  # ISO block table.
  def block_indices(version, level)
    blocks = QrReader::SymbolVersion[version].ec_blocks(level)
    counts = blocks.data_codewords_per_block
    indices = counts.map { [] }
    raw = 0
    counts.max.times do |i|
      counts.each_with_index do |count, b|
        next if i >= count

        indices[b] << raw
        raw += 1
      end
    end
    blocks.ec_codewords_per_block.times { indices.each { |list| (list << raw) && raw += 1 } }
    indices
  end

  def format_coords(n)
    [[[0, 8], [1, 8], [2, 8], [3, 8], [4, 8], [5, 8], [7, 8], [8, 8], [8, 7], [8, 5], [8, 4], [8, 3], [8, 2], [8, 1],
      [8, 0]],
     (0..6).map { |k| [8, n - 1 - k] } + (0..7).map { |k| [n - 8 + k, 8] }]
  end

  def version_coords(n)
    [(0...18).map { |i| [n - 11 + i % 3, i / 3] }, (0...18).map { |i| [i / 3, n - 11 + i % 3] }]
  end

  # A random damaged symbol description (see #build).
  def random_case(rng, i)
    version = VERSIONS[rng.rand(VERSIONS.size)]
    level = DecoderTestHelper::LEVELS[rng.rand(4)]
    mode = %i[alphanumeric number byte_8bit][rng.rand(3)]
    max = [DecoderTestHelper.capacity(version, level, mode), 60].min
    text = DecoderTestHelper.payload(rng, mode, rng.rand(1..max))
    t = QrReader::SymbolVersion[version].ec_blocks(level).ec_codewords_per_block / 2
    n = 17 + 4 * version
    kind = i % 4
    codewords = []
    if kind.zero? || kind == 3
      # t - 1 .. t + 1 errors in up to three blocks (flat [index, xor, ...])
      block_indices(version, level).shuffle(random: rng).first(3).each do |indices|
        count = [t, t, t - 1, t + 1][rng.rand(4)].clamp(0, indices.size)
        indices.sample(count, random: rng).each { |j| codewords.push(j, rng.rand(1..255)) }
      end
    end
    flips = [] # flat [x, y, ...] of format and version information modules
    if kind == 1 || kind == 3
      format_coords(n).each { |coords| flips.concat(coords.sample(rng.rand(0..6), random: rng).flatten) }
    end
    if (kind == 2 || kind == 3) && version >= 7
      version_coords(n).each { |coords| flips.concat(coords.sample(rng.rand(0..6), random: rng).flatten) }
    end
    { "version" => version, "level" => level.to_s, "mask" => rng.rand(8), "mode" => mode.to_s, "text" => text,
      "codewords" => codewords, "flips" => flips, "mirrored" => rng.rand(3).zero? }
  end

  # The BitMatrix described by +spec+ (a fixture entry).
  def build(spec)
    version = spec["version"]
    level = spec["level"].to_sym
    writer = DecoderTestHelper::BitWriter.new
    case spec["mode"]
    when "number" then writer.numeric(spec["text"], version)
    when "alphanumeric" then writer.alphanumeric(spec["text"], version)
    else writer.bytes(spec["text"], version)
    end
    data = writer.to_data(QrReader::SymbolVersion[version].data_codewords(level))
    corrupt = ->(codewords) { spec["codewords"].each_slice(2) { |j, value| codewords[j] ^= value } }
    matrix = DecoderTestHelper::SymbolBuilder.build(data, version: version, level: level, mask: spec["mask"],
                                                          corrupt: corrupt)
    spec["flips"].each_slice(2) { |x, y| matrix.flip(x, y) }
    spec["mirrored"] ? matrix.transpose : matrix
  end

  def run(count)
    rng = Random.new(2024)
    specs = Array.new(count) { |i| random_case(rng, i) }
    Dir.mktmpdir do |dir|
      paths = specs.each_with_index.map do |spec, i|
        path = File.join(dir, "#{i}.png")
        QrTestHelper.write_png(QrTestHelper.render(build(spec), module_size: 3), path)
        path
      end
      script = File.join(ROOT, "bench/reference/zxcpp.py")
      lines = IO.popen([PYTHON, "-I", script, "--pure", "--text-mode", "Plain", *paths], &:read).lines
      abort "zxing-cpp returned #{lines.size} lines for #{paths.size} images" unless lines.size == paths.size
      File.open(OUTPUT, "w") do |out|
        specs.each_with_index do |spec, i|
          text = JSON.parse(lines[i])["results"].first&.fetch("text")
          spec["zxing_cpp"] = text.nil? || text.empty? ? nil : text
          spec["crc"] = Zlib.crc32(build(spec).bits)
          out.puts JSON.generate(spec)
        end
      end
    end
  end
end

ZxingCppDamaged.run(Integer(ARGV[0] || 400)) if $PROGRAM_NAME == __FILE__
