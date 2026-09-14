# frozen_string_literal: true

require "test_helper"

class SlimDocumentTest < Minitest::Test
  include TestHelper

  def setup
    @global_state = RubyLsp::GlobalState.new
    @global_state.apply_options({})
  end

  def test_parse_produces_ast
    source = "- x = 1\n- y = x + 2\n"
    document = create_document(source)

    # Constructor already calls parse!
    refute_nil document.ast
    assert_kind_of Prism::ProgramNode, document.ast
  end

  def test_only_generated_document_uses_the_erb_definition_fallback
    document = create_document("h1 Hello")

    assert_equal :slim, document.language_id
    assert_equal :erb, document.generated_document.language_id
    refute document.generated_document.should_index?
  end

  def test_no_syntax_error_for_valid_ruby
    source = "- x = 1\n= x.to_s\n"
    document = create_document(source)

    refute document.syntax_error?
  end

  def test_original_source_is_retained_separately_from_generated_ruby
    source = "h1 Hello\n- x = 1\n"
    document = create_document(source)

    assert_equal source, document.source
    assert_equal "x = 1", document.ast.statements.body.first.location.slice
    refute_includes document.generated_document.source, "h1 Hello"
  end

  def test_facade_is_not_an_erb_document_and_cannot_delegate_slim_as_html
    document = create_document("h1 Hello")

    assert_kind_of RubyLsp::Document, document
    refute_kind_of RubyLsp::ERBDocument, document
    assert_kind_of RubyLsp::RubyDocument, document.generated_document
  end

  def test_parse_with_control_flow
    source = read_fixture("control_flow.slim").delete_suffix("- end\n")
    document = create_document(source)

    refute_nil document.ast
    assert_kind_of Prism::ProgramNode, document.ast
  end

  def test_explicit_end_is_rejected_just_as_it_is_by_slim
    source = read_fixture("control_flow.slim")
    error = assert_raises(Temple::FilterError) { Slim::Engine.new.call(source) }
    document = create_document(source)

    assert document.syntax_error?
    assert_nil document.ast
    assert_includes document.projection.diagnostics.map(&:message), error.message
  end

  def test_indentation_based_if_else_closes_on_dedent
    source = <<~SLIM
      - if visible
        = title
      - else
        = fallback
      = footer
    SLIM
    document = create_document(source)

    assert_equal 2, document.ast.statements.body.length
    conditional, footer = document.ast.statements.body
    assert_if_else_body(conditional, source)
    footer = named_node(footer, Prism::CallNode, :footer)
    assert_instance_of Prism::CallNode, footer
    assert_equal :footer, footer.name
    assert_source_location(footer.location, source, "footer", line: 5, column: 2)
    refute document.syntax_error?, "Valid indentation-based if/else should parse without errors"
  end

  def test_indentation_based_if_else_closes_at_eof
    source = <<~SLIM.chomp
      - if visible
        = title
      - else
        = fallback
    SLIM
    document = create_document(source)

    assert_equal 1, document.ast.statements.body.length
    assert_if_else_body(document.ast.statements.body.first, source)
    refute document.syntax_error?, "Valid indentation-based if/else should close at EOF"
  end

  def test_indentation_based_each_closes_on_dedent
    source = <<~SLIM
      - items.each do |item|
        = item
      = footer
    SLIM
    document = create_document(source)

    assert_equal 2, document.ast.statements.body.length
    each_call, footer = document.ast.statements.body
    assert_each_body(each_call, source)
    footer = named_node(footer, Prism::CallNode, :footer)
    assert_instance_of Prism::CallNode, footer
    assert_equal :footer, footer.name
    assert_source_location(footer.location, source, "footer", line: 3, column: 2)
    refute document.syntax_error?, "Valid indentation-based each block should parse without errors"
  end

  def test_indentation_based_each_closes_at_eof
    source = <<~SLIM.chomp
      - items.each do |item|
        = item
    SLIM
    document = create_document(source)

    assert_equal 1, document.ast.statements.body.length
    assert_each_body(document.ast.statements.body.first, source)
    refute document.syntax_error?, "Valid indentation-based each block should close at EOF"
  end

  def test_parse_with_interpolation
    source = read_fixture("interpolation.slim")
    document = create_document(source)

    refute_nil document.ast
    assert_kind_of Prism::ProgramNode, document.ast
  end

  def test_parse_with_ruby_filter
    source = read_fixture("ruby_filter.slim")
    document = create_document(source)

    refute_nil document.ast
    assert_kind_of Prism::ProgramNode, document.ast
  end

  def test_inside_host_language
    source = "h1 Hello\n- x = 1\n"
    document = create_document(source)

    # "h" at position 0 should be host language
    assert document.inside_host_language?(0)

    # Ruby code position (after "- ") should not be host language
    # "- x = 1" starts at position 9 (after "h1 Hello\n")
    # "x" is at position 11
    refute document.inside_host_language?(11)
  end

  def test_parse_recovers_from_errors
    # Even with broken content, the document should not crash
    source = "- x = \#{broken\n= unclosed(\n"
    document = create_document(source)

    assert document.syntax_error?
    assert_nil document.ast
    assert_nil document.generated_document
  end

  def test_snapshot_owns_current_fold_regions_and_edits_invalidate_them
    document = create_document("div\n  section\n    p Hello\np Tail\n")

    assert_equal([[0, 2], [1, 2]], document.snapshot.fold_regions.map { |region| [region.start_line, region.end_line] })
    document.push_edits([{ text: "p Alone\n" }], version: 2)
    assert_empty document.snapshot.fold_regions
  end

  def test_edits_invalidate_original_version_caches_and_generated_ast
    document = create_document("- title = 1\n= title\n")
    original_ast = document.ast
    document.cache_set("probe", "cached")
    document.push_edits([{ text: "= user.\n" }], version: 2)

    assert_equal 2, document.version
    assert_equal "= user.\n", document.source
    assert_equal RubyLsp::Document::EMPTY_CACHE, document.cache_get("probe")
    2.times do
      assert document.syntax_error?
      assert_nil document.ast
      assert_nil document.generated_document
    end
    refute document.parse!, "Failed input is parsed once per version"

    document.push_edits([{ text: "= title\n" }], version: 3)
    refute document.syntax_error?
    refute_same original_ast, document.ast
    assert_equal :title, named_node(document.ast.statements.body.first, Prism::CallNode, :title).name
  end

  def test_sequential_unicode_edits_and_full_replacement_are_original_coordinates
    document = create_document("| é😀\r\n= title\r\n")
    document.push_edits([
                          { range: { start: { line: 0, character: 3 }, end: { line: 0, character: 5 } }, text: "ok" },
                          { range: { start: { line: 1, character: 2 }, end: { line: 1, character: 7 } }, text: "name" }
                        ], version: 2)
    assert_equal "| éok\r\n= name\r\n", document.source
    document.push_edits([
                          { text: "= name" },
                          { range: { start: { line: 0, character: 6 }, end: { line: 0, character: 6 } }, text: ".to_s" }
                        ], version: 3)
    assert_equal "= name.to_s", document.source
    refute document.syntax_error?
  end

  def test_invalid_edit_batch_is_not_partially_applied
    document = create_document("= name")
    assert_raises(RubyLsp::RubyLspSlim::InvalidPosition) do
      document.push_edits([
                            { text: "= changed" },
                            { range: { start: { line: 9, character: 0 }, end: { line: 9, character: 1 } }, text: "x" }
                          ], version: 2)
    end
    assert_equal "= name", document.source
    assert_equal 1, document.version
  end

  def test_unexpected_projection_failure_is_logged_once_without_reusing_ast
    document = create_document("= name")
    document.push_edits([{ text: "= changed" }], version: 2)
    failure = ->(*) { raise "projection bug" }
    _output, error = capture_io do
      RubyLsp::RubyLspSlim::Projection.stub(:new, failure) do
        2.times do
          assert document.syntax_error?
          assert_nil document.ast
        end
      end
    end
    assert_equal 1, error.scan("projection bug").length
    assert_equal "projection bug", document.failure.message
  end

  private

  def assert_if_else_body(conditional, source)
    assert_instance_of Prism::IfNode, conditional
    assert_instance_of Prism::CallNode, conditional.predicate
    assert_equal :visible, conditional.predicate.name
    assert_source_location(conditional.predicate.location, source, "visible", line: 1, column: 5)

    assert_equal 1, conditional.statements.body.length
    title = named_node(conditional.statements.body.first, Prism::CallNode, :title)
    assert_instance_of Prism::CallNode, title
    assert_equal :title, title.name
    assert_source_location(title.location, source, "title", line: 2, column: 4)

    assert_instance_of Prism::ElseNode, conditional.subsequent
    assert_equal 1, conditional.subsequent.statements.body.length
    fallback = named_node(conditional.subsequent.statements.body.first, Prism::CallNode, :fallback)
    assert_instance_of Prism::CallNode, fallback
    assert_equal :fallback, fallback.name
    assert_source_location(fallback.location, source, "fallback", line: 4, column: 4)
  end

  def assert_each_body(each_call, source)
    assert_instance_of Prism::CallNode, each_call
    assert_equal :each, each_call.name
    assert_source_location(each_call.message_loc, source, "each", line: 1, column: 8)
    assert_instance_of Prism::CallNode, each_call.receiver
    assert_equal :items, each_call.receiver.name
    assert_source_location(each_call.receiver.location, source, "items", line: 1, column: 2)

    assert_instance_of Prism::BlockNode, each_call.block
    assert_equal [:item], each_call.block.locals
    assert_equal 1, each_call.block.body.body.length
    item = named_node(each_call.block.body.body.first, Prism::LocalVariableReadNode, :item)
    assert_instance_of Prism::LocalVariableReadNode, item
    assert_equal :item, item.name
    assert_source_location(item.location, source, "item", line: 2, column: 4)
  end

  # Search only within the asserted owning statement/block. Generated expression
  # wrappers may change, but dedent, block locals and copied source ranges may not.
  def named_node(root, type, name)
    queue = [root]
    until queue.empty?
      node = queue.shift
      return node if node.is_a?(type) && node.name == name

      queue.concat(node.child_nodes.compact)
    end
    flunk "Expected #{type} named #{name} in its owning statement"
  end

  def assert_source_location(location, source, text, line:, column:)
    assert_equal text, location.slice
    original = @document.projection.map.exact_span(RubyLsp::RubyLspSlim::Span.from_location(location))
    assert_equal source.lines.take(line - 1).sum(&:bytesize) + column, original.start_offset
    assert_equal text.bytesize, original.length
    assert_equal text, source.byteslice(original.range)
    positions = RubyLsp::RubyLspSlim::Positions.new(source, Encoding::UTF_8)
    assert_equal({ line: line - 1, character: column }, positions.position(original.start_offset))
  end

  def create_document(source)
    uri = URI::Generic.from_path(path: "/fake/test.slim")
    @document = RubyLsp::RubyLspSlim::SlimDocument.new(
      source: source,
      version: 1,
      uri: uri,
      global_state: @global_state
    )
  end
end
