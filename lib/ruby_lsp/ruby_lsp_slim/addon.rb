# frozen_string_literal: true

require "ruby_lsp/addon"
require_relative "slim_document"
require_relative "version"

module RubyLsp
  module RubyLspSlim
    class Addon < ::RubyLsp::Addon
      def activate(global_state, outgoing_queue)
        @outgoing_queue = outgoing_queue

        RubyLsp::Store.prepend(StorePatch) unless RubyLsp::Store.ancestors.include?(StorePatch)
        RubyLsp::Server.prepend(ServerPatch) unless RubyLsp::Server.ancestors.include?(ServerPatch)

        register_slim_capability if global_state.client_capabilities.supports_watching_files

        outgoing_queue << Notification.window_log_message(
          "[Ruby LSP Slim] Addon v#{::RubyLspSlim::VERSION} activated",
          type: Constant::MessageType::INFO
        )
      end

      def deactivate; end

      def name
        "Ruby LSP Slim"
      end

      def version
        ::RubyLspSlim::VERSION
      end

      private

      def register_slim_capability
        registration = Request.new(
          id: "ruby-lsp-slim-register",
          method: "client/registerCapability",
          params: Interface::RegistrationParams.new(
            registrations: [
              Interface::Registration.new(
                id: "ruby-lsp-slim-text-sync",
                method: "textDocument/didOpen",
                register_options: Interface::TextDocumentRegistrationOptions.new(
                  document_selector: [
                    { language: "slim" }
                  ]
                )
              ),
              Interface::Registration.new(
                id: "ruby-lsp-slim-did-change",
                method: "textDocument/didChange",
                register_options: Interface::TextDocumentChangeRegistrationOptions.new(
                  document_selector: [
                    { language: "slim" }
                  ],
                  sync_kind: Constant::TextDocumentSyncKind::INCREMENTAL
                )
              ),
              Interface::Registration.new(
                id: "ruby-lsp-slim-did-close",
                method: "textDocument/didClose",
                register_options: Interface::TextDocumentRegistrationOptions.new(
                  document_selector: [
                    { language: "slim" }
                  ]
                )
              )
            ]
          )
        )
        @outgoing_queue << registration
      end
    end

    module StorePatch
      def get(uri)
        super
      rescue Store::NonExistingDocumentError
        path = uri.to_standardized_path
        raise unless path && File.extname(path) == ".slim" && File.file?(path)

        set(uri: uri, source: File.binread(path), version: 0, language_id: :slim)
        @state[uri.to_s]
      end

      def set(uri:, source:, version:, language_id:)
        if language_id == :slim
          @state[uri.to_s] = SlimDocument.new(
            source: source,
            version: version,
            uri: uri,
            global_state: @global_state
          )
        else
          super
        end
      end
    end

    module ServerPatch
      def text_document_did_open(message)
        text_document = message.dig(:params, :textDocument)
        uri = text_document[:uri]
        path = uri.is_a?(URI::Generic) ? uri.to_standardized_path : uri.to_s

        if text_document[:languageId] == "slim" || (path && File.extname(path) == ".slim")
          @store.set(
            uri: uri,
            source: text_document[:text],
            version: text_document[:version],
            language_id: :slim
          )

          document = @store.get(uri)
          if document.past_expensive_limit? && uri.respond_to?(:scheme) && uri.scheme == "file"
            send_message(
              Notification.new(
                method: "window/logMessage",
                params: Interface::LogMessageParams.new(
                  type: Constant::MessageType::WARNING,
                  message: "The file #{path} is too long. Semantic highlighting and diagnostics will be disabled."
                )
              )
            )
          end
        else
          super
        end
      end
    end
  end
end
