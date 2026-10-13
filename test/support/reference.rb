# frozen_string_literal: true

require "json"
require "open3"

# Runs the zxing-cpp reference decoder (bench/reference/zxcpp.py) through the
# development Python venv. Development and benchmarking only.
#
#   QrReference.available?                                   # => true/false
#   QrReference.decode(["a.png", "b.png"], text_mode: "Plain")
#   # => [{"image" => "a.png", "ms" => 1.2, "results" => [{"text" => ...}]}, ...]
module QrReference
  class Error < StandardError; end

  # Venv with zxing-cpp and Pillow (see DESIGN.md); override with QR_READER_PYTHON.
  DEFAULT_PYTHON = "/tmp/claude-1000/-home-andi-workspace/024a2597-ef40-4f4c-a25b-3210b1b14972/scratchpad/venv/bin/python"
  SCRIPT = File.expand_path("../../bench/reference/zxcpp.py", __dir__)
  WRITER_SCRIPT = File.expand_path("../../bench/reference/zxcpp_write.py", __dir__)

  module_function

  def python
    ENV.fetch("QR_READER_PYTHON", DEFAULT_PYTHON)
  end

  def available?
    return @available unless @available.nil?

    @available = File.executable?(python) && File.exist?(SCRIPT) &&
                 system(python, "-I", "-c", "import zxingcpp, PIL", out: File::NULL, err: File::NULL)
  end

  # zxing-cpp version string, e.g. "zxing-cpp 3.1.1".
  def version
    out, status = Open3.capture2(python, "-I", "-c", "import importlib.metadata as m; print(m.version('zxing-cpp'))")
    status.success? ? "zxing-cpp #{out.strip}" : "zxing-cpp"
  end

  # Decodes image files in one Python process. Returns one Hash per path, in
  # order. +rotate_cw+ (0/90/180/270) rotates exactly like QrReader::Image#rotate.
  def decode(paths, rotate_cw: 0, text_mode: "HRI", pure: false)
    return [] if paths.empty?
    raise Error, "zxing-cpp reference venv not available (#{python})" unless available?

    # A path starting with "-" would be taken for an option.
    paths = paths.map { |path| path.to_s.start_with?("-") ? File.join(".", path.to_s) : path.to_s }

    args = [python, "-I", SCRIPT, "--rotate-cw", rotate_cw.to_s, "--text-mode", text_mode]
    args << "--pure" if pure
    out, err, status = Open3.capture3(*args, *paths)
    raise Error, "zxcpp.py failed: #{err}" unless status.success?

    lines(out, paths.size, "zxcpp.py")
  end

  # Encodes texts with zxing-cpp's writer (zint), an encoder independent of
  # both QrTestEncoder and rqrcode_core. +requests+: [[text, level], ...].
  # Returns, in order, the module rows ("0101...", 1 = dark) or nil when the
  # writer rejected that request.
  def encode(requests)
    return [] if requests.empty?
    raise Error, "zxing-cpp reference venv not available (#{python})" unless available?

    input = requests.map { |text, level| JSON.generate({ "text" => text, "ec_level" => level.to_s.upcase }) }.join("\n")
    out, err, status = Open3.capture3(python, "-I", WRITER_SCRIPT, stdin_data: "#{input}\n")
    raise Error, "zxcpp_write.py failed: #{err}" unless status.success?

    lines(out, requests.size, "zxcpp_write.py").map { |row| row["rows"] }
  end

  # One parsed JSON line per input; anything else means the script broke
  # (results must never be silently paired with the wrong input).
  def lines(out, count, script)
    parsed = out.each_line.map { |line| JSON.parse(line) }
    raise Error, "#{script} returned #{parsed.size} results for #{count} inputs" unless parsed.size == count

    parsed
  rescue JSON::ParserError => e
    raise Error, "#{script} printed invalid JSON: #{e.message}"
  end

  private_class_method :lines
end
