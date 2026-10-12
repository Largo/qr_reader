# frozen_string_literal: true

require_relative "lib/qr_reader/version"

Gem::Specification.new do |spec|
  spec.name = "qr_reader"
  spec.version = QrReader::VERSION
  spec.authors = ["Andi Idogawa"]
  spec.email = ["andi@idogawa.com"]

  spec.summary = "Fast, accurate QR code reader in pure Ruby."
  spec.description = "Detects and decodes QR codes in PNG, JPEG, GIF, BMP and PNM images " \
                     "(or raw pixel buffers) without native extensions or external tools."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = Dir["exe/*"].map { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
