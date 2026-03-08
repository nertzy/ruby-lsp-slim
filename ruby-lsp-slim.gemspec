# frozen_string_literal: true

require_relative "lib/ruby_lsp/ruby_lsp_slim/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-lsp-slim"
  spec.version = RubyLspSlim::VERSION
  spec.authors = ["Andrea Fomera"]
  spec.license = "MIT"

  spec.summary = "Ruby LSP addon for Slim templates"
  spec.description = "A Ruby LSP addon that provides language server features for Slim template files."
  spec.homepage = "https://github.com/afomera/ruby-lsp-slim"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?("test/", ".git", ".github", "bin/")
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby-lsp", ">= 0.26.0"
  spec.add_dependency "slim", ">= 4.0"
end
