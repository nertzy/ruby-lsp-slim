# frozen_string_literal: true

require_relative "slim_scanner"

module RubyLsp
  module RubyLspSlim
    class SlimDocument < RubyLsp::ERBDocument
      def parse!
        return false unless @needs_parsing

        @needs_parsing = false
        scanner = SlimScanner.new(@source)
        scanner.scan
        @host_language_source = scanner.host_language
        @parse_result = Prism.parse_lex(scanner.ruby, partial_script: true)
        @code_units_cache = @parse_result.code_units_cache(@encoding)
        true
      rescue StandardError => e
        @host_language_source = +""
        @parse_result = Prism.parse_lex("", partial_script: true)
        @code_units_cache = @parse_result.code_units_cache(@encoding)
        $stderr.puts("[Ruby LSP Slim] Parse error: #{e.message}")
        true
      end

      def language_id
        # Return :erb so that ruby-lsp's Definition listener applies the same
        # "Object" receiver-type fallback it uses for ERB templates, allowing
        # bare method calls like `current_user` to resolve via the index.
        :erb
      end
    end
  end
end
