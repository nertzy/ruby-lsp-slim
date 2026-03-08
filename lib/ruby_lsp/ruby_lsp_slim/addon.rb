# frozen_string_literal: true

require "ruby_lsp/addon"
require_relative "slim_document"
require_relative "version"

module RubyLsp
  module RubyLspSlim
    class Addon < ::RubyLsp::Addon
      def activate(global_state, outgoing_queue)
        # Patch Store to recognize .slim files and create SlimDocuments
        unless RubyLsp::Store.ancestors.include?(StorePatch)
          RubyLsp::Store.prepend(StorePatch)
        end

        # Patch Server to recognize "slim" language ID
        unless RubyLsp::Server.ancestors.include?(ServerPatch)
          RubyLsp::Server.prepend(ServerPatch)
        end
      end

      def deactivate; end

      def name
        "Ruby LSP Slim"
      end

      def version
        ::RubyLspSlim::VERSION
      end
    end

    module StorePatch
      def get(uri)
        document = super
        return document unless document.nil?
      rescue Store::NonExistingDocumentError
        path = uri.to_standardized_path
        raise unless path

        ext = File.extname(path)
        if ext == ".slim"
          set(uri: uri, source: File.binread(path), version: 0, language_id: :slim)
          return @state[uri.to_s]
        end

        raise
      end

      def set(uri:, source:, version:, language_id:)
        if language_id == :slim
          @state[uri.to_s] = SlimDocument.new(
            source: source,
            version: version,
            uri: uri,
            global_state: @global_state,
          )
        else
          super
        end
      end
    end

    module ServerPatch
      def text_document_did_open(message)
        text_document = message.dig(:params, :textDocument)

        if text_document[:languageId] == "slim"
          text_document[:languageId] = "slim"
          @store.set(
            uri: text_document[:uri],
            source: text_document[:text],
            version: text_document[:version],
            language_id: :slim,
          )

          document = @store.get(text_document[:uri])
          if document.past_expensive_limit? && text_document[:uri].scheme == "file"
            log_message = <<~MESSAGE
              The file #{text_document[:uri].path} is too long. For performance reasons, semantic highlighting and
              diagnostics will be disabled.
            MESSAGE

            send_message(
              Notification.new(
                method: "window/logMessage",
                params: Interface::LogMessageParams.new(
                  type: Constant::MessageType::WARNING,
                  message: log_message,
                ),
              ),
            )
          end
        else
          super
        end
      end
    end
  end
end
