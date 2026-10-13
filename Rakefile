# frozen_string_literal: true

require "bundler/gem_tasks"
require_relative "lib/qr_reader/version"
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

namespace :native do
  ext_dir = File.expand_path("native/ext/qr_reader_native", __dir__)
  lib_dir = File.expand_path("native/lib/qr_reader_native", __dir__)

  desc "Regenerate native/ext from lib/qr_reader/kernels with Spinel (needs SPINEL_HOME)"
  task :generate do
    ruby "script/native_generate.rb"
  end

  desc "Compile the qr_reader-native extension in place (for tests and benchmarks)"
  task :compile do
    Dir.chdir(ext_dir) do
      ruby "extconf.rb"
      sh "make", "-j#{ENV.fetch('MAKE_JOBS', '2')}"
    end
    mkdir_p lib_dir
    cp Dir[File.join(ext_dir, "qr_reader_native.{so,bundle,dll}")], lib_dir
  end

  desc "Run the test suite with the native kernels (after native:compile)"
  task :test do
    ENV["RUBYLIB"] = [File.expand_path("native/lib", __dir__), ENV.fetch("RUBYLIB", nil)].compact.join(File::PATH_SEPARATOR)
    ENV["QR_READER_NATIVE"] = "1"
    Rake::Task[:test].invoke
  end

  desc "Build the qr_reader-native gem into pkg/"
  task :gem do
    mkdir_p "pkg"
    Dir.chdir("native") { sh "gem", "build", "qr_reader-native.gemspec", "--output", "../pkg/qr_reader-native-#{QrReader::VERSION}.gem" }
  end
end

namespace :scans do
  desc "Generate the scanned-document QR corpus into test/corpus/scans (needs ImageMagick 7 and qpdf)"
  task :generate do
    require "etc"
    ruby "bench/scans/generate.rb", "--jobs", ENV.fetch("JOBS", [Etc.nprocessors / 2, 1].max.to_s)
  end

  desc "Read the scanned-document corpus and compare with the zxing-cpp baseline"
  task :run do
    ruby "--yjit", "bench/scans/run.rb", "--baseline"
  end
end

task default: :test
