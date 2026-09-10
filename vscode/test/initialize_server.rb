# frozen_string_literal: true

require "bundler/setup" if ENV["BUNDLE_GEMFILE"]
require "json"
require "tmpdir"
require "timeout"
gem "ruby-lsp", ENV.fetch("RUBY_LSP_VERSION", ">= 0.26.0"), "< 1.0"
require "ruby_lsp/internal"

# Exercise native initialization without running the launcher, addon loading, or
# indexing. A disposable CWD also isolates Ruby LSP's bundle_env consumption.
params = JSON.parse($stdin.read, symbolize_names: true)
Dir.mktmpdir("ruby-lsp-slim-client") do |directory|
  Dir.chdir(directory) do
    params[:workspaceFolders] = [
      { uri: URI::Generic.from_path(path: directory).to_s, name: "client-test" }
    ]
    server = RubyLsp::Server.new(test_mode: true)
    begin
      server.process_message(id: 0, method: "initialize", params: params)
      Timeout.timeout(5) do
        loop do
          message = server.pop_response.to_hash
          next unless message[:id]&.zero?

          raise message[:error].inspect if message[:error]

          puts JSON.generate(
            version: RubyLsp::VERSION,
            capabilities: message.fetch(:result).fetch(:capabilities)
          )
          break
        end
      end
    ensure
      server.run_shutdown
    end
  end
end
