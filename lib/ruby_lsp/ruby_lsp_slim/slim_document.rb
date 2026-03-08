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
      end

      def language_id
        :slim
      end
    end
  end
end
