# frozen_string_literal: true

# Writes qr_page.jp2: a 1700 x 2200 page (gray, lossy JPEG 2000) with a QR
# code of "JPX page" near its lower right corner. Development tool only:
#
#   QR_READER_PYTHON=path/to/python bundle exec ruby test/fixtures/pdf/generate_jpx.rb
$LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__), File.expand_path("../../support", __dir__))
require "qr_test_helper"
require "tmpdir"

WIDTH = 1700
HEIGHT = 2200
code = QrTestHelper.render(QrTestHelper.rqr_matrix("JPX page"), module_size: 6)
rows = Array.new(HEIGHT) { "\xF0".b * WIDTH }
x0 = WIDTH - code.width - 150
y0 = HEIGHT - code.height - 200
code.height.times { |y| rows[y0 + y][x0, code.width] = code.row(y) }
Dir.mktmpdir do |dir|
  pgm = File.join(dir, "page.pgm")
  File.binwrite(pgm, "P5\n#{WIDTH} #{HEIGHT}\n255\n#{rows.join}")
  out = File.join(__dir__, "qr_page.jp2")
  system(ENV.fetch("QR_READER_PYTHON", "python"), "-I", File.join(__dir__, "jp2_encode.py"), pgm, out,
         exception: true)
  puts "#{out}: #{File.size(out)} bytes"
end
