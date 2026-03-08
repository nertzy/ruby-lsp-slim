# frozen_string_literal: true

require "test_helper"

class IntegrationTest < Minitest::Test
  include TestHelper

  def setup
    @global_state = RubyLsp::GlobalState.new
    @global_state.apply_options({})
  end

  def test_store_creates_slim_document_for_slim_language_id
    store = RubyLsp::Store.new(@global_state)
    store.singleton_class.prepend(RubyLsp::RubyLspSlim::StorePatch)

    uri = URI::Generic.from_path(path: "/fake/test.slim")
    store.set(uri: uri, source: "- x = 1\n= x.to_s\n", version: 1, language_id: :slim)

    document = store.get(uri)
    assert_kind_of RubyLsp::RubyLspSlim::SlimDocument, document
    assert_kind_of RubyLsp::ERBDocument, document
  end

  def test_store_still_creates_ruby_document_for_ruby
    store = RubyLsp::Store.new(@global_state)
    store.singleton_class.prepend(RubyLsp::RubyLspSlim::StorePatch)

    uri = URI::Generic.from_path(path: "/fake/test.rb")
    store.set(uri: uri, source: "x = 1", version: 1, language_id: :ruby)

    document = store.get(uri)
    assert_kind_of RubyLsp::RubyDocument, document
    refute_kind_of RubyLsp::RubyLspSlim::SlimDocument, document
  end

  def test_store_still_creates_erb_document_for_erb
    store = RubyLsp::Store.new(@global_state)
    store.singleton_class.prepend(RubyLsp::RubyLspSlim::StorePatch)

    uri = URI::Generic.from_path(path: "/fake/test.erb")
    store.set(uri: uri, source: "<%= hello %>", version: 1, language_id: :erb)

    document = store.get(uri)
    assert_kind_of RubyLsp::ERBDocument, document
    refute_kind_of RubyLsp::RubyLspSlim::SlimDocument, document
  end

  def test_locate_node_finds_ruby_in_slim
    source = "- x = 1\n= x.to_s\n"
    uri = URI::Generic.from_path(path: "/fake/test.slim")
    document = RubyLsp::RubyLspSlim::SlimDocument.new(
      source: source,
      version: 1,
      uri: uri,
      global_state: @global_state
    )

    # Position of "x" on line 0, character 2
    node_context = document.locate_node({ line: 0, character: 2 })
    refute_nil node_context
    refute_nil node_context.node
  end

  def test_locate_node_finds_method_call
    source = "= link_to \"Home\", root_path\n"
    uri = URI::Generic.from_path(path: "/fake/test.slim")
    document = RubyLsp::RubyLspSlim::SlimDocument.new(
      source: source,
      version: 1,
      uri: uri,
      global_state: @global_state
    )

    # Position of "link_to" — line 0, character 2
    node_context = document.locate_node({ line: 0, character: 2 })
    refute_nil node_context
    refute_nil node_context.node
  end

  def test_control_flow_produces_expected_ast_nodes
    source = read_fixture("control_flow.slim")
    uri = URI::Generic.from_path(path: "/fake/test.slim")
    document = RubyLsp::RubyLspSlim::SlimDocument.new(
      source: source,
      version: 1,
      uri: uri,
      global_state: @global_state
    )

    ast = document.ast
    # Collect all node types in the AST
    node_types = collect_node_types(ast)

    # Should contain if/else nodes from the control flow
    assert_includes node_types, Prism::IfNode
    # Should contain method calls (current_user, link_to, etc.)
    assert_includes node_types, Prism::CallNode
  end

  def test_ruby_filter_produces_assignment_nodes
    source = read_fixture("ruby_filter.slim")
    uri = URI::Generic.from_path(path: "/fake/test.slim")
    document = RubyLsp::RubyLspSlim::SlimDocument.new(
      source: source,
      version: 1,
      uri: uri,
      global_state: @global_state
    )

    ast = document.ast
    node_types = collect_node_types(ast)

    # Should contain local variable writes from x = 1, y = 2, z = x + y
    assert_includes node_types, Prism::LocalVariableWriteNode
  end

  private

  def collect_node_types(node)
    types = [node.class]
    node.child_nodes.compact.each do |child|
      types.concat(collect_node_types(child))
    end
    types.uniq
  end
end
