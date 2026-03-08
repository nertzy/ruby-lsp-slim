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

    assert document.parse!
    refute_nil document.ast
    assert_kind_of Prism::ProgramNode, document.ast
  end

  def test_language_id_returns_slim
    document = create_document("h1 Hello")

    assert_equal :slim, document.language_id
  end

  def test_no_syntax_error_for_valid_ruby
    source = "- x = 1\n= x.to_s\n"
    document = create_document(source)
    document.parse!

    refute document.syntax_error?
  end

  def test_host_language_source_populated
    source = "h1 Hello\n- x = 1\n"
    document = create_document(source)
    document.parse!

    refute_empty document.host_language_source
    assert_equal source.length, document.host_language_source.length
  end

  def test_is_a_erb_document
    document = create_document("h1 Hello")

    assert_kind_of RubyLsp::ERBDocument, document
  end

  def test_parse_with_control_flow
    source = read_fixture("control_flow.slim")
    document = create_document(source)

    assert document.parse!
    refute_nil document.ast
  end

  def test_parse_with_interpolation
    source = read_fixture("interpolation.slim")
    document = create_document(source)

    assert document.parse!
    refute_nil document.ast
  end

  def test_parse_with_ruby_filter
    source = read_fixture("ruby_filter.slim")
    document = create_document(source)

    assert document.parse!
    refute_nil document.ast
  end

  def test_inside_host_language
    source = "h1 Hello\n- x = 1\n"
    document = create_document(source)
    document.parse!

    # "h" at position 0 should be host language
    assert document.inside_host_language?(0)

    # Ruby code position (after "- ") should not be host language
    # "- x = 1" starts at position 9 (after "h1 Hello\n")
    # "x" is at position 11
    refute document.inside_host_language?(11)
  end

  private

  def create_document(source)
    uri = URI::Generic.from_path(path: "/fake/test.slim")
    RubyLsp::RubyLspSlim::SlimDocument.new(
      source: source,
      version: 1,
      uri: uri,
      global_state: @global_state,
    )
  end
end
