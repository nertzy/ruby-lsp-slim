# frozen_string_literal: true

require "test_helper"
require "ruby_lsp/ruby_lsp_slim/request_adapter"

class RequestAdapterTest < Minitest::Test
  Slim = RubyLsp::RubyLspSlim

  def setup
    @state = RubyLsp::GlobalState.new
    @state.apply_options(capabilities: {})
    @uri = URI("untitled:Adapter")
  end

  def test_folding_ranges_are_original_sorted_minimal_objects
    result = perform(document("div\n  section\n    p Hello\np Tail\n"), "foldingRange")

    assert_equal [{ startLine: 0, endLine: 2 }, { startLine: 1, endLine: 2 }], result
  end

  def test_folding_ranges_deduplicate_captured_regions
    document = document("div\n  p Body\n")
    snapshot = document.snapshot
    duplicate = Slim::FoldRegion.new(0, 1)
    captured = snapshot.dup
    captured.fold_regions = [duplicate, duplicate].freeze
    captured.freeze
    document.stub(:snapshot, captured) do
      result = Slim::RequestAdapter.new(@state, document).perform("textDocument/foldingRange", {})
      assert_equal [{ startLine: 0, endLine: 1 }], result
    end
  end

  def test_folding_ranges_work_without_a_generated_document
    ["javascript:\n  alert(1)\n", "css:\n  p {\n    color: red;\n  }\n"].each do |source|
      document = document(source)
      assert_nil document.generated_document
      refute_empty perform(document, "foldingRange")
    end
  end

  def test_folding_ranges_preserve_closed_regions_before_slim_errors
    source = "div\n  p Body\np Tail\np(class=\n"

    assert_equal [{ startLine: 0, endLine: 1 }], perform(document(source), "foldingRange")
  end

  def test_folding_ranges_survive_attributed_filter_mapping_diagnostics
    document = document("javascript(type=\"module\"):\n  alert(1)\n")

    assert_nil document.generated_document
    assert_includes document.projection.diagnostics.map(&:message), "Unsupported Slim source normalization"
    assert_equal [{ startLine: 0, endLine: 1 }], perform(document, "foldingRange")
  end

  def test_folding_ranges_survive_ruby_errors_and_valid_slim_continuations
    assert_equal [{ startLine: 0, endLine: 1 }],
                 perform(document("- if (\n  p Body\np Tail\n"), "foldingRange")
    assert_equal [{ startLine: 0, endLine: 1 }, { startLine: 2, endLine: 4 }],
                 perform(document("div\n  p Body\np Tail\n   p Child\n  p Invalid\n"), "foldingRange")
  end

  def test_folding_ranges_are_empty_for_invalid_or_flat_sources
    ["\xff".b, "p Alone\r", "", "p Alone\n"].each do |source|
      assert_empty perform(document(source), "foldingRange")
    end
  end

  def test_folding_ranges_detect_stale_snapshots
    document = document("div\n  p Body\n")
    adapter = Slim::RequestAdapter.new(@state, document)
    document.push_edits([{ text: "p Alone\n" }], version: 2)

    assert_raises(Slim::RequestAdapter::StaleDocument) do
      adapter.perform("textDocument/foldingRange", {})
    end
    assert_empty perform(document, "foldingRange")
  end

  def test_folding_ranges_reject_unexpected_collector_failures
    document = document("div\n  p Body\n")
    document.push_edits([{ text: "section\n  p Body\n" }], version: 2)
    failure = ->(*) { raise "collector bug" }

    RubyLsp::RubyLspSlim::StructureCollector.stub(:new, failure) do
      _output, _error = capture_io do
        assert_raises(Slim::RequestAdapter::UnsupportedRequest) do
          perform(document, "foldingRange")
        end
      end
    end
  end

  def test_completion_at_eof_maps_replacement_and_resolve_preserves_it
    document = document("- title = 1\n= tit")
    item = perform(document, "completion", position: { line: 1, character: 5 }).find do |entry|
      entry[:label] == "title"
    end

    refute_nil item
    assert_equal range(1, 2, 5), item.dig(:textEdit, :range)
    assert_equal "title", item.dig(:textEdit, :newText)
    assert_equal @uri.to_s, item.dig(:data, :rubyLspSlim, :uri)
    resolved = Slim::RequestAdapter.new(@state, document).resolve_completion(item)
    assert_equal item[:textEdit], resolved[:textEdit]
  end

  def test_highlights_after_unicode_and_dedent_use_editor_positions
    document = document("| é😀\r\n- if visible\r\n  = footer\r\n= format(\"é😀\", footer)")
    highlights = perform(document, "documentHighlight", position: { line: 3, character: 16 })

    assert_equal([range(2, 4, 10), range(3, 16, 22)], highlights.map { |entry| entry[:range] })
  end

  def test_synthetic_end_is_not_a_highlight_in_slim
    document = document("- if visible\n  = title\n")
    highlights = perform(document, "documentHighlight", position: { line: 0, character: 3 })

    assert_equal([range(0, 2, 4)], highlights.map { |entry| entry[:range] })
  end

  def test_symbols_map_name_and_extent
    symbols = perform(document("p Hello\n- Widget = 1\n"), "documentSymbol")

    assert_equal 1, symbols.length
    assert_equal "Widget", symbols.first[:name]
    assert_equal range(1, 2, 8), symbols.first[:selectionRange]
    assert_equal range(1, 2, 12), symbols.first[:range]
  end

  def test_definition_leaves_external_target_in_its_own_document
    target_uri = URI("file:///projection/helpers.rb")
    @state.index.index_single(target_uri, "module Helpers; \"é😀\"; def footer; end; end")
    locations = perform(document("p Host\n= footer\n"), "definition", position: { line: 1, character: 3 })

    assert_equal 1, locations.length
    assert_equal target_uri.to_s, locations.first[:targetUri]
    assert_equal range(0, 27, 33), locations.first[:targetSelectionRange]
  end

  def test_external_definition_rejects_unverified_non_utf16_index_coordinates
    @state.apply_options(capabilities: { general: { positionEncodings: ["utf-8"] } })
    @state.index.index_single(URI("file:///projection/helpers.rb"), "module Helpers; def footer; end; end")

    error = assert_raises(Slim::RequestAdapter::UnsupportedRequest) do
      perform(document("= footer"), "definition", position: { line: 0, character: 3 })
    end
    assert_match(/UTF-16/, error.message)
  end

  def test_native_require_relative_file_start_links_work_in_all_encodings
    @uri = URI("file:///projection/view.slim")
    %w[utf-8 utf-16 utf-32].each do |encoding|
      @state.apply_options(capabilities: { general: { positionEncodings: [encoding] } })
      locations = perform(document("= require_relative \"helpers\""), "definition",
                          position: { line: 0, character: 22 })

      assert_equal [{ uri: "file:///projection/helpers.rb", range: range(0, 0, 0) }], locations, encoding
    end
  end

  def test_hover_uses_generated_cursor_but_returns_native_contents
    @state.index.index_single(URI("file:///projection/widget.rb"), "# A widget.\nclass Widget; end")
    hover = perform(document("p Host\n= Widget\n"), "hover", position: { line: 1, character: 3 })

    assert_includes hover.dig(:contents, :value), "Widget"
    assert_includes hover.dig(:contents, :value), "A widget"
  end

  def test_diagnostics_report_prism_errors_at_original_positions_and_clear
    document = document("p Hello\n= foo(\n")
    report = perform(document, "diagnostic")

    assert_equal "full", report[:kind]
    refute_empty report[:items]
    assert(report[:items].all? { |item| item[:severity] == 1 && item[:range][:start][:line] == 1 })
    document.push_edits([{ text: "p Hello\n= foo()\n" }], version: 2)
    assert_empty perform(document, "diagnostic")[:items]
  end

  def test_invalid_document_has_diagnostics_and_no_semantic_results
    document = document("= user.\n")

    refute_empty perform(document, "diagnostic")[:items]
    assert_nil perform(document, "hover", position: { line: 0, character: 3 })
    assert_empty perform(document, "completion", position: { line: 0, character: 7 })
    assert_empty perform(document, "semanticTokens/full")[:data]
  end

  def test_invalid_source_encoding_and_bare_cr_have_document_diagnostics
    ["\xff".b, "= title\r"].each do |source|
      document = document(source)
      report = perform(document, "diagnostic")

      refute_empty report[:items]
      assert_includes report[:items].first[:message], "UTF-8"
      assert_equal range(0, 0, 0), report[:items].first[:range]
      assert_empty perform(document, "semanticTokens/full")[:data]
      document.push_edits([{ text: "= title" }], version: 2)
      assert_empty perform(document, "diagnostic")[:items]
    end
  end

  def test_host_cursor_is_empty_not_an_internal_error
    document = document("p Host\n= footer\n")

    assert_nil perform(document, "hover", position: { line: 0, character: 2 })
    assert_empty perform(document, "completion", position: { line: 0, character: 2 })
  end

  def test_host_cursor_results_are_rejected_if_the_snapshot_changed
    %w[hover completion definition documentHighlight].each do |method|
      document = document("p Host\n= footer\n")
      adapter = Slim::RequestAdapter.new(@state, document)
      document.push_edits([{ text: "= Widget\n" }], version: 2)

      assert_raises(Slim::RequestAdapter::StaleDocument, method) do
        adapter.perform("textDocument/#{method}", position: { line: 0, character: 2 })
      end
    end
  end

  def test_semantic_full_range_and_delta_are_original_encoded_full_results
    document = document("p Host\n- café = 1\n= format(\"é😀\", café)\n= café\n")
    full = perform(document, "semanticTokens/full")
    tokens = decode_tokens(full[:data])

    assert_includes tokens, [2, 16, 4]
    assert_includes tokens, [3, 2, 4]
    ranged = perform(document, "semanticTokens/range", range: range(3, 0, 6))
    assert_equal [[3, 2, 4]], decode_tokens(ranged[:data])
    document.push_edits([{ text: "p Another host line\np Host\n- café = 1\n= café\n" }], version: 2)
    delta = perform(document, "semanticTokens/full/delta", previousResultId: full[:resultId])
    assert delta.key?(:data)
    refute delta.key?(:edits)
    assert_includes decode_tokens(delta[:data]), [3, 2, 4]
  end

  def test_all_editor_encodings_keep_generated_byte_coordinates
    { "utf-8" => 5, "utf-16" => 4, "utf-32" => 4 }.each do |encoding, length|
      @state.apply_options(capabilities: { general: { positionEncodings: [encoding] } })
      document = document("- café = 1\n= café\n")
      tokens = perform(document, "semanticTokens/full")

      assert_includes decode_tokens(tokens[:data]), [1, 2, length], encoding
      node = find_node(document, Prism::LocalVariableReadNode, :café)
      assert_equal 5, node.location.length
      assert_equal node.location.start_offset, document.generated_document.code_units_cache[node.location.start_offset]
    end
  end

  def test_an_unsafe_additional_edit_drops_the_whole_completion_item
    document = document("- if visible\n  = title\n")
    mapper = Slim::ResponseMapper.new(document.projection, document.encoding)
    title = find_node(document, Prism::CallNode, :title).message_loc
    positions = Slim::Positions.new(document.projection.ruby, Encoding::UTF_8)
    safe = { range: { start: positions.position(title.start_offset), end: positions.position(title.end_offset) },
             newText: "name" }
    ending = document.projection.map.segments.find { |segment| segment.kind == :end }.generated
    synthetic = { range: { start: positions.position(ending.start_offset), end: positions.position(ending.end_offset) },
                  newText: "" }
    items = [{ label: "name", textEdit: safe, additionalTextEdits: [synthetic] }]

    provenance = { uri: @uri, version: 1, document_id: document.document_id }
    assert_equal 1, mapper.completions([{ label: "name", textEdit: safe }], **provenance).length
    assert_empty mapper.completions(items, **provenance)
    assert_equal safe, items.first[:textEdit], "Mapping must not mutate native results"
  end

  def test_definition_origin_is_mapped_independently_from_external_target
    document = document("p Host\n= footer\n")
    mapper = Slim::ResponseMapper.new(document.projection, document.encoding)
    location = find_node(document, Prism::CallNode, :footer).message_loc
    positions = Slim::Positions.new(document.projection.ruby, Encoding::UTF_8)
    origin = { start: positions.position(location.start_offset), end: positions.position(location.end_offset) }
    link = { originSelectionRange: origin, targetUri: "file:///projection/other.rb",
             targetRange: range(7, 0, 30), targetSelectionRange: range(7, 4, 10) }
    mapped = mapper.definitions([link], uri: @uri).first

    assert_equal range(1, 2, 8), mapped[:originSelectionRange]
    assert_equal link[:targetRange], mapped[:targetRange]
    assert_equal link[:targetSelectionRange], mapped[:targetSelectionRange]
  end

  private

  def find_node(document, type, name)
    queue = [document.ast]
    until queue.empty?
      node = queue.shift
      return node if node.is_a?(type) && node.name == name

      queue.concat(node.child_nodes.compact)
    end
    flunk "Expected #{type} named #{name} in the generated AST"
  end

  def document(source)
    Slim::SlimDocument.new(source: source, version: 1, uri: @uri, global_state: @state)
  end

  def perform(document, method, **params)
    Slim::RequestAdapter.new(@state, document).perform("textDocument/#{method}", params)
  end

  def range(line, first, last)
    { start: { line: line, character: first }, end: { line: line, character: last } }
  end

  def decode_tokens(data)
    line = column = 0
    data.each_slice(5).map do |delta_line, delta_column, length, _type, _modifiers|
      column = delta_line.zero? ? column + delta_column : delta_column
      line += delta_line
      [line, column, length]
    end
  end
end
