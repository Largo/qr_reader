# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("support", __dir__)

require "minitest/autorun"
require "stringio"
require "qr_reader"
require "qr_test_helper"
