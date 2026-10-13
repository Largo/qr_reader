# frozen_string_literal: true

require_relative "lib/qr_reader/version"

Gem::Specification.new do |spec|
  spec.name = "qr_reader"
  spec.version = QrReader::VERSION
  spec.authors = ["Andi Idogawa"]
  spec.email = ["andi@idogawa.com"]

  spec.summary = "Fast, accurate QR code reader in pure Ruby."
  spec.description = "Detects and decodes QR codes in photos and scanned documents (PNG, JPEG, JPEG 2000, GIF, " \
                     "BMP, PNM, TIFF incl. CCITT fax, PDF incl. vector-drawn codes) without native extensions or " \
                     "external tools."
  spec.license = "MIT"
  spec.homepage = "https://github.com/largo/qr_reader"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt", "NOTICE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = Dir["exe/*"].map { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
end
