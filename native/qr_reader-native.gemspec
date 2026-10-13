# frozen_string_literal: true

require_relative "../lib/qr_reader/version"

Gem::Specification.new do |spec|
  spec.name = "qr_reader-native"
  spec.version = QrReader::VERSION
  spec.authors = ["Andi Idogawa"]
  spec.email = ["andi@idogawa.com"]

  spec.summary = "Optional native speed-up for qr_reader (its Ruby kernels compiled by Spinel)."
  spec.description = "The hot loops of the pure-Ruby qr_reader gem, compiled to C with the Spinel Ruby AOT " \
                     "compiler. qr_reader uses them automatically when this gem is installed; without it, " \
                     "qr_reader runs the same code as plain Ruby."
  spec.license = "MIT"
  spec.homepage = "https://github.com/largo/qr_reader"
  spec.required_ruby_version = ">= 3.2"

  # lib/qr_reader_native/kernel.rb is the Spinel input (generation only), not shipped.
  spec.files = Dir["lib/qr_reader/**/*.rb", "ext/**/*.{c,h,inc,rb}", "ext/**/SPINEL_VERSION", "README.md", "LICENSE*"]
  spec.extensions = ["ext/qr_reader_native/extconf.rb"]
  spec.require_paths = ["lib"]
  spec.add_dependency "qr_reader", QrReader::VERSION

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
end
