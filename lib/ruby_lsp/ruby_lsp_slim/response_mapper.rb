# frozen_string_literal: true

require_relative "projection"

module RubyLsp
  module RubyLspSlim
    # Each entry point names the producer and coordinate domain. An arbitrary
    # nested `range` or a matching URI is not proof that a range was generated.
    class ResponseMapper
      class UnsupportedResult < StandardError; end

      Token = Struct.new(:line, :column, :width, :type, :modifiers, keyword_init: true)

      def self.serialize(value)
        case value
        when Array then value.map { |item| serialize(item) }
        when Hash then value.transform_values { |item| serialize(item) }
        else value.respond_to?(:to_hash) ? serialize(value.to_hash) : value
        end
      end

      def initialize(projection, encoding)
        @projection = projection
        @encoding = encoding
        @original_positions = Positions.new(projection.source, encoding)
        @generated_positions = Positions.new(projection.ruby, Encoding::UTF_8)
      end

      def original_range(span)
        { start: @original_positions.position(span.start_offset), end: @original_positions.position(span.end_offset) }
      end

      def range(value, policy: :exact)
        value = self.class.serialize(value)
        span = Span.new(@generated_positions.byte_offset(value.fetch(:start)),
                        @generated_positions.byte_offset(value.fetch(:end)))
        original = case policy
                   when :exact then @projection.map.exact_span(span)
                   when :edit then @projection.map.edit_span(span)
                   when :read then @projection.map.read_range(span).span
                   else raise ArgumentError, "Unknown mapping policy: #{policy}"
                   end
        original_range(original)
      end

      def diagnostic_range(location)
        span = Span.from_location(location)
        # Prism can point one past the final synthetic separator. Attribute that
        # zero-width EOF error to the preceding segment, not a fictitious token.
        at_eof = span.start_offset == @projection.ruby.bytesize
        if span.start_offset == span.end_offset && at_eof && span.start_offset.positive?
          span = Span.new(span.start_offset - 1, span.end_offset)
        end
        original_range(@projection.map.read_range(span).span)
      end

      def highlights(items)
        self.class.serialize(items).filter_map do |item|
          item.merge(range: range(item.fetch(:range)))
        rescue UnmappedPosition
          nil
        end
      end

      def hover(value)
        item = self.class.serialize(value)
        return item unless item && item[:range]

        item.merge(range: range(item[:range]))
      end

      def symbols(items)
        self.class.serialize(items).filter_map do |item|
          item.merge(range: range(item.fetch(:range), policy: :read),
                     selectionRange: range(item.fetch(:selectionRange)), children: symbols(item.fetch(:children, [])))
        rescue UnmappedPosition
          nil
        end
      end

      def completions(items, uri:, version:, document_id:)
        self.class.serialize(items).filter_map do |item|
          # Commands can carry opaque edits. This adapter only vouches for the
          # explicit, single-line edits it can check before the client applies them.
          next if item[:command] || !item[:textEdit]

          mapped = item.merge(textEdit: completion_edit(item[:textEdit]))
          if item[:additionalTextEdits]
            mapped[:additionalTextEdits] = item[:additionalTextEdits].map { |edit| completion_edit(edit) }
          end
          mapped[:data] = item.fetch(:data, {}).merge(
            rubyLspSlim: { uri: uri.to_s, version: version, documentId: document_id }
          )
          mapped
        rescue UnsafeEdit, UnmappedPosition, InvalidPosition
          nil
        end
      end

      def definitions(items, uri:)
        self.class.serialize(items).map do |item|
          target = item[:targetUri] || item[:uri]
          if target == uri.to_s
            raise UnsupportedResult, "Slim definition targets need explicit original/generated provenance"
          end
          unless @encoding == Encoding::UTF_16LE || file_start_link?(item)
            raise UnsupportedResult, "External Slim symbol definitions currently require UTF-16 position encoding"
          end

          item[:originSelectionRange] = range(item[:originSelectionRange]) if item[:originSelectionRange]
          item
        end
      end

      def semantic_tokens(data, requested_range: nil)
        tokens = decode_tokens(data).filter_map do |token|
          value = { start: { line: token.line, character: token.column },
                    end: { line: token.line, character: token.column + token.width } }
          mapped = range(value)
          start = mapped[:start]
          finish = mapped[:end]
          next unless start[:line] == finish[:line]
          next if requested_range && !within_range?(mapped, requested_range)

          Token.new(line: start[:line], column: start[:character], width: finish[:character] - start[:character],
                    type: token.type, modifiers: token.modifiers).freeze
        rescue UnmappedPosition
          nil
        end
        encode_tokens(tokens)
      end

      private

      # Native require/require_relative return a Location at the start of a file,
      # not an indexed symbol range. That position is independent of encoding.
      def file_start_link?(item)
        return false unless item[:uri] && item[:range] && !item[:targetUri]

        origin = { line: 0, character: 0 }
        item[:range] == { start: origin, end: origin }
      end

      def completion_edit(edit)
        raise UnsafeEdit if edit.fetch(:newText).match?(/[\r\n]/)

        if edit[:range]
          edit.merge(range: range(edit[:range], policy: :edit))
        else
          edit.merge(insert: range(edit.fetch(:insert), policy: :edit),
                     replace: range(edit.fetch(:replace), policy: :edit))
        end
      end

      def within_range?(mapped, requested)
        first = requested.fetch(:start).values_at(:line, :character)
        last = requested.fetch(:end).values_at(:line, :character)
        selection = first..last
        selection.cover?(mapped[:start].values_at(:line, :character)) &&
          selection.cover?(mapped[:end].values_at(:line, :character))
      end

      def decode_tokens(data)
        line = column = 0
        data.each_slice(5).map do |delta_line, delta_column, length, type, modifiers|
          line += delta_line
          column = delta_line.zero? ? column + delta_column : delta_column
          Token.new(line: line, column: column, width: length, type: type, modifiers: modifiers).freeze
        end
      end

      def encode_tokens(tokens)
        line = column = 0
        tokens.sort_by { |token| [token.line, token.column] }.flat_map do |token|
          result = [token.line - line, token.line == line ? token.column - column : token.column,
                    token.width, token.type, token.modifiers]
          line = token.line
          column = token.column
          result
        end
      end
    end
  end
end
