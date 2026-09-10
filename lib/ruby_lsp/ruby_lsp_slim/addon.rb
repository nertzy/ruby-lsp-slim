# frozen_string_literal: true

require "ruby_lsp/addon"
require_relative "request_adapter"
require_relative "cross_document_requests"
require_relative "version"

module RubyLsp
  module RubyLspSlim
    class Addon < ::RubyLsp::Addon
      def activate(_global_state, outgoing_queue)
        RubyLsp::Store.prepend(StorePatch) unless RubyLsp::Store.ancestors.include?(StorePatch)
        RubyLsp::Server.prepend(ServerPatch) unless RubyLsp::Server.ancestors.include?(ServerPatch)

        # Ruby LSP already advertises static incremental text synchronization.
        # File-watching support is not permission to register text sync dynamically.
        outgoing_queue << Notification.window_log_message(
          "[Ruby LSP Slim] Addon v#{::RubyLspSlim::VERSION} activated",
          type: Constant::MessageType::INFO
        )
      end

      def deactivate; end
      def name = "Ruby LSP Slim"
      def version = ::RubyLspSlim::VERSION
    end

    module StorePatch
      def set(uri:, source:, version:, language_id:)
        parsed_uri = URI(uri.to_s)
        path = parsed_uri.to_standardized_path
        return super unless language_id == :slim || (path && File.extname(path) == ".slim")

        @state[uri.to_s] =
          SlimDocument.new(source: source, version: version, uri: parsed_uri, global_state: @global_state)
      end
    end

    module ServerPatch
      def process_message(message)
        method = message[:method]
        return super unless message[:id] && method

        adapter = slim_request_adapter(method, slim_request_document(message))
        return super unless adapter

        response = if method == "completionItem/resolve"
                     adapter.resolve_completion(message[:params])
                   else
                     adapter.perform(method, message[:params])
                   end
        send_message(Result.new(id: message[:id], response: response))
      rescue RequestAdapter::UnsupportedRequest, ResponseMapper::UnsupportedResult, UnsafeEdit, UnmappedPosition,
             Requests::Rename::InvalidNameError => e
        slim_request_error(message, Constant::ErrorCodes::REQUEST_FAILED, e)
      rescue RequestAdapter::StaleDocument => e
        slim_request_error(message, Constant::ErrorCodes::CONTENT_MODIFIED, e)
      rescue InvalidPosition, RubyLsp::Document::InvalidLocationError, URI::Error, Store::NonExistingDocumentError,
             KeyError => e
        slim_request_error(message, Constant::ErrorCodes::INVALID_PARAMS, e)
      rescue StandardError => e
        slim_request_error(message, Constant::ErrorCodes::INTERNAL_ERROR, e)
        send_log_message("[Ruby LSP Slim] #{method}: #{e.full_message}", type: Constant::MessageType::ERROR)
      end

      private

      def text_document_did_open(message)
        text_document = message.dig(:params, :textDocument)
        return super unless text_document[:languageId] == "slim"

        @store.set(uri: text_document[:uri], source: text_document[:text],
                   version: text_document[:version], language_id: :slim)
      end

      def slim_request_document(message)
        params = message[:params] || {}
        uri = params.dig(:textDocument, :uri)
        uri ||= params.dig(:data, :rubyLspSlim, :uri) if message[:method] == "completionItem/resolve"
        uri ||= params.dig(:data, :uri) if message[:method] == "codeAction/resolve"
        uri ||= params.dig(:item, :uri) if message[:method].start_with?("typeHierarchy/")
        @store.get(URI(uri.to_s)) if uri
      end

      # Ordinary Ruby/ERB dispatch stays native. Workspace searches are the
      # exception: a Ruby-origin request must still see participating templates.
      def slim_request_adapter(method, document)
        if CrossDocumentRequests::METHODS.include?(method) && slim_workspace_request?(method) &&
           (document.is_a?(RubyDocument) || document.is_a?(SlimDocument))
          CrossDocumentRequests.new(@global_state, @store)
        elsif document.is_a?(SlimDocument)
          RequestAdapter.new(@global_state, document)
        end
      end

      def slim_workspace_request?(method)
        managed_slim_documents? ||
          (method == "textDocument/rename" && !CrossDocumentRequests.disk_templates(@global_state).empty?)
      end

      def managed_slim_documents?
        @store.to_enum(:each).any? { |_uri, document| document.is_a?(SlimDocument) }
      end

      def slim_request_error(message, code, error)
        if message[:id]
          send_message(RubyLsp::Error.new(id: message[:id], code: code, message: error.message))
        else
          send_log_message("[Ruby LSP Slim] #{error.message}", type: Constant::MessageType::ERROR)
        end
      end
    end
  end
end
