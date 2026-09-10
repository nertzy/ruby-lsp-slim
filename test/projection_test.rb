# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_lsp/ruby_lsp_slim/projection"

class ProjectionTest < Minitest::Test
  Core = RubyLsp::RubyLspSlim

  def test_if_else_and_each_scope_at_dedent_and_eof
    ["", "\n"].each do |ending|
      source = "- if visible\n  = title\n- else\n  = fallback\n= footer#{ending}"
      projection = valid_projection(source)
      conditional, wrapped_footer = projection.ast.statements.body
      footer = output(wrapped_footer)
      assert_instance_of Prism::IfNode, conditional
      assert_equal :footer, footer.name
      assert_equal :title, output(conditional.statements.body.first).name
      assert_equal :fallback, output(conditional.subsequent.statements.body.first).name
      assert_original(projection, footer.location, "footer")
      assert_equal 1, valid_projection(source.sub(/\n= footer\n?\z/, "")).ast.statements.body.length

      each = valid_projection("- items.each do |item|\n  = item\n= footer#{ending}")
      assert_equal 2, each.ast.statements.body.length
      assert_instance_of Prism::LocalVariableReadNode, output(each.ast.statements.body.first.block.body.body.first)
    end
  end

  def test_context_sensitive_division_break_and_header_comments
    source = "- xs = [1]\n- x = 4\n- xs.each do |item| # note\n  - if x / 2 > item # division\n    - break\n= footer"
    projection = valid_projection(source)
    assert_equal :footer, output(projection.ast.statements.body.last).name
    assert nodes(projection).any?(Prism::BreakNode)
    assert(nodes(projection).any? { |node| node.is_a?(Prism::CallNode) && node.name == :/ })
  end

  def test_general_slim_controls
    sources = [
      "- if a\n  = one\n- elsif b\n  = two\n- else\n  = three",
      "- unless a\n  = one\n- else\n  = two",
      "- case value\n- when 1\n  = one\n- else\n  = two",
      "- case value\n  - when 1\n    = one\n  - else\n    = two",

      "- while ready\n  = work",
      "- until ready\n  = work",
      "- for item in items\n  = item",
      "- begin\n  = work\n- rescue Error => error\n  = error\n- else\n  = good\n- ensure\n  = cleanup"
    ]
    sources.each do |source|
      assert native_valid?("#{source}\n= footer"), source
      projection = valid_projection("#{source}\n= footer")
      assert_equal 2, projection.ast.statements.body.length, source
      assert_equal :footer, output(projection.ast.statements.body.last).name
    end
  end

  def test_explicit_and_implicit_helper_blocks_including_static_only_body
    ["= capture do |item|\n  = item", "= capture\n  p literal", "p ==<> capture do\n  = inner"].each do |source|
      projection = valid_projection("#{source}\n= footer")
      assert_instance_of Prism::BlockNode, output(projection.ast.statements.body.first).block
      assert_equal :footer, output(projection.ast.statements.body.last).name
    end
  end

  def test_outputs_attributes_and_interpolation
    source = "p.notice ==<> title\n" \
             "p(class=classes title=\"Hi \#{name}\" *attrs) == raw_html\n" \
             "p name \#{name} \#{{raw_html}} \\\#{literal}\n"
    projection = valid_projection(source)
    calls = nodes(projection).grep(Prism::CallNode)
    assert_equal %i[title classes name attrs raw_html name raw_html], calls.map(&:name)
    calls.each { |call| assert_original(projection, call.message_loc, call.name.to_s) }
    refute_includes projection.ruby, "literal"
  end

  def test_comments_and_text_bodies_do_not_become_ruby
    source = "/ ignored\n  = hidden\n| literal\n  = not_ruby \#{name}\n" \
             "/! visible \#{comment_name}\n<p>\#{inline}</p>\n= footer"
    projection = valid_projection(source)
    assert_equal %i[name comment_name inline footer], nodes(projection).grep(Prism::CallNode).map(&:name)
  end

  def test_ruby_filter_is_raw_ruby_including_definitions_and_string_interpolation
    source = "ruby:\r\n  def helper(value)\r\n    \"\#{value}\"\r\n  end\r\n\r\n  x = 1\r\n= helper(x)"
    projection = valid_projection(source)
    assert_instance_of Prism::DefNode, projection.ast.statements.body.first
    assert_instance_of Prism::LocalVariableWriteNode, projection.ast.statements.body[1]
    assert_equal :helper, output(projection.ast.statements.body.last).name
    assert(nodes(projection).any? { |node| node.is_a?(Prism::LocalVariableReadNode) && node.name == :value })
  end

  def test_multiline_normalization_and_mapping
    source = "| é😀\r\n- x = \"hello\\\r\n    world\"\r\n= helper(x,\r\n  x)"
    projection = valid_projection(source)
    assert_equal "helloworld", projection.ast.statements.body.first.value.unescaped
    call = output(projection.ast.statements.body.last)
    assert_original(projection, call.message_loc, "helper")
    call.arguments.arguments.each { |node| assert_original(projection, node.location, "x") }
    assert_raises(Core::UnsafeEdit) { projection.map.edit_span(Core::Span.from_location(call.location)) }
    projection.map.segments.each do |segment|
      next unless segment.original

      assert_equal source.byteslice(segment.original.range), projection.ruby.byteslice(segment.generated.range)
    end
  end

  def test_normalized_quoted_interpolation_maps_duplicate_expressions
    source = "p title=\"Hi \#{user.name} \\\r\n  again \#{user.name}\" = footer"
    projection = valid_projection(source)
    names = nodes(projection).grep(Prism::CallNode).select { |node| node.name == :name }
    spans = names.map { |node| projection.map.exact_span(Core::Span.from_location(node.location)) }
    assert_equal 2, spans.length
    refute_equal spans.first, spans.last
    spans.each { |span| assert_equal "user.name", source.byteslice(span.range) }
  end

  def test_expected_bad_input_returns_current_diagnostics_or_prism_errors
    ["p(class=", "= helper,", "= helper \\", "- if\n  = body\n= footer", "- x =\n= footer",
     "= user.\n= footer", "- if ready\n    = one\n  = two", "= broken(", "- end",
     "markdown:\n  text", "- def helper\n  = body"].each do |source|
      projection = Core::Projection.new(source)
      refute projection.valid?, source
      assert_equal source, projection.source
      refute_nil projection.ast
      assert projection.parse_result.failure? || projection.diagnostics.any? { |item| item.severity == 1 }, source
      projection.diagnostics.each do |diagnostic|
        assert_operator diagnostic.span.start_offset, :>=, 0
        assert_operator diagnostic.span.end_offset, :<=, source.bytesize
      end
    end
  end

  def test_invalid_encoding_is_an_input_diagnostic
    source = "= \xFF".dup.force_encoding(Encoding::UTF_8)
    projection = Core::Projection.new(source)
    refute projection.valid?
    assert_equal source, projection.source
    refute_empty projection.diagnostics
    assert_equal "", projection.ruby
  end

  def test_prism_errors_are_retained_not_duplicated_as_projection_diagnostics
    projection = Core::Projection.new("= 1 + * 2\n= footer")
    refute projection.valid?
    assert projection.parse_result.failure?
    assert_empty projection.diagnostics
    assert(nodes(projection).grep(Prism::CallNode).any? { |node| node.name == :footer })
    assert Core::Projection.new("= footer").valid?
  end

  def test_tag_output_whitespace_matrix_and_static_attributes
    sources = tag_output_sources
    sources = sources.select { |source| native_valid?(source) } if slim4?
    refute_empty sources
    sources.each do |source|
      assert native_valid?(source), source
      projection = valid_projection(source)
      call = output(projection.ast.statements.body.first)
      assert_equal :title, call.name
      assert_original(projection, call.message_loc, "title")
      original = source.b.index("title")
      assert_equal original, projection.map.original_offset(projection.map.generated_offset(original))
    end
  end

  def test_native_unsupported_slim4_tag_output_has_diagnostics
    unsupported = tag_output_sources.reject { |source| native_valid?(source) }
    slim4? ? refute_empty(unsupported) : assert_empty(unsupported)
    unsupported.each { |source| assert_invalid_projection(source) }
  end

  def test_pattern_matching_follows_native_slim_capabilities
    ["- case value\n- in {name:}\n  = name\n- else\n  = other",
     "- case value\n  - in {name:}\n    = name\n  - else\n    = other"].each do |source|
      source += "\n= footer"
      if slim4? && !native_valid?(source)
        assert_invalid_projection(source)
      else
        assert native_valid?(source), source
        projection = valid_projection(source)
        assert_equal 2, projection.ast.statements.body.length
        assert_equal :footer, output(projection.ast.statements.body.last).name
      end
    end
  end

  def test_embedded_filter_pass_through_preserves_attributes
    content = [:multi, [:slim, :interpolate, "x = 1"]]
    attributes = [:html, :attrs, [:html, :attr, "class", [:static, "preserved"]]]
    [Core::Projection::DoInserter, Core::Projection::EndInserter].each do |type|
      filter = type.new({}.compare_by_identity, {}.compare_by_identity)
      result = filter.on_slim_embedded("ruby", content, attributes)
      assert_equal [:slim, :embedded, "ruby", content, attributes], result
      assert_same attributes, result.last
    end
  end

  def test_control_and_helper_output_have_exact_original_spans
    source = "- x = 42\n= link_to \"Home\", root_path\n== raw_html\nh1= title\n"
    assert native_valid?(source)
    projection = valid_projection(source)
    assignment = projection.ast.statements.body.first
    assert_instance_of Prism::LocalVariableWriteNode, assignment
    assert_original(projection, assignment.name_loc, "x")
    assert_equal Core::Span.new(2, 3), projection.map.exact_span(Core::Span.from_location(assignment.name_loc))
    calls = nodes(projection).grep(Prism::CallNode)
    assert_equal %i[link_to raw_html title root_path], calls.map(&:name)
    calls.each { |call| assert_original(projection, call.message_loc, call.name.to_s) }
  end

  def test_equals_in_plain_tag_text_is_not_ruby
    [" ", "  ", "\t", " \t ", "\f", "\v"].each do |space|
      ["=", "=="].each do |operator|
        source = "p#{space}literal text #{operator} value\n"
        assert native_valid?(source), source
        projection = valid_projection(source)
        assert_equal source, projection.source
        assert_equal "", projection.ruby
        assert_empty projection.map.segments
      end
    end
  end

  def test_trailing_tag_whitespace_does_not_consume_the_next_line
    source = "p \t\n= title\n"
    assert native_valid?(source)
    projection = valid_projection(source)
    call = output(projection.ast.statements.body.first)
    assert_original(projection, call.location, "title")
    assert_equal Core::Span.new(6, 11), projection.map.exact_span(Core::Span.from_location(call.location))
  end

  def test_ruby_filter_dedent_leaves_html_as_host_text
    source = "ruby:\n  x = 1\n  y = 2\nh1 Hello\n"
    assert native_valid?(source)
    projection = valid_projection(source)
    assert_equal %i[x y], projection.ast.statements.body.map(&:name)
    refute_includes projection.ruby, "h1"
    refute_includes projection.ruby, "Hello"
  end

  def test_index_interpolation_pipe_text_and_unclosed_interpolation
    ["p \#{hash[:key]}\n", "| Some text \#{hash[:key]}\n"].each do |source|
      assert native_valid?(source), source
      projection = valid_projection(source)
      call = nodes(projection).grep(Prism::CallNode).find { |node| node.name == :[] }
      assert_original(projection, call.location, "hash[:key]")
      assert_raises(Core::UnmappedPosition) { projection.map.generated_offset(0) }
    end
    source = "p \#{user.name\n"
    assert native_valid?(source)
    projection = valid_projection(source)
    assert_equal source, projection.source
    assert_equal "", projection.ruby
  end

  def test_initial_indentation_and_arithmetic_backslash_continuation
    ["  - items.each do |item|\n", "- x = 1 + \\\n  2\n"].each do |source|
      assert native_valid?(source), source
      projection = valid_projection(source)
      assert_equal 1, projection.ast.statements.body.length
    end
    projection = valid_projection("- x = 1 + \\\n  2\n")
    addition = projection.ast.statements.body.first.value
    assert_equal :+, addition.name
    assert_original(projection, addition.receiver.location, "1")
    assert_original(projection, addition.arguments.arguments.first.location, "2")
  end

  def test_inline_definitions_and_ruby_filter_heredoc
    projection = valid_projection("- def helper(x) = x\n= helper(1)")
    assert_instance_of Prism::DefNode, projection.ast.statements.body.first
    projection = valid_projection("ruby:\n  text = <<~TEXT\n    hello\n  TEXT\n= text")
    assert_equal "hello\n", projection.ast.statements.body.first.value.unescaped
  end

  def test_unsupported_embedded_engine_is_localized_inside_block_expansion
    source = "= before\np: markdown:\n  text\n= after"
    projection = Core::Projection.new(source)
    refute projection.valid?
    diagnostic = projection.diagnostics.first
    assert_equal "Unsupported Slim construct: slim embedded", diagnostic.message
    assert_equal "p: markdown:\n  text", source.byteslice(diagnostic.span.range)
    assert_equal(%i[before after], projection.ast.statements.body.map { |node| output(node).name })
  end

  def test_warnings_do_not_invalidate_a_projection
    projection = valid_projection("- 1")
    refute_empty projection.parse_result.warnings
    assert_empty projection.diagnostics
  end

  def test_slim_syntax_failure_produces_a_safe_empty_current_projection
    projection = Core::Projection.new("= before\np(class=\n= after")
    refute projection.valid?
    assert_equal "", projection.ruby
    assert_empty projection.map.segments
    assert_equal "Invalid empty attribute", projection.diagnostics.first.message
    assert_equal Core::Span.new(17, 17), projection.diagnostics.first.span
    refute projection.parse_result.failure?
    assert valid_projection("= before\np(class=classes)\n= after").ast
  end

  def test_insertion_at_an_implicit_helper_header_has_original_affinity
    projection = valid_projection("= capture\n  p text")
    offset = projection.map.generated_offset(9)
    assert_equal Core::Span.new(9, 9), projection.map.edit_span(Core::Span.new(offset, offset))
    assert_raises(Core::UnsafeEdit) { projection.map.edit_span(Core::Span.new(offset + 2, offset + 2)) }
  end

  def test_every_truncated_prefix_returns_a_current_result
    sources = [
      "p(class=(helper(1,\r\n  2)) title=\"Hi \#{user.name}\") = footer",
      "- items.each do |item|\n  p = item.name\n= footer",
      "ruby:\n  def helper(value)\n    value.to_s\n  end\n= helper(1)",
      "| text \#{helper({key: value})}\n  more \#{{raw}}\n= footer"
    ]
    sources.each do |source|
      (0..source.length).each do |length|
        current = source[0, length]
        projection = Core::Projection.new(current)
        assert_equal current, projection.source
        assert_instance_of Prism::ProgramNode, projection.ast
        projection.diagnostics.each do |diagnostic|
          assert_operator diagnostic.span.start_offset, :>=, 0
          assert_operator diagnostic.span.end_offset, :<=, current.bytesize
        end
      end
    end
  end

  def test_output_value_context_matches_native_slim_errors
    sources = [
      "= return", "== return value", "p = return", "p(foo=(return))", "| \#{return}",
      "= foo # comment", "| \#{foo # comment}", "= BEGIN { foo }",
      "= return value\n  = body\n= footer",
      "- xs.each do\n  = break\n", "- xs.each do\n  = next\n"
    ]
    sources.each do |source|
      native = Prism.parse_lex(Slim::Engine.new.call(source))
      assert native.failure?, "The native oracle must reject #{source.inspect}"
      projection = Core::Projection.new(source)
      refute projection.valid?, source
      assert projection.parse_result.failure?, source
      assert_empty projection.diagnostics
    end
  end

  def test_native_attribute_sorting_changes_local_binding_and_keeps_source_locations
    source = "p title=b class=(b=1)"
    native = Prism.parse_lex(Slim::Engine.new.call(source))
    refute native.failure?
    assert(ast_nodes(native.value.first).any? { |node| node.is_a?(Prism::LocalVariableReadNode) && node.name == :b })
    projection = valid_projection(source)
    original = source.index("b")
    node = nodes(projection).find do |candidate|
      candidate.is_a?(Prism::LocalVariableReadNode) && candidate.name == :b &&
        projection.map.exact_span(Core::Span.from_location(candidate.location)).start_offset == original
    end
    assert_instance_of Prism::LocalVariableReadNode, node
    assert_original(projection, node.location, "b")
    assert_operator projection.map.generated_offset(source.index("b=1")), :<,
                    projection.map.generated_offset(original)
  end

  def test_native_attribute_merging_rejects_duplicate_ids
    source = "= before\np id=a id=b\n= after"
    error = assert_raises(Temple::FilterError) { Slim::Engine.new.call(source) }
    projection = Core::Projection.new(source)
    refute projection.valid?
    assert_equal error.message, projection.diagnostics.first.message
    assert_equal "p id=a id=b", source.byteslice(projection.diagnostics.first.span.range)
  end

  def test_native_class_merging_preserves_stable_grouped_evaluation_order
    source = "p class=(a=1) title=a class=(a=2)"
    native = Prism.parse_lex(Slim::Engine.new.call(source))
    refute native.failure?
    projection = valid_projection(source)
    ordered = nodes(projection).select do |node|
      [Prism::LocalVariableWriteNode, Prism::LocalVariableReadNode].include?(node.class) && node.name == :a
    end
    ordered.sort_by! { |node| node.location.start_offset }
    assert_equal [Prism::LocalVariableWriteNode, Prism::LocalVariableWriteNode, Prism::LocalVariableReadNode],
                 ordered.map(&:class)
    assert_equal(["a=1", "a=2", "a"], ordered.map { |node| node.location.slice })
    ordered.each { |node| assert_original(projection, node.location, node.location.slice) }
  end

  def test_native_splat_attribute_path_keeps_source_order
    ["p title=b class=(b=1) *attrs", "p title=b class=(b=1) data=attrs"].each do |source|
      native = Prism.parse_lex(Slim::Engine.new.call(source))
      refute native.failure?
      assert(ast_nodes(native.value.first).any? { |node| node.is_a?(Prism::CallNode) && node.name == :b })
      projection = valid_projection(source)
      call = nodes(projection).find { |node| node.is_a?(Prism::CallNode) && node.name == :b }
      assert_original(projection, call.location, "b")
    end
  end

  def test_fragment_start_keeps_end_marker_out_of_column_zero
    ["= __END__", "- __END__", "ruby:\n  __END__"].each do |prefix|
      source = "#{prefix}\n- After = 1\n"
      native = Prism.parse_lex(Slim::Engine.new.call(source))
      refute native.failure?
      assert(ast_nodes(native.value.first).any? { |node| node.is_a?(Prism::ConstantWriteNode) && node.name == :After })
      projection = valid_projection(source)
      assignment = nodes(projection).find { |node| node.is_a?(Prism::ConstantWriteNode) && node.name == :After }
      assert_instance_of Prism::ConstantWriteNode, assignment
      assert_original(projection, assignment.name_loc, "After")
      assert_includes projection.ruby, "__END__"
    end
  end

  def test_fragment_comments_cannot_become_encoding_directives
    %w[us-ascii iso-8859-1 binary not-an-encoding].each do |encoding|
      source = "- # coding: #{encoding}\n= café"
      native = Prism.parse_lex(Slim::Engine.new.call(source))
      refute native.failure?
      projection = valid_projection(source)
      assert_includes nodes(projection).grep(Prism::CallNode).map(&:name), :café
      assert_original(projection, nodes(projection).grep(Prism::CallNode).last.location, "café")
      assert_includes projection.ruby, "# coding: #{encoding}"
    end
  end

  def test_fragment_comment_does_not_change_string_literal_flags
    source = "- # frozen_string_literal: true\n= \"text\""
    native = Prism.parse_lex(Slim::Engine.new.call(source))
    expected = ast_nodes(native.value.first).grep(Prism::StringNode).find { |node| node.unescaped == "text" }
    projection = valid_projection(source)
    actual = nodes(projection).grep(Prism::StringNode).find { |node| node.unescaped == "text" }
    assert_equal expected.frozen?, actual.frozen?
    refute actual.frozen?
    assert_equal native.magic_comments.map(&:key), projection.parse_result.magic_comments.map(&:key)
  end

  def test_internal_ruby_filter_marker_is_not_erased_or_repaired
    source = "ruby:\n  x = 1\n  __END__\n- After = 1"
    native = Prism.parse_lex(Slim::Engine.new.call(source))
    projection = valid_projection(source)
    refute native.failure?
    refute ast_nodes(native.value.first).any?(Prism::ConstantWriteNode)
    refute nodes(projection).any?(Prism::ConstantWriteNode)
    assert_includes projection.ruby, "\n__END__\n"
  end

  def test_value_wrapper_errors_have_original_domain_read_mappings
    ["= return", "= café # comment\r\n= footer"].each do |source|
      projection = Core::Projection.new(source)
      refute projection.valid?
      refute_empty projection.parse_result.errors
      positions = Core::Positions.new(source, Encoding::UTF_16LE)
      projection.parse_result.errors.each do |error|
        original = projection.map.read_range(Core::Span.from_location(error.location)).span
        assert_operator original.start_offset, :>=, 0
        assert_operator original.end_offset, :<=, source.bytesize
        assert positions.position(original.start_offset)
        assert positions.position(original.end_offset)
      end
    end
  end

  def test_empty_source_and_unclosed_interpolation_are_not_exceptions
    assert valid_projection("").ast
    assert valid_projection('p #{unfinished').ast
  end

  private

  def slim4?
    Gem::Version.new(Slim::VERSION) < Gem::Version.new("5.0")
  end

  def native_valid?(source)
    Prism.parse_lex(Slim::Engine.new.call(source)).success?
  rescue Slim::Parser::SyntaxError, Temple::FilterError
    false
  end

  def tag_output_sources
    tags = ["p", "p.notice#message", "p.notice(class=\"a\")"]
    spaces = ["", " ", "  ", "\t", " \t ", "\f", "\v"]
    operators = ["=", "==", "=<", "=>", "=<>", "='", "==<", "==>", "==<>", "=='"]
    tags.product(spaces, operators).map { |tag, space, operator| "#{tag}#{space}#{operator}\t  title\r\n" }
  end

  def assert_invalid_projection(source)
    projection = Core::Projection.new(source)
    refute projection.valid?, source
    structural_error = projection.diagnostics.any? { |diagnostic| diagnostic.severity == 1 }
    assert projection.parse_result.failure? || structural_error, source
  end

  def valid_projection(source)
    Core::Projection.new(source).tap do |projection|
      assert projection.valid?, [source, projection.ruby, projection.diagnostics,
                                 projection.parse_result.errors.map(&:message)].inspect
    end
  end

  def nodes(projection)
    ast_nodes(projection.ast)
  end

  def ast_nodes(ast)
    result = []
    queue = [ast]
    until queue.empty?
      node = queue.shift
      result << node
      queue.concat(node.compact_child_nodes)
    end
    result
  end

  def output(node)
    assert_instance_of Prism::ArrayNode, node
    assert_equal 1, node.elements.length
    parentheses = node.elements.first
    assert_instance_of Prism::ParenthesesNode, parentheses
    assert_equal 1, parentheses.body.body.length
    parentheses.body.body.first
  end

  def assert_original(projection, location, text)
    mapped = projection.map.exact_span(Core::Span.from_location(location))
    assert_equal text, projection.source.byteslice(mapped.range)
  end
end
