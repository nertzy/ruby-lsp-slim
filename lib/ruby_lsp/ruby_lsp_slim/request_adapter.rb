# frozen_string_literal: true

require_relative "slim_document"
require_relative "response_mapper"

module RubyLsp
  module RubyLspSlim
    class RequestAdapter
      class UnsupportedRequest < StandardError; end
      class StaleDocument < StandardError; end
      class HostPosition < StandardError; end

      METHODS = {
        "textDocument/diagnostic" => :diagnostics,
        "textDocument/hover" => :hover,
        "textDocument/completion" => :completion,
        "textDocument/definition" => :definition,
        "textDocument/documentHighlight" => :highlights,
        "textDocument/documentSymbol" => :symbols,
        "textDocument/semanticTokens/full" => :semantic_tokens,
        "textDocument/semanticTokens/full/delta" => :semantic_tokens,
        "textDocument/semanticTokens/range" => :semantic_tokens
      }.freeze

      def initialize(global_state, document)
        @state = document.snapshot
        @global_state = global_state
        @document = document
        @version = @state.version
        @projection = @state.projection
        @generated = @state.generated_document
        @mapper = ResponseMapper.new(@projection, document.encoding) if @projection && positions_available?
      end

      def perform(method, params)
        operation = METHODS[method]
        raise UnsupportedRequest, "#{method} is not supported for Slim documents" unless operation

        response = response_for(operation, params)
        # Empty host-language results describe a snapshot too. Validate every
        # successful response, not only the ones produced by a native request.
        check_version!
        response
      rescue ResponseMapper::UnsupportedResult => e
        raise UnsupportedRequest, e.message
      end

      def resolve_completion(item)
        marker = item.dig(:data, :rubyLspSlim)
        unless marker && marker[:uri] == @document.uri.to_s && marker[:version] == @version &&
               marker[:documentId] == @document.document_id
          raise StaleDocument, "Slim completion belongs to a different document lifetime or version"
        end

        response = ResponseMapper.serialize(Requests::CompletionResolve.new(@global_state, item).perform)
        check_version!
        response
      end

      def hover(params)
        request = Requests::Hover.new(@generated, @global_state, position(params), Prism::Dispatcher.new,
                                      SorbetLevel.ignore)
        @mapper.hover(request.perform)
      end

      def completion(params)
        mapped = params.merge(position: position(params))
        request = Requests::Completion.new(@generated, @global_state, mapped, SorbetLevel.ignore, Prism::Dispatcher.new)
        @mapper.completions(request.perform, uri: @document.uri, version: @version, document_id: @document.document_id)
      end

      def definition(params)
        request = Requests::Definition.new(@generated, @global_state, position(params), Prism::Dispatcher.new,
                                           SorbetLevel.ignore)
        @mapper.definitions(request.perform, uri: @document.uri)
      end

      def highlights(params)
        dispatcher = Prism::Dispatcher.new
        request = Requests::DocumentHighlight.new(@global_state, @generated, position(params), dispatcher)
        dispatcher.dispatch(@generated.ast)
        @mapper.highlights(request.perform)
      end

      def symbols(_params)
        dispatcher = Prism::Dispatcher.new
        request = Requests::DocumentSymbol.new(@document.uri, dispatcher)
        dispatcher.dispatch(@generated.ast)
        @mapper.symbols(request.perform)
      end

      def semantic_tokens(params)
        dispatcher = Prism::Dispatcher.new
        # Full responses are valid for delta requests. Never compute a delta in
        # generated space: a host-only edit can move every editor token.
        request = Requests::SemanticHighlighting.new(@global_state, dispatcher, @generated, nil)
        dispatcher.visit(@generated.ast)
        { resultId: "slim-#{@version}",
          data: @mapper.semantic_tokens(request.perform.data, requested_range: params[:range]) }
      end

      def diagnostics
        return { kind: "full", items: [failure_diagnostic] } if @state.failure

        items = @projection.diagnostics.map do |diagnostic|
          { message: diagnostic.message, severity: diagnostic.severity, source: "Ruby LSP Slim",
            range: @mapper ? @mapper.original_range(diagnostic.span) : document_start_range }
        end
        items.concat(prism_diagnostics)
        { kind: "full", items: items }
      end

      private

      def response_for(operation, params)
        if operation == :diagnostics
          diagnostics
        elsif @state.failure
          raise UnsupportedRequest, "Slim projection failed; see document diagnostics and server log"
        elsif @generated.nil? || (@document.past_expensive_limit? && operation == :semantic_tokens)
          empty_response(operation)
        else
          public_send(operation, params)
        end
      rescue HostPosition
        empty_response(operation)
      end

      def positions_available?
        @state.source.valid_encoding? && !@state.source.match?(/\r(?!\n)/)
      end

      # Invalid encoding/line endings prevent meaningful editor coordinates. Such
      # whole-document input errors are anchored at the document start explicitly.
      def document_start_range
        { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } }
      end

      def position(params)
        original = Positions.new(@projection.source, @document.encoding).byte_offset(params.fetch(:position))
        generated = @projection.map.generated_offset(original)
        Positions.new(@projection.ruby, Encoding::UTF_8).position(generated)
      rescue UnmappedPosition
        raise HostPosition
      end

      def check_version!
        raise StaleDocument, "Slim document changed while processing the request" unless @document.version == @version
      end

      def empty_response(operation)
        case operation
        when :hover then nil
        when :semantic_tokens then { resultId: "slim-#{@version}", data: [] }
        else []
        end
      end

      def prism_diagnostics
        result = @projection.parse_result
        return [] unless result

        result.errors.map do |error|
          { message: error.message, severity: Constant::DiagnosticSeverity::ERROR, source: "Prism",
            range: @mapper ? @mapper.diagnostic_range(error.location) : document_start_range }
        end
      end

      def failure_diagnostic
        { message: "Slim projection failed (#{@state.failure.class}); see the server log",
          severity: Constant::DiagnosticSeverity::ERROR, source: "Ruby LSP Slim",
          range: document_start_range }
      end
    end
  end
end
