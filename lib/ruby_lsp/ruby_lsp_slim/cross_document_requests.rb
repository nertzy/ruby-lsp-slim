# frozen_string_literal: true

require_relative "request_adapter"
require_relative "template_scopes"

module RubyLsp
  module RubyLspSlim
    # Reuse native target resolution, workspace discovery and file-renaming rules.
    # Only the request-local document view and collection coordinates differ.
    class CrossDocumentRequests
      METHODS = %w[textDocument/references textDocument/rename textDocument/prepareRename].freeze

      def self.disk_templates(global_state)
        Dir.glob(File.join(global_state.workspace_path, "**/*.slim")).select { |path| File.file?(path) }.sort
      end

      # Bind original bytes, version, map and native request input together. A
      # result must be mapped through this entry, never a newer live projection.
      class Entry
        attr_reader :original, :source, :version, :projection

        def initialize(global_state, original)
          @original = original
          if original.is_a?(SlimDocument)
            snapshot = original.snapshot
            @source = snapshot.source
            @version = snapshot.version
            @projection = snapshot.projection
            @document = snapshot.generated_document
          else
            @version = original.version
            @source = original.source.dup.force_encoding(Encoding::UTF_8).freeze
            klass = original.is_a?(ERBDocument) ? ERBDocument : GeneratedDocument
            @document = klass.new(source: @source, version: @version, uri: original.uri, global_state: global_state)
          end
          freeze
        end

        def document
          unless @document
            raise RequestAdapter::UnsupportedRequest,
                  "Cannot search #{original.uri}: invalid Slim syntax or projection failure may hide references"
          end
          @document
        end

        def position(value, encoding)
          offset = Positions.new(source, encoding).byte_offset(value)
          offset = projection.map.generated_offset(offset) if projection
          Positions.new(document.source, Encoding::UTF_8).position(offset)
        rescue UnmappedPosition
          raise RequestAdapter::HostPosition
        end

        def original_span(span, producer, edit:)
          mapped = if projection
                     edit ? projection.map.edit_span(span) : projection.map.exact_span(span)
                   else
                     # Native ERB can shorten non-ASCII host text when masking it.
                     # Without its own map, reject only matching unsafe ranges.
                     if source.bytesize != producer.bytesize
                       raise UnsafeEdit, "Cannot safely map embedded source in #{original.uri}"
                     end

                     span
                   end
          unless source.byteslice(mapped.range) == producer.byteslice(span.range)
            raise UnsafeEdit, "Source text does not match the reference in #{original.uri}"
          end

          mapped
        end
      end

      # The native Store protocol over request-local documents. This view owns
      # discovery and freshness; TemplateScopes owns constant-resolution safety.
      # Neither installs projected documents or declarations into server state.
      class StoreView
        def initialize(global_state, store)
          @global_state = global_state
          @store = store
          @originals = store.to_enum(:each).to_h
          @entries = @originals.each_with_object({}) do |(uri, document), entries|
            next unless document.is_a?(SlimDocument) || document.is_a?(RubyDocument) || document.is_a?(ERBDocument)

            entries[uri] = Entry.new(global_state, document)
          end
          @disk_sources = {}
          @disk_entries = {}
        end

        def get(uri) = @entries.fetch(uri.to_s).document
        def key?(uri) = @originals.key?(uri.to_s)
        def entry(uri) = @entries.fetch(uri.to_s)

        def each
          @entries.each { |uri, entry| yield uri, entry.document }
          @disk_entries.each { |uri, entry| yield uri, entry.document }
        end

        def include_disk_templates!
          # Adding participants invalidates scope caches, not existing snapshots.
          @template_scopes = nil
          @disk_template_paths = CrossDocumentRequests.disk_templates(@global_state)
          @disk_template_paths.each do |path|
            uri = URI::Generic.from_path(path: path)
            next if key?(uri)

            source = File.binread(path).force_encoding(Encoding::UTF_8).freeze
            document = SlimDocument.new(source: source, version: 0, uri: uri, global_state: @global_state)
            @disk_entries[uri.to_s] = Entry.new(@global_state, document)
            @disk_sources[uri.to_s] = source
          rescue Errno::ENOENT
            raise RequestAdapter::StaleDocument, "Template disappeared during the request: #{path}"
          end
        end

        def track_disk_ruby!
          @disk_ruby_paths = disk_ruby_paths
        end

        # Called with the bytes native discovery actually parsed, even for zero
        # matches. Re-reading now could bless a different, unsearched disk file.
        def snapshot_source(uri, source)
          return if @entries.key?(uri.to_s) || @disk_entries.key?(uri.to_s)

          @disk_sources[uri.to_s] ||= source.dup.force_encoding(Encoding::UTF_8).freeze
        end

        def validate_target!(uri, target, span = nil)
          template_scopes.validate_target!(uri, target, span)
        end

        def map_location(uri, location, producer:, edit: false)
          map_span(uri, Span.from_location(location), producer, edit: edit)
        rescue UnmappedPosition, InvalidPosition
          raise RequestAdapter::UnsupportedRequest, "Cannot map a reference exactly in #{uri}"
        end

        def map_range(uri, value, producer, edit: false)
          map_span(uri, generated_span(value, producer), producer, edit: edit)
        end

        def map_edits(uri, ast, edits, target: nil)
          producer = ast.source_lines.join
          snapshot_source(uri, producer)
          ResponseMapper.serialize(edits).map do |edit|
            raise UnsafeEdit, "Multiline constant rename is not supported" if edit.fetch(:newText).match?(/[\r\n]/)

            span = generated_span(edit.fetch(:range), producer)
            if target
              validate_target!(uri, target, span)
              template_scopes.validate_destination!(uri, ast, span, edit.fetch(:newText))
            end
            edit.merge(range: map_span(uri, span, producer, edit: true))
          end
        rescue UnsafeEdit, UnmappedPosition, InvalidPosition
          raise UnsafeEdit, "Cannot safely map every rename edit in #{uri}"
        end

        def version_workspace_edit(result)
          result = ResponseMapper.serialize(result)
          result&.fetch(:documentChanges, nil)&.each do |change|
            identifier = change[:textDocument]
            next unless identifier && @entries.key?(identifier[:uri])

            identifier[:version] = @entries.fetch(identifier[:uri]).version
          end
          result
        end

        # Optimistic validation, not a filesystem transaction: check membership
        # as well as contents so additions and zero-match changes cannot silently
        # yield an incomplete rename. Any mismatch rejects the entire response.
        def verify!
          current = @store.to_enum(:each).to_h
          changed = current.keys.sort != @originals.keys.sort || @entries.any? do |uri, entry|
            !current[uri].equal?(entry.original) || entry.original.version != entry.version ||
              entry.original.source.b != entry.source.b
          end
          raise RequestAdapter::StaleDocument, "Workspace documents changed during the Slim-aware request" if changed

          if @disk_template_paths && @disk_template_paths != CrossDocumentRequests.disk_templates(@global_state)
            raise RequestAdapter::StaleDocument, "Workspace templates changed during the request"
          end

          if @disk_ruby_paths && @disk_ruby_paths != disk_ruby_paths
            raise RequestAdapter::StaleDocument, "Workspace Ruby files changed during the request"
          end

          @disk_sources.each do |uri, source|
            next if File.binread(URI(uri).to_standardized_path) == source.b

            raise RequestAdapter::StaleDocument, "File changed during the request: #{uri}"
          rescue Errno::ENOENT
            raise RequestAdapter::StaleDocument, "File disappeared during the request: #{uri}"
          end
        end

        private

        def disk_ruby_paths
          # Match native discovery, including its managed-document and directory exclusions.
          Dir.glob(File.join(@global_state.workspace_path, "**/*.rb")).select do |path|
            File.file?(path) && !key?(URI::Generic.from_path(path: path))
          end.sort
        end

        def template_scopes
          @template_scopes ||= TemplateScopes.new(@global_state, [*@entries.values, *@disk_entries.values])
        end

        def generated_span(value, producer)
          value = ResponseMapper.serialize(value)
          positions = Positions.new(producer, Encoding::UTF_8)
          Span.new(positions.byte_offset(value.fetch(:start)), positions.byte_offset(value.fetch(:end)))
        end

        def map_span(uri, span, producer, edit:)
          entry = @entries[uri.to_s] || @disk_entries[uri.to_s]
          if entry
            source = entry.source
            span = entry.original_span(span, producer, edit: edit)
          else
            source = producer
          end
          positions = Positions.new(source, @global_state.encoding)
          { start: positions.position(span.start_offset), end: positions.position(span.end_offset) }
        end
      end

      class References < Requests::References
        private

        def collect_references(target, parse_result, uri)
          @store.snapshot_source(uri, parse_result.source.source)
          @store.validate_target!(uri, target)
          dispatcher = Prism::Dispatcher.new
          finder = RubyIndexer::ReferenceFinder.new(target, @global_state.index, dispatcher, uri)
          ast = parse_result.value.first
          dispatcher.visit(ast)
          declarations = constant_declarations(ast)
          include_declarations = @params.dig(:context, :includeDeclaration) != false
          finder.references.each do |reference|
            declaration = if target.is_a?(RubyIndexer::ReferenceFinder::ConstTarget)
                            declarations.include?(Span.from_location(reference.location))
                          else
                            reference.declaration
                          end
            next if declaration && !include_declarations

            @store.validate_target!(uri, target, Span.from_location(reference.location))
            range = @store.map_location(uri, reference.location, producer: parse_result.source.source)
            @locations << Interface::Location.new(uri: uri.to_s, range: range)
          end
        end

        # The native finder compares index locations to Prism locations to identify
        # declarations. That comparison is invalid for unindexed generated sources.
        def constant_declarations(ast)
          spans = []
          queue = [ast]
          until queue.empty?
            node = queue.shift
            queue.concat(node.child_nodes.compact)
            location = case node
                       when Prism::ClassNode, Prism::ModuleNode then node.constant_path.location
                       when Prism::ConstantWriteNode, Prism::ConstantAndWriteNode,
                            Prism::ConstantOrWriteNode, Prism::ConstantOperatorWriteNode then node.name_loc
                       when Prism::ConstantPathWriteNode, Prism::ConstantPathAndWriteNode,
                            Prism::ConstantPathOrWriteNode, Prism::ConstantPathOperatorWriteNode
                         node.target.location
                       when Prism::ConstantTargetNode, Prism::ConstantPathTargetNode then node.location
                       end
            spans << Span.from_location(location) if location
          end
          spans
        end
      end

      class Rename < Requests::Rename
        private

        def collect_text_edits(target, name)
          parsed = Prism.parse(@new_name)
          node = parsed.value.statements.body.first
          unless parsed.success? && parsed.value.statements.body.length == 1 &&
                 (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && node.slice == @new_name
            raise InvalidNameError, "The new name must be a Ruby constant path"
          end

          @store.include_disk_templates!
          super
        end

        def collect_changes(target, ast, name, uri)
          @store.validate_target!(uri, target)
          @store.map_edits(uri, ast, super, target: target)
        end
      end

      def initialize(global_state, store)
        @global_state = global_state
        @view = StoreView.new(global_state, store)
      end

      def perform(method, params)
        uri = params.fetch(:textDocument).fetch(:uri)
        entry = @view.entry(uri)
        document = entry.document
        mapped = params.merge(position: entry.position(params.fetch(:position), @global_state.encoding))
        response = case method
                   when "textDocument/references"
                     @view.track_disk_ruby!
                     References.new(@global_state, @view, document, mapped).perform
                   when "textDocument/rename"
                     @view.track_disk_ruby!
                     mapped.fetch(:newName)
                     result = Rename.new(@global_state, @view, document, mapped).perform
                     @view.version_workspace_edit(result)
                   when "textDocument/prepareRename"
                     range = Requests::PrepareRename.new(document, mapped[:position]).perform
                     @view.map_range(uri, range, document.source) if range
                   else raise RequestAdapter::UnsupportedRequest, "Unsupported cross-document request: #{method}"
                   end
        @view.verify!
        ResponseMapper.serialize(response)
      rescue RequestAdapter::HostPosition
        @view.verify!
        method == "textDocument/references" ? [] : nil
      end
    end
  end
end
