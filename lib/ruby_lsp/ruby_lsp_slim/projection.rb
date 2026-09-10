# frozen_string_literal: true

require "prism"
require_relative "positioned_parser"

module RubyLsp
  module RubyLspSlim
    class Projection
      Boundary = Struct.new(:span, :owner, :header) do
        include ImmutableValue
      end

      # Slim rewrites tree nodes as its structural passes run. Carry ownership to
      # replacement nodes; a pass that replaces code must also carry its payload.
      module ProvenanceFilter
        def initialize(payloads, owners, **options)
          @payloads = payloads
          @owners = owners
          super(options)
        end

        # These passes see embedded nodes before expansion. Slim 4.0.0's base
        # handler takes two arguments even though its parser also supplies attrs.
        def on_slim_embedded(type, content, attrs = %i[html attrs])
          [:slim, :embedded, type, compile(content), attrs]
        end

        def compile(expression)
          result = super
          @owners[result] = @owners[expression] if @owners.key?(expression)
          result
        end
      end

      class DoInserter < Slim::DoInserter
        include ProvenanceFilter

        def on_slim_control(code, content)
          result = super
          carry_code(code, result[2])
          result
        end

        def on_slim_output(escape, code, content)
          result = super
          carry_code(code, result[3])
          result
        end

        private

        def carry_code(original, generated)
          return if original.equal?(generated)

          payload = @payloads.fetch(original)
          unless generated == "#{original} do"
            raise PositionedParser::MappingError.new("Unsupported Slim block normalization", payload.owner)
          end

          @payloads[generated] = payload.append(" do", kind: :do)
        end
      end

      class EndInserter < Slim::EndInserter
        include ProvenanceFilter

        attr_reader :error_span

        def on_multi(*expressions)
          explicit = expressions.find do |expression|
            expression[0..1] == %i[slim control] && expression[2].match?(Slim::EndInserter::END_RE)
          end
          @error_span = @payloads.fetch(explicit[2]).owner if explicit
          super
        end

        private

        def append_end(result)
          control = result.reverse.find { |node| node[0..1] == %i[slim control] }
          owner = @payloads.fetch(control[2]).owner
          super
          @owners[result.last] = owner
          result
        end
      end

      class AttributeContext < Slim::Splat::Filter
        def builder?(attributes)
          attributes.any? { |attribute| splat?(attribute) }
        end
      end

      class AttributeMerger < Temple::HTML::AttributeMerger
        include ProvenanceFilter

        attr_reader :error_span

        def on_html_attrs(*attributes)
          @error_span = @owners[attributes.first]
          originals = {}.compare_by_identity
          attributes.each { |attribute| originals[attribute[3]] = true }
          result = super
          result.drop(2).each do |attribute|
            attribute[3] = without_rendering(attribute[3], originals)
            @owners[attribute] = @error_span
          end
          result
        end

        private

        # Let Temple decide duplicates, grouping, and order. Only its generated
        # rendering captures/joins are discarded; original values keep identity.
        def without_rendering(expression, originals)
          return expression if originals.key?(expression)

          case expression.first
          when :multi
            [:multi, *expression.drop(1).filter_map { |child| without_rendering(child, originals) }]
          when :capture then without_rendering(expression[2], originals)
          when :static, :code, :dynamic then nil
          else
            raise PositionedParser::MappingError.new("Unsupported attribute merging normalization", @error_span)
          end
        end
      end

      attr_reader :source, :map, :parse_result, :diagnostics

      def initialize(source)
        @source = source.dup.freeze
        @map = SourceMap.new(@source)
        @diagnostics = []
        @boundaries = []
        build
        @map.finish
        @parse_result = Prism.parse_lex(ruby)
        check_boundaries unless @parse_result.failure?
        @diagnostics.freeze
      end

      def ruby = @map.ruby
      def ast = @parse_result.value.first

      def valid?
        !@parse_result.failure? && @diagnostics.none? { |diagnostic| diagnostic.severity == 1 }
      end

      private

      def build
        unless @source.encoding == Encoding::UTF_8 && @source.valid_encoding? && !@source.match?(/\r(?!\n)/)
          diagnose("Only valid UTF-8 source with LF or CRLF is supported", Span.new(0, @source.bytesize))
          return
        end

        @parser = PositionedParser.new(default_tag: "div")
        tree = @parser.call(@source)
        @payloads = @parser.payloads
        @owners = @parser.owners
        # Follow Slim's structural order: implicit do affects which blocks need
        # end. Attribute sorting/merging below also follows native semantics;
        # emitting values in source order can change Ruby local-variable binding.
        tree = DoInserter.new(@payloads, @owners).call(tree)
        @end_inserter = EndInserter.new(@payloads, @owners)
        tree = @end_inserter.call(tree)
        @attribute_context = AttributeContext.new
        @attribute_sorter = Temple::HTML::AttributeSorter.new(sort_attrs: Slim::Engine.options[:sort_attrs])
        @attribute_merger = AttributeMerger.new(@payloads, @owners, merge_attrs: Slim::Engine.options[:merge_attrs])
        emit(tree)
      rescue Slim::Parser::SyntaxError => e
        diagnose(e.error, @parser.failure_span)
      rescue PositionedParser::MappingError => e
        diagnose(e.message, e.span)
      rescue Temple::FilterError => e
        span = @attribute_merger&.error_span || @end_inserter&.error_span || Span.new(0, @source.bytesize)
        diagnose(e.message, span)
      end

      def emit(node)
        case node.first
        when :multi then node.drop(1).each { |child| emit(child) }
        when :newline, :static then nil
        when :html then emit_html(node)
        when :escape then emit(node[2])
        when :slim then emit_slim(node)
        when :code
          if node[1] == "end" && @owners[node]
            @map.synthetic("end\n", :end, @owners.fetch(node))
          else
            unsupported(node)
          end
        else unsupported(node)
        end
      end

      def emit_html(node)
        case node[1]
        when :tag
          if node[2] == "*"
            unsupported(node)
          else
            node.drop(3).each { |child| emit(child) }
          end
        when :attrs then emit_attributes(node)
        when :attr, :condcomment then emit(node[3])
        when :comment then emit(node[2])
        when :doctype then nil
        else unsupported(node)
        end
      end

      def emit_attributes(node)
        unless @attribute_context.builder?(node.drop(2))
          node = @attribute_sorter.call(node)
          node = @attribute_merger.call(node)
        end
        node.drop(2).each { |attribute| emit(attribute) }
      end

      def emit_slim(node)
        case node[1]
        when :control
          header = node[2].match?(Slim::DoInserter::BLOCK_REGEX)
          emit_code(@payloads.fetch(node[2]), header: header)
          emit(node[3])
        when :output
          emit_output(@payloads.fetch(node[3]), node[4])
        when :attrvalue, :splat
          code = node[1] == :splat ? node[2] : node[3]
          emit_code(@payloads.fetch(code), value: true)
        when :text then emit(node[3])
        when :interpolate then emit_interpolation(@payloads.fetch(node[2]))
        when :embedded
          if node[2] == "ruby"
            emit_ruby_filter(node[3])
          else
            unsupported(node)
          end
        else unsupported(node)
        end
      end

      # Slim treats output conditionals and do-blocks as values spanning their
      # indented bodies. Keep the value wrapper open until the body ends.
      def emit_output(payload, body)
        block = payload.text.match?(Slim::Controls::IF_RE)
        emit_code(payload, header: block, value: true)
        emit(body)
        return unless block

        @map.synthetic("end", :end, payload.owner)
        @map.synthetic(")]", :value_close, payload.owner)
        @map.synthetic("\n", :separator, payload.owner)
      end

      def emit_code(payload, header: false, value: false, separator: ";\n")
        # Values must stay values (return/break are not legal results). The array
        # context adds no locals or calls. The statement prefix prevents relocation
        # from activating column-zero markers or first-line magic comments.
        @map.synthetic(value ? "[(" : "; ", value ? :value_open : :statement_prefix, payload.owner)
        start = ruby.bytesize
        emit_pieces(payload)
        @boundaries << Boundary.new(Span.new(start, ruby.bytesize), payload.owner, header)
        @map.synthetic(")]", :value_close, payload.owner) if value && !header
        # Keep the compiler's same-line closers/terminator: moving them after a
        # newline repairs swallowed delimiters and can activate comment directives.
        @map.synthetic(separator, :separator, payload.owner)
      end

      def emit_pieces(payload)
        payload.pieces.each do |piece|
          if piece.original
            @map.copy(piece.original)
          else
            @map.synthetic(piece.text, piece.kind || :normalized, payload.owner)
          end
        end
      end

      def emit_interpolation(payload)
        tree = Slim::Interpolation.new.call([:slim, :interpolate, payload.text])
        cursor = 0
        tree.drop(1).each do |node|
          if node[0] == :static
            cursor += 1 if node[1] == "\#{" && payload.text.byteslice(cursor, 3) == "\\\#{"
            consumed = node[1]
          elsif node[0..1] == %i[slim output]
            opening, closing = node[2] ? ["\#{", "}"] : ["\#{{", "}}"]
            consumed = opening + node[3] + closing
            code = payload.slice(cursor + opening.bytesize, node[3].bytesize)
            emit_output(code, node[4])
          else
            raise PositionedParser::MappingError.new("Unsupported Slim interpolation", payload.owner)
          end
          unless payload.text.byteslice(cursor, consumed.bytesize) == consumed
            raise PositionedParser::MappingError.new("Unsupported Slim interpolation normalization", payload.owner)
          end

          cursor += consumed.bytesize
        end
        return if cursor == payload.text.bytesize

        raise PositionedParser::MappingError.new("Incomplete Slim interpolation mapping", payload.owner)
      end

      def emit_ruby_filter(body)
        payloads = body.drop(1).filter_map do |node|
          @payloads.fetch(node[2]) if node[0..1] == %i[slim interpolate]
        end
        return if payloads.empty?

        owner = Span.new(payloads.first.owner.start_offset, payloads.last.owner.end_offset)
        text = payloads.map(&:text).join
        pieces = payloads.flat_map(&:pieces)
        # RubyEngine terminates its raw block with a newline, including heredocs.
        emit_code(MappedCode.new(text, pieces, owner), separator: "\n;\n")
      end

      # Parse the assembled program to retain Ruby local/control context, then
      # check that a later Slim expression did not accidentally complete an
      # earlier one. Block headers may span their bodies, but their operands may
      # not consume Ruby from the next Slim expression.
      def check_boundaries
        nodes = []
        queue = [ast]
        until queue.empty?
          node = queue.pop
          nodes << node
          queue.concat(node.compact_child_nodes)
        end
        @boundaries.each do |boundary|
          candidates = nodes.select do |node|
            !node.is_a?(Prism::ProgramNode) && !node.is_a?(Prism::StatementsNode) &&
              boundary.span.cover?(node.location.start_offset)
          end
          crossed = if boundary.header
                      header_crosses?(candidates, boundary.span)
                    else
                      candidates.any? { |node| node.location.end_offset > boundary.span.end_offset }
                    end
          diagnose("Incomplete Ruby expression crosses a Slim expression boundary", boundary.owner) if crossed
        end
      end

      def header_crosses?(nodes, span)
        nodes.any? do |node|
          expressions = case node
                        when Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode,
                             Prism::CaseNode, Prism::CaseMatchNode
                          [node.predicate]
                        when Prism::ForNode then [node.collection]
                        when Prism::WhenNode then node.conditions
                        when Prism::InNode then [node.pattern]
                        when Prism::RescueNode then node.exceptions + [node.reference]
                        else []
                        end
          expressions.compact.any? { |expression| expression.location.end_offset > span.end_offset }
        end
      end

      def unsupported(node)
        span = @owners[node] || Span.new(0, @source.bytesize)
        diagnose("Unsupported Slim construct: #{node.first(2).join(" ")}", span)
      end

      def diagnose(message, span)
        @diagnostics << ProjectionDiagnostic.new(message.freeze, span, 1)
      end
    end
  end
end
