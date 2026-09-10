# frozen_string_literal: true

require_relative "request_adapter"

module RubyLsp
  module RubyLspSlim
    # Native lookup uses the persistent Ruby index, which deliberately excludes
    # generated templates. Inspect declarations and potentially matching uses
    # separately: native lookup can both misidentify a local constant and omit
    # an inherited use when its template namespace is absent from the index.
    # These caches belong to one fixed set of request snapshots, never the Store.
    class TemplateScopes
      Namespace = Struct.new(:name, :span) do
        include ImmutableValue
      end

      def initialize(global_state, entries)
        @global_state = global_state
        @entries = entries.select(&:projection).to_h { |entry| [entry.original.uri.to_s, entry] }
        @declarations = {}
        @unindexed_namespaces = {}
      end

      def validate_target!(uri, target, span = nil)
        entry = @entries[uri.to_s]
        return unless entry && target.is_a?(RubyIndexer::ReferenceFinder::ConstTarget)

        short_name = target.fully_qualified_name.split("::").last
        shadow = declarations(entry).find do |declaration|
          declaration.name.split("::").last == short_name && declaration.name != target.fully_qualified_name &&
            !@global_state.index[declaration.name]
        end
        if shadow
          raise RequestAdapter::UnsupportedRequest,
                "Cannot safely resolve #{target.fully_qualified_name} in #{uri}: " \
                "unindexed declaration #{shadow.name} may shadow it"
        end
        namespaces = @unindexed_namespaces[uri.to_s] ||= unindexed_namespaces(entry.document.ast)
        return if namespaces.empty?

        # Preflight before native discovery, including uses it cannot resolve at
        # all. Short-name matching is deliberately conservative; proving that an
        # unindexed scope is independent would require template name resolution.
        spans = span ? [span] : matching_constant_spans(entry.document.ast, short_name)
        namespace = namespaces.find do |scope|
          spans.any? { |candidate| scope.span.cover?(candidate.start_offset) }
        end
        return unless namespace

        raise RequestAdapter::UnsupportedRequest,
              "Cannot safely resolve #{target.fully_qualified_name} in #{uri}: " \
              "template namespace #{namespace.name} is not indexed"
      end

      def validate_destination!(uri, ast, span, name)
        # A declaration can capture the new name even in a template with no
        # references to the old name. Include every participating template.
        @destination_declarations ||= @entries.values.flat_map { |entry| declarations(entry) }
        short_name = name.split("::").last
        candidates = @destination_declarations.select do |declaration|
          declaration.name.split("::").last == short_name
        end
        return if candidates.empty?

        context = RubyDocument.locate(ast, span.start_offset, code_units_cache: GeneratedDocument::BYTE_OFFSETS)
        nesting = RubyIndexer::Index.actual_nesting(context.nesting, nil)
        # Bare top-level and absolute single constants cannot see disjoint namespaces.
        # In scoped/qualified lookups, unindexed aliases or ancestors may capture the
        # replacement, so matching destination names are conservatively rejected.
        unqualified = !name.delete_prefix("::").include?("::")
        top_level = unqualified && (nesting.empty? || name.start_with?("::"))
        conflict = candidates.find do |declaration|
          !top_level || declaration.name == name.delete_prefix("::")
        end
        return unless conflict

        raise RequestAdapter::UnsupportedRequest,
              "Cannot safely rename in #{uri}: destination #{name} may collide with or be captured by " \
              "template declaration #{conflict.name} in #{conflict.uri}"
      end

      private

      def declarations(entry)
        @declarations[entry.original.uri.to_s] ||= template_declarations(entry)
      end

      def matching_constant_spans(ast, short_name)
        spans = []
        queue = [ast]
        until queue.empty?
          node = queue.shift
          queue.concat(node.child_nodes.compact)
          case node
          when Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::ConstantTargetNode,
               Prism::ConstantPathTargetNode, Prism::ConstantWriteNode, Prism::ConstantAndWriteNode,
               Prism::ConstantOrWriteNode, Prism::ConstantOperatorWriteNode
            spans << Span.from_location(node.location) if node.name.to_s == short_name
          end
        end
        spans
      end

      def unindexed_namespaces(node, nesting = [])
        namespaces = []
        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          nesting = [*nesting, RubyIndexer::Index.constant_name(node.constant_path)]
          name = RubyIndexer::Index.actual_nesting(nesting, nil).join("::")
          namespaces << Namespace.new(name, Span.from_location(node.location)) unless indexed_namespace?(name)
        end
        node.child_nodes.compact.each { |child| namespaces.concat(unindexed_namespaces(child, nesting)) }
        namespaces
      end

      def indexed_namespace?(name)
        # Mere name presence is insufficient: constants and aliases do not carry
        # the ancestry that Index#lookup_ancestor_chain needs for inherited uses.
        (@global_state.index[name] || []).any?(RubyIndexer::Entry::Namespace)
      end

      def template_declarations(entry)
        # A throwaway index gives us native declaration/alias semantics without
        # making generated locations visible to ordinary workspace navigation.
        index = RubyIndexer::Index.new
        index.index_single(entry.original.uri, entry.document.source, collect_comments: false)
        (index.entries_for(entry.original.uri) || []).select do |declaration|
          declaration.is_a?(RubyIndexer::Entry::Namespace) || declaration.is_a?(RubyIndexer::Entry::Constant) ||
            declaration.is_a?(RubyIndexer::Entry::ConstantAlias) ||
            declaration.is_a?(RubyIndexer::Entry::UnresolvedConstantAlias)
        end
      end
    end
  end
end
