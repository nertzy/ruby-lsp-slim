# frozen_string_literal: true

require "securerandom"
require_relative "projection"
require_relative "generated_document"
require_relative "structure_collector"

module RubyLsp
  module RubyLspSlim
    # The Store always contains editor text, never a generated document. Invalid
    # versions retain diagnostics but expose no semantic AST from an older edit.
    class SlimDocument < RubyLsp::Document
      Snapshot = Struct.new(:source, :version, :projection, :generated_document, :fold_regions, :failure,
                            keyword_init: true)

      attr_reader :document_id

      def initialize(source:, **options)
        # URI/version can be reused after didClose. This wire-safe identity lasts
        # through edits and reparses, but never through replacement in the Store.
        @document_id = SecureRandom.uuid.freeze
        @projection_mutex = Mutex.new
        super(source: source.dup.force_encoding(Encoding::UTF_8).freeze, **options)
      end

      def parse!
        @projection_mutex.synchronize { parse_projection }
      end

      # Publish the text, map, AST and failure from one version under the same
      # lock used for edits. Readers retain this immutable tuple for the request;
      # separate calls to projection/generated_document could observe two edits.
      def snapshot
        @projection_mutex.synchronize do
          parse_projection
          Snapshot.new(source: @source, version: @version, projection: @projection,
                       generated_document: @generated_document, fold_regions: @fold_regions,
                       failure: @failure).freeze
        end
      end

      def projection = snapshot.projection
      def generated_document = snapshot.generated_document
      def fold_regions = snapshot.fold_regions
      def failure = snapshot.failure
      def parse_result = projection&.parse_result
      def ast = generated_document&.ast
      def valid? = !generated_document.nil?
      def syntax_error? = !valid?
      def language_id = :slim

      def push_edits(edits, version:)
        @projection_mutex.synchronize do
          # LSP ranges in a batch refer to the result of the preceding edit,
          # including full replacements. Publish nothing until all edits succeed.
          source = edits.inject(@source) { |text, edit| apply_edit(text, edit) }
          @source = source.freeze
          @version = version
          @last_edit = nil
          @cache.clear
          @semantic_tokens = EMPTY_CACHE
          clear_projection
          @needs_parsing = true
        end
      end

      def generated_position(position)
        state = snapshot
        original = Positions.new(state.source, @encoding).byte_offset(position)
        raise UnmappedPosition unless state.generated_document

        generated = state.projection.map.generated_offset(original)
        Positions.new(state.projection.ruby, Encoding::UTF_8).position(generated)
      end

      def locate_node(position, node_types: [])
        state = snapshot
        return unless state.generated_document

        original = Positions.new(state.source, @encoding).byte_offset(position)
        offset = state.projection.map.generated_offset(original)
        generated = Positions.new(state.projection.ruby, Encoding::UTF_8).position(offset)
        state.generated_document.locate_node(generated, node_types: node_types)
      rescue UnmappedPosition
        nil
      end

      def inside_host_language?(byte_offset)
        state = snapshot
        return true unless state.generated_document

        state.projection.map.generated_offset(byte_offset)
        false
      rescue UnmappedPosition
        true
      end

      private

      def parse_projection
        return false unless @needs_parsing

        # Invalidate before building: parse errors and unexpected failures must
        # never leave the last successful generated AST available to requests.
        clear_projection
        @needs_parsing = false
        @fold_regions = StructureCollector.new(default_tag: "div").call(@source)
        @projection = Projection.new(@source)
        @parse_result = @projection.parse_result
        if @projection.valid?
          @generated_document = GeneratedDocument.new(source: @projection.ruby, version: @version,
                                                      uri: @uri, global_state: @global_state)
        end
        true
      rescue StandardError => e
        # BaseServer also parses on its reader thread, outside its request rescue.
        # Keep unexpected failures visible without terminating that reader loop.
        clear_projection
        @failure = e
        warn "[Ruby LSP Slim] Projection failed for #{@uri} at version #{@version}: #{e.class}: #{e.message}"
        true
      end

      def clear_projection
        @projection = @generated_document = @parse_result = @fold_regions = @failure = nil
      end

      def apply_edit(source, edit)
        text = edit.fetch(:text).dup.force_encoding(Encoding::UTF_8)
        return text unless edit[:range]

        positions = Positions.new(source, @encoding)
        first = positions.byte_offset(edit[:range].fetch(:start))
        last = positions.byte_offset(edit[:range].fetch(:end))
        raise InvalidPosition if last < first

        source.byteslice(0...first) + text + source.byteslice(last..)
      end
    end
  end
end
