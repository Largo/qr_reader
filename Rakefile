# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  t.warning = false
end

desc "Fetch the ZXing QR code blackbox images into test/corpus/zxing (Apache-2.0)"
task "corpus:fetch" do
  dest = File.expand_path("test/corpus/zxing", __dir__)
  next puts("#{dest} already present") if Dir.exist?(File.join(dest, "qrcode-1"))

  require "tmpdir"
  Dir.mktmpdir do |dir|
    sh "git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", "https://github.com/zxing/zxing.git", dir
    sets = (1..6).map { |i| "core/src/test/resources/blackbox/qrcode-#{i}" }
    sh "git", "-C", dir, "sparse-checkout", "set", *sets
    mkdir_p dest
    sets.each { |s| cp_r File.join(dir, s), dest }
  end
end

task default: :test
