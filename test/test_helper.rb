# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ruby_lsp/internal"
require "ruby_lsp_slim"
require "ruby_lsp/ruby_lsp_slim/slim_document"
require "ruby_lsp/ruby_lsp_slim/addon"
require "minitest/autorun"

module TestHelper
  def fixture_path(name)
    File.join(File.dirname(__FILE__), "fixtures", name)
  end

  def read_fixture(name)
    File.read(fixture_path(name))
  end
end
