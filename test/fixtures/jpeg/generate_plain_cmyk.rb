# frozen_string_literal: true

# Writes NAME.plain.SCALE.gray.z: the luminance libjpeg (via Pillow) gives for
# the 4-component fixtures read with plain ink values (JPEG.decode cmyk: :plain).
# Development tool only:
#
#   QR_READER_PYTHON=path/to/python ruby test/fixtures/jpeg/generate_plain_cmyk.rb
require "open3"
require "zlib"

DIR = __dir__
NAMES = %w[cmyk ycck ycck_progressive adv_ycck_420].freeze
python = ENV.fetch("QR_READER_PYTHON", "python")

NAMES.each do |name|
  [1, 2].each do |scale|
    out = File.join(DIR, "#{name}.plain.#{scale}.gray")
    info, status = Open3.capture2(python, "-I", File.join(DIR, "reference.py"), File.join(DIR, "#{name}.jpg"),
                                  scale.to_s, out, "plain")
    abort "reference.py failed for #{name}" unless status.success?
    File.binwrite("#{out}.z", Zlib::Deflate.deflate(File.binread(out), 9))
    File.delete(out)
    puts "#{name} 1/#{scale}: #{info.strip}"
  end
end
