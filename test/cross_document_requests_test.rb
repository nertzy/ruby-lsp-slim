# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "timeout"

class CrossDocumentRequestsTest < Minitest::Test
  Slim = RubyLsp::RubyLspSlim

  def setup
    @directory = Dir.mktmpdir("slim-cross-document-")
    @server = RubyLsp::Server.new(test_mode: true)
    @state = @server.global_state
    @state.apply_options(workspaceFolders: [{ uri: uri_for("").to_s }], capabilities: {})
    Slim::Addon.new.activate(@state, Thread::Queue.new)
    @store = @server.instance_variable_get(:@store)
    @id = 0
    @ruby = open_document("model.rb", "class Widget; end\nWidget\n", language: :ruby)
  end

  def teardown
    @server.run_shutdown
    FileUtils.remove_entry(@directory)
  end

  def test_ruby_references_include_two_mapped_templates_but_not_host_text
    first, second = open_templates
    locations = request("references", @ruby, context: { includeDeclaration: false })

    assert_equal 4, locations.length
    assert_equal [range(1, 0, 6)], ranges_for(locations, @ruby.uri)
    assert_equal [range(2, 4, 10), range(3, 2, 8)], ranges_for(locations, first.uri)
    assert_equal [range(1, 16, 22)], ranges_for(locations, second.uri)
    assert_same first, @store.get(first.uri)
    refute(@state.index["Widget"].any? { |entry| entry.uri == first.uri }, "Generated documents must not be indexed")
  end

  def test_ruby_rename_maps_all_edits_and_preserves_host_text
    first, second = open_templates
    changes = request("rename", @ruby, newName: "Gadget").fetch(:changes)

    assert_equal "class Gadget; end\nGadget\n", apply_edits(@ruby.source, changes.fetch(@ruby.uri.to_s))
    assert_equal "p Widget host\n- if visible\n  = Gadget\n= Gadget\n",
                 apply_edits(first.source, changes.fetch(first.uri.to_s))
    assert_equal "| é😀\r\n= format(\"é😀\", Gadget)\r\n", apply_edits(second.source, changes.fetch(second.uri.to_s))
    assert_equal "p Widget host\n- if visible\n  = Widget\n= Widget\n", first.source
  end

  def test_slim_origin_uses_the_same_workspace_search_and_original_cursor
    first, second = open_templates
    locations = request("references", second, position: { line: 1, character: 17 },
                                              context: { includeDeclaration: false })
    assert_equal 4, locations.length
    changes = request("rename", first, position: { line: 2, character: 5 }, newName: "Gadget").fetch(:changes)
    assert_equal 3, changes.length
    assert_equal([range(2, 4, 10), range(3, 2, 8)], changes.fetch(first.uri.to_s).map { |edit| edit[:range] })
    prepared = request("prepareRename", second, position: { line: 1, character: 17 })
    assert_equal range(1, 16, 22), prepared
  end

  def test_static_only_slim_does_not_disable_ruby_references_or_rename
    static = open_document("static.slim", "p Widget is host text\n")
    locations = request("references", @ruby, context: { includeDeclaration: true })
    assert_equal 2, locations.length
    refute(locations.any? { |location| location[:uri] == static.uri.to_s })
    changes = request("rename", @ruby, newName: "Gadget").fetch(:changes)
    assert_equal [@ruby.uri.to_s], changes.keys
  end

  def test_include_declaration_is_honored_for_projected_class_declarations
    template = open_document("declaration.slim", "p Host\nruby:\n  class Widget\n    Widget\n  end\n")
    with_declarations = request("references", @ruby, context: { includeDeclaration: true })
    without_declarations = request("references", @ruby, context: { includeDeclaration: false })

    assert_equal [range(2, 8, 14), range(3, 4, 10)], ranges_for(with_declarations, template.uri)
    assert_equal [range(3, 4, 10)], ranges_for(without_declarations, template.uri)
    changes = request("rename", @ruby, newName: "Gadget").fetch(:changes)
    assert_equal "p Host\nruby:\n  class Gadget\n    Gadget\n  end\n",
                 apply_edits(template.source, changes.fetch(template.uri.to_s))
  end

  def test_method_and_instance_variable_references_preserve_declaration_filtering
    source = "class Widget\n  def title\n    @title = 1\n    @title\n  end\nend\n"
    ruby = open_document("instance.rb", source, language: :ruby)
    template_source = "p Host\nruby:\n  class Widget\n    def title\n      @title = 1\n      @title\n    end\n  end\n"
    template = open_document("instance.slim", template_source)
    variables = request("references", ruby, position: { line: 3, character: 5 },
                                            context: { includeDeclaration: false })
    assert_equal [range(5, 6, 12)], ranges_for(variables, template.uri)
    assert_equal [range(3, 4, 10)], ranges_for(variables, ruby.uri)
    methods = request("references", ruby, position: { line: 1, character: 7 },
                                          context: { includeDeclaration: true })
    assert_equal [range(3, 8, 13)], ranges_for(methods, template.uri)
    assert_empty request("references", ruby, position: { line: 1, character: 7 },
                                             context: { includeDeclaration: false })
  end

  def test_invalid_template_fails_atomically_and_recovery_uses_fresh_snapshot
    first, second = open_templates
    second.push_edits([{ text: "= Widget(\n" }], version: 2)
    %w[references rename].each do |method|
      error = request(method, @ruby, newName: "Gadget", error: true)
      assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
      assert_includes error[:message], second.uri.to_s
    end
    second.push_edits([{ text: "p Added host\n= Widget\n" }], version: 3)
    changes = request("rename", @ruby, newName: "Gadget").fetch(:changes)
    assert_equal([range(1, 2, 8)], changes.fetch(second.uri.to_s).map { |edit| edit[:range] })
    assert_includes changes.keys, first.uri.to_s
  end

  def test_disk_ruby_files_are_searched_but_unopened_templates_are_not_claimed
    open_document("static.slim", "p Host\n")
    disk_ruby = uri_for("use.rb")
    File.write(disk_ruby.to_standardized_path, "Widget\n")
    File.write(File.join(@directory, "closed.slim"), "= Widget\n")
    locations = request("references", @ruby, context: { includeDeclaration: false })

    assert_equal 2, locations.length
    assert_equal [range(0, 0, 6)], ranges_for(locations, disk_ruby)
    refute(locations.any? { |location| location[:uri].end_with?("closed.slim") })
    changes = request("rename", @ruby, newName: "Gadget").fetch(:changes)
    assert_equal "Gadget\n", apply_edits(File.read(disk_ruby.to_standardized_path), changes.fetch(disk_ruby.to_s))
    assert_equal "= Gadget\n", apply_edits("= Widget\n", changes.fetch(uri_for("closed.slim").to_s))
    refute @store.key?(uri_for("closed.slim")), "Disk projections stay request-local"
  end

  def test_reference_and_rename_positions_are_encoded_for_each_target_document
    %w[utf-8 utf-16 utf-32].each do |encoding|
      @state.apply_options(capabilities: { general: { positionEncodings: [encoding] } })
      ruby = open_document("unicode.rb", "class Widget; end\n\"é😀\"; Widget\n", language: :ruby)
      template = open_document("unicode.slim", "= format(\"é😀\", Widget)\n")
      position = Slim::Positions.new(ruby.source, @state.encoding).position(ruby.source.b.rindex("Widget") + 1)
      locations = request("references", ruby, position: position, context: { includeDeclaration: false })
      expected = source_range(template.source, template.source.b.index("Widget"), "Widget".bytesize)
      assert_equal [expected], ranges_for(locations, template.uri), encoding
      changes = request("rename", ruby, position: position, newName: "Gadget").fetch(:changes)
      assert_equal "= format(\"é😀\", Gadget)\n", apply_edits(template.source, changes.fetch(template.uri.to_s)),
                   encoding
    end
  end

  def test_a_changed_or_reopened_participant_invalidates_the_whole_result
    first, = open_templates
    view = Slim::CrossDocumentRequests::StoreView.new(@state, @store)
    first.push_edits([{ text: "= Different\n" }], version: 2)
    assert_raises(Slim::RequestAdapter::StaleDocument) { view.verify! }
    view = Slim::CrossDocumentRequests::StoreView.new(@state, @store)
    open_document("first.slim", "= Different\n")
    assert_raises(Slim::RequestAdapter::StaleDocument) { view.verify! }
  end

  def test_mid_request_changes_fail_without_a_partial_workspace_edit
    first, = open_templates
    index = @state.index
    original = index.method(:resolve)
    changed = false
    intercept = lambda do |*arguments, **keywords|
      unless changed
        changed = true
        first.push_edits([{ text: "= Widget\n" }], version: 2)
      end
      original.call(*arguments, **keywords)
    end
    index.stub(:resolve, intercept) do
      error = request("rename", @ruby, newName: "Gadget", error: true)
      assert_equal RubyLsp::Constant::ErrorCodes::CONTENT_MODIFIED, error[:code]
    end
  end

  def test_synthetic_and_host_gap_workspace_edits_are_rejected_atomically
    template = open_document("gaps.slim", "- if visible\n  = Widget\n= Widget\n")
    view = Slim::CrossDocumentRequests::StoreView.new(@state, @store)
    generated = view.get(template.uri)
    queue = [generated.ast]
    node = queue.shift
    until node.is_a?(Prism::ConstantReadNode) && node.name == :Widget
      queue.unshift(*node.child_nodes.compact)
      node = queue.shift
      refute_nil node
    end
    copied = node.location
    positions = Slim::Positions.new(generated.source, Encoding::UTF_8)
    safe = { range: byte_range(positions, copied.start_offset, copied.end_offset), newText: "Gadget" }
    ending = template.projection.map.segments.find { |segment| segment.kind == :end }.generated
    unsafe = { range: byte_range(positions, ending.start_offset, ending.end_offset), newText: "Gadget" }
    assert_equal([range(1, 4, 10)], view.map_edits(template.uri, generated.ast, [safe]).map { |edit| edit[:range] })
    assert_raises(Slim::UnsafeEdit) { view.map_edits(template.uri, generated.ast, [safe, unsafe]) }
    crossing = { range: byte_range(positions, copied.start_offset, generated.ast.location.end_offset),
                 newText: "Gadget" }
    assert_raises(Slim::UnsafeEdit) { view.map_edits(template.uri, generated.ast, [crossing]) }
    assert_equal "- if visible\n  = Widget\n= Widget\n", template.source
  end

  def test_native_rename_crossing_omitted_filter_indentation_fails_atomically
    ruby = open_document("nested.rb", "class Widget\n  class Child; end\nend\nWidget::Child\n", language: :ruby)
    template = open_document("multiline.slim", "ruby:\n  Widget::\n    Child\n")
    refute template.syntax_error?
    error = request("rename", ruby, position: { line: 3, character: 10 }, newName: "Other", error: true)
    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], template.uri.to_s
    assert_equal "ruby:\n  Widget::\n    Child\n", template.source
  end

  def test_closed_template_content_and_membership_are_checked_for_coherence
    path = File.join(@directory, "closed.slim")
    File.write(path, "= Widget\n")
    view = Slim::CrossDocumentRequests::StoreView.new(@state, @store)
    view.include_disk_templates!
    File.write(path, "= Different\n")
    assert_raises(Slim::RequestAdapter::StaleDocument) { view.verify! }
    view = Slim::CrossDocumentRequests::StoreView.new(@state, @store)
    view.include_disk_templates!
    File.write(File.join(@directory, "added.slim"), "= Widget\n")
    assert_raises(Slim::RequestAdapter::StaleDocument) { view.verify! }
  end

  def test_unindexed_shadowing_declaration_is_not_renamed_as_the_global_constant
    shadow = open_document("shadow.slim", "ruby:\n  module Scope\n    Widget = 1\n    Widget\n  end\n")
    %w[references rename].each do |method|
      error = request(method, @ruby, newName: "Gadget", error: true)
      assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
      assert_includes error[:message], "Scope::Widget"
      assert_includes error[:message], shadow.uri.to_s
    end
    assert_nil @state.index["Scope::Widget"]
    open_document("shadow.slim", "ruby:\n  module Scope\n    Unrelated = 1\n  end\n")
    assert_equal [@ruby.uri.to_s], request("rename", @ruby, newName: "Gadget").fetch(:changes).keys
  end

  def test_unindexed_template_namespace_cannot_hide_inherited_constants
    open_document("parent.rb", "class Parent; Widget = 1; end", language: :ruby)
    template = open_document("inherited.slim", "ruby:\n  class Scope < Parent\n    Widget\n  end\n")
    error = request("rename", @ruby, newName: "Gadget", error: true)
    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], "Scope"
    assert_includes error[:message], template.uri.to_s

    # The unindexed namespace is irrelevant when the matching reference is outside it.
    open_document("inherited.slim", "ruby:\n  class Scope < Parent\n    Other = 1\n  end\n= Widget\n")
    changes = request("rename", @ruby, newName: "Gadget").fetch(:changes)
    assert_equal([range(4, 2, 8)], changes.fetch(template.uri.to_s).map { |edit| edit[:range] })
  end

  def test_rename_rejects_zero_match_inherited_uses_in_managed_templates
    ruby = open_document("parent.rb", "class Parent\n  Widget = 1\n  Widget\nend\n", language: :ruby)
    template = open_document("inherited.slim", "ruby:\n  class Scope < Parent\n    Widget\n  end\n")
    error = request("rename", ruby, position: { line: 2, character: 3 }, newName: "Gadget", error: true)

    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], "Scope"
    assert_includes error[:message], template.uri.to_s
    assert_nil @state.index["Scope"], "Template namespaces must remain outside the persistent index"
  end

  def test_references_reject_zero_match_inherited_uses_in_managed_templates
    ruby = open_document("parent.rb", "class Parent\n  Widget = 1\n  Widget\nend\n", language: :ruby)
    template = open_document("inherited.slim", "ruby:\n  class Scope < Parent\n    Widget\n  end\n")
    [false, true].each do |include_declaration|
      error = request("references", ruby, position: { line: 2, character: 3 },
                                          context: { includeDeclaration: include_declaration }, error: true)
      assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
      assert_includes error[:message], "Scope"
      assert_includes error[:message], template.uri.to_s
    end
  end

  def test_rename_rejects_inherited_managed_use_when_scope_name_is_only_a_constant
    ruby = open_document(
      "parent.rb",
      "class Parent\n  Widget = 1\n  Widget\nend\nScope = Class.new(Parent)\n",
      language: :ruby
    )
    template = open_document("inherited.slim", "ruby:\n  class Scope < Parent\n    Widget\n  end\n")
    assert @state.index["Scope"].all?(RubyIndexer::Entry::Constant)
    refute template.syntax_error?, "Class.new(Parent) may be reopened by the valid Slim class declaration"

    error = request("rename", ruby, position: { line: 2, character: 3 }, newName: "Gadget", error: true)

    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], "Scope"
    assert_includes error[:message], template.uri.to_s
  end

  def test_rename_rejects_zero_match_inherited_uses_in_disk_templates
    ruby = open_document("parent.rb", "class Parent\n  Widget = 1\n  Widget\nend\n", language: :ruby)
    path = File.join(@directory, "inherited.slim")
    source = "ruby:\n  class Scope < Parent\n    Widget\n  end\n"
    File.write(path, source)
    # References promise managed templates only; an unopened namespace is not a participant.
    open_document("static.slim", "p Host\n")
    locations = request("references", ruby, position: { line: 2, character: 3 },
                                            context: { includeDeclaration: false })
    assert_equal([ruby.uri.to_s], locations.map { |location| location[:uri] })
    error = request("rename", ruby, position: { line: 2, character: 3 }, newName: "Gadget", error: true)

    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], "Scope"
    assert_includes error[:message], uri_for("inherited.slim").to_s
    assert_equal source, File.read(path)
    refute @store.key?(uri_for("inherited.slim"))
    assert_nil @state.index["Scope"]
  end

  def test_rename_rejects_inherited_disk_use_when_scope_name_is_only_a_constant
    ruby = open_document(
      "parent.rb",
      "class Parent\n  Widget = 1\n  Widget\nend\nScope = Class.new(Parent)\n",
      language: :ruby
    )
    path = File.join(@directory, "inherited.slim")
    source = "ruby:\n  class Scope < Parent\n    Widget\n  end\n"
    File.write(path, source)
    assert @state.index["Scope"].all?(RubyIndexer::Entry::Constant)

    error = request("rename", ruby, position: { line: 2, character: 3 }, newName: "Gadget", error: true)

    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], "Scope"
    assert_includes error[:message], uri_for("inherited.slim").to_s
    assert_equal source, File.read(path)
    refute @store.key?(uri_for("inherited.slim"))
  end

  def test_indexed_class_and_module_namespaces_remain_usable
    parent = open_document(
      "parent.rb",
      "class Parent\n  Widget = 1\n  Widget\nend\nclass Scope < Parent; end\nmodule Container; end\n",
      language: :ruby
    )
    inherited = open_document("inherited.slim", "ruby:\n  class Scope < Parent\n    Widget\n  end\n")
    top_level = open_document("module.slim", "ruby:\n  module Container\n    Parent\n  end\n")
    %w[Scope Container].each do |name|
      assert @state.index[name].any?(RubyIndexer::Entry::Namespace), name
    end

    inherited_changes = request("rename", parent, position: { line: 2, character: 3 },
                                                  newName: "Gadget").fetch(:changes)
    assert_equal([range(2, 4, 10)], inherited_changes.fetch(inherited.uri.to_s).map { |edit| edit[:range] })
    module_changes = request("rename", parent, position: { line: 0, character: 7 }, newName: "Base").fetch(:changes)
    assert_equal([range(2, 4, 10)], module_changes.fetch(top_level.uri.to_s).map { |edit| edit[:range] })
  end

  def test_unrelated_uses_in_unindexed_namespaces_do_not_block_inherited_target_rename
    ruby = open_document("parent.rb", "class Parent\n  Widget = 1\n  Widget\nend\n", language: :ruby)
    open_document("unrelated.slim", "ruby:\n  class Scope < Parent\n    Other\n  end\n")
    File.write(File.join(@directory, "closed.slim"), "ruby:\n  class ClosedScope < Parent\n    Other\n  end\n")
    locations = request("references", ruby, position: { line: 2, character: 3 },
                                            context: { includeDeclaration: false })
    assert_equal([ruby.uri.to_s], locations.map { |location| location[:uri] })
    changes = request("rename", ruby, position: { line: 2, character: 3 }, newName: "Gadget").fetch(:changes)

    assert_equal [ruby.uri.to_s], changes.keys
    assert_equal "class Parent\n  Gadget = 1\n  Gadget\nend\n", apply_edits(ruby.source, changes.fetch(ruby.uri.to_s))
    assert_nil @state.index["Scope"]
    assert_nil @state.index["ClosedScope"]
  end

  def test_rename_searches_unopened_templates_even_when_none_are_managed
    File.write(File.join(@directory, "closed.slim"), "p Widget host\n= Widget\n")
    changes = request("rename", @ruby, newName: "Gadget").fetch(:changes)
    assert_equal "p Widget host\n= Gadget\n",
                 apply_edits("p Widget host\n= Widget\n", changes.fetch(uri_for("closed.slim").to_s))
    File.write(File.join(@directory, "closed.slim"), "= Widget(\n")
    error = request("rename", @ruby, newName: "Gadget", error: true)
    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], "closed.slim"
  end

  def test_template_destination_declarations_reject_rename_before_any_edits
    source = "ruby:\n  Gadget = 123\n= Widget\n= Gadget\n"
    template = open_document("destination.slim", source)
    error = request("rename", @ruby, newName: "Gadget", error: true)

    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], "Gadget"
    assert_includes error[:message], template.uri.to_s
    assert_equal source, template.source
    assert_nil @state.index["Gadget"]
  end

  def test_unopened_destination_declarations_are_checked_without_matching_references
    path = File.join(@directory, "destination.slim")
    File.write(path, "ruby:\n  Gadget = 123\n= Gadget\n")
    error = request("rename", @ruby, newName: "Gadget", error: true)

    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], uri_for("destination.slim").to_s
    assert_nil @state.index["Gadget"]
    refute @store.key?(uri_for("destination.slim"))

    File.write(path, "= Widget\n")
    changes = request("rename", @ruby, newName: "Gadget").fetch(:changes)
    assert_equal "= Gadget\n", apply_edits("= Widget\n", changes.fetch(uri_for("destination.slim").to_s))
  end

  def test_template_destination_cannot_capture_references_inside_an_indexed_namespace
    open_document("scope.rb", "module Foo; end\n", language: :ruby)
    template = open_document("capture.slim", "ruby:\n  module Foo\n    Gadget = 123\n    Widget\n  end\n")
    error = request("rename", @ruby, newName: "Gadget", error: true)

    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], "Foo::Gadget"
    assert_includes error[:message], template.uri.to_s
    assert_nil @state.index["Foo::Gadget"]
  end

  def test_unopened_template_destination_cannot_capture_a_ruby_reference
    open_document("scope.rb", "module Foo\n  Widget\nend\n", language: :ruby)
    File.write(File.join(@directory, "capture.slim"), "ruby:\n  module Foo\n    Gadget = 123\n  end\n")
    error = request("rename", @ruby, newName: "Gadget", error: true)

    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], "Foo::Gadget"
    assert_includes error[:message], uri_for("capture.slim").to_s
    assert_nil @state.index["Foo::Gadget"]
  end

  def test_destination_in_a_disjoint_template_namespace_does_not_block_top_level_rename
    File.write(File.join(@directory, "separate.slim"), "ruby:\n  module Other\n    Gadget = 123\n  end\n= Widget\n")
    changes = request("rename", @ruby, newName: "Gadget").fetch(:changes)

    assert_equal "class Gadget; end\nGadget\n", apply_edits(@ruby.source, changes.fetch(@ruby.uri.to_s))
    assert_equal([range(4, 2, 8)], changes.fetch(uri_for("separate.slim").to_s).map { |edit| edit[:range] })
    assert_nil @state.index["Other::Gadget"]
  end

  def test_ambiguous_scoped_destination_is_rejected_but_absolute_destination_is_safe
    ruby = open_document("scope.rb", "module Foo\n  Widget\nend\n", language: :ruby)
    File.write(File.join(@directory, "separate.slim"), "ruby:\n  module Other\n    Gadget = 123\n  end\n")
    error = request("rename", @ruby, newName: "Gadget", error: true)
    assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    assert_includes error[:message], "Other::Gadget"

    changes = request("rename", @ruby, newName: "::Gadget").fetch(:changes)
    assert_equal "module Foo\n  ::Gadget\nend\n", apply_edits(ruby.source, changes.fetch(ruby.uri.to_s))
    assert_nil @state.index["Other::Gadget"]
  end

  def test_disk_snapshots_preserve_native_managed_file_and_directory_exclusions
    open_document("static.slim", "p Host\n")
    managed_path = @ruby.uri.to_standardized_path
    File.write(managed_path, "Unrelated\n")
    Dir.mkdir(File.join(@directory, "directory.rb"))
    %w[rename references].each do |method|
      runner = Slim::CrossDocumentRequests.new(@state, @store)
      view = runner.instance_variable_get(:@view)
      verify = view.method(:verify!)
      intercept = lambda do
        File.write(managed_path, "ChangedOnDisk\n")
        File.write(File.join(@directory, "not_ruby.txt"), "Widget\n")
        verify.call
      end
      result = view.stub(:verify!, intercept) do
        runner.perform("textDocument/#{method}", textDocument: { uri: @ruby.uri },
                                                 position: { line: 1, character: 1 }, newName: "Gadget")
      end
      if method == "rename"
        assert_equal "class Gadget; end\nGadget\n",
                     apply_edits(@ruby.source, result.fetch(:changes).fetch(@ruby.uri.to_s))
      else
        assert_equal [range(0, 6, 12), range(1, 0, 6)], ranges_for(result, @ruby.uri)
      end
    end
  end

  def test_zero_match_ruby_sources_changed_after_collection_invalidate_the_result
    open_document("static.slim", "p Host\n")
    path = File.join(@directory, "unrelated.rb")
    %w[rename references].each do |method|
      File.write(path, "Unrelated\n")
      runner = Slim::CrossDocumentRequests.new(@state, @store)
      view = runner.instance_variable_get(:@view)
      verify = view.method(:verify!)
      changed = false
      intercept = lambda do
        changed = true
        File.write(path, "Widget\n")
        verify.call
      end
      view.stub(:verify!, intercept) do
        assert_raises(Slim::RequestAdapter::StaleDocument) do
          runner.perform("textDocument/#{method}", textDocument: { uri: @ruby.uri },
                                                   position: { line: 1, character: 1 }, newName: "Gadget")
        end
      end
      assert changed, "The #{method} request must reach final snapshot validation"
    end
  end

  def test_zero_match_ruby_snapshots_use_the_bytes_parsed_not_a_later_disk_read
    open_document("static.slim", "p Host\n")
    path = File.join(@directory, "unrelated.rb")
    { rename: :parse_file, references: :parse_lex_file }.each do |method, parser|
      File.write(path, "Unrelated\n")
      parse = Prism.method(parser)
      parsed = []
      intercept = lambda do |file, **options|
        result = parse.call(file, **options)
        if file == path
          parsed << result.source.source
          File.write(path, "Widget\n")
        end
        result
      end
      Prism.stub(parser, intercept) do
        error = request(method, @ruby, newName: "Gadget", error: true)
        assert_equal RubyLsp::Constant::ErrorCodes::CONTENT_MODIFIED, error[:code]
      end
      assert_equal ["Unrelated\n"], parsed, "Native #{method} must parse the disk source once"
    end
  end

  def test_ruby_files_added_after_native_discovery_invalidate_the_result
    open_document("static.slim", "p Host\n")
    path = File.join(@directory, "unrelated.rb")
    added = File.join(@directory, "added.rb")
    File.write(path, "Unrelated\n")
    { rename: :parse_file, references: :parse_lex_file }.each do |method, parser|
      FileUtils.rm_f(added)
      parse = Prism.method(parser)
      parsed = []
      intercept = lambda do |file, **options|
        result = parse.call(file, **options)
        parsed << file
        File.write(added, "Widget\n") if file == path
        result
      end
      Prism.stub(parser, intercept) do
        error = request(method, @ruby, newName: "Gadget", error: true)
        assert_equal RubyLsp::Constant::ErrorCodes::CONTENT_MODIFIED, error[:code]
      end
      assert_equal [path], parsed, "The new file must be absent from native #{method} discovery"
      assert_equal "Widget\n", File.read(added)
    end
  end

  def test_invalid_rename_names_fail_without_edits
    open_document("static.slim", "p Host\n")
    ["lowercase", "Gadget\nOther", "Gadget; puts(1)"].each do |name|
      error = request("rename", @ruby, newName: name, error: true)
      assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
    end
  end

  def test_versioned_document_changes_keep_native_file_renames_and_original_versions
    @state.apply_options(capabilities: { workspace: { workspaceEdit: { documentChanges: true,
                                                                       resourceOperations: ["rename"] } } })
    ruby = open_document("widget.rb", "class Widget; end\nWidget\n", language: :ruby)
    template = open_document("versioned.slim", "= Widget\n")
    template.push_edits([{ text: "p Host\n= Widget\n" }], version: 7)
    response = request("rename", ruby, newName: "Gadget")
    edits = response.fetch(:documentChanges)
    slim_edit = edits.find { |edit| edit.dig(:textDocument, :uri) == template.uri.to_s }

    assert_equal 7, slim_edit.dig(:textDocument, :version)
    assert_equal range(1, 2, 8), slim_edit[:edits].first[:range]
    assert(edits.any? do |edit|
      edit[:kind] == "rename" && edit[:oldUri] == ruby.uri.to_s && edit[:newUri] == uri_for("gadget.rb").to_s
    end)
  end

  private

  def open_templates
    [open_document("first.slim", "p Widget host\n- if visible\n  = Widget\n= Widget\n"),
     open_document("second.slim", "| é😀\r\n= format(\"é😀\", Widget)\r\n")]
  end

  def uri_for(path)
    URI::Generic.from_path(path: File.join(@directory, path))
  end

  def open_document(path, source, language: :slim)
    uri = uri_for(path)
    @state.index.index_single(uri, source) if language == :ruby
    @store.set(uri: uri, source: source, version: 1, language_id: language)
  end

  def request(method, document, error: false, **params)
    @id += 1
    params = { position: { line: 1, character: 1 }, textDocument: { uri: document.uri } }.merge(params)
    @server.process_message(id: @id, method: "textDocument/#{method}", params: params)
    response = Timeout.timeout(5) do
      loop do
        message = @server.pop_response
        if message.is_a?(RubyLsp::Result) || message.is_a?(RubyLsp::Error)
          break Slim::ResponseMapper.serialize(message.to_hash)
        end
      end
    end
    if error
      refute_nil response[:error], response.inspect
      response[:error]
    else
      assert_nil response[:error], response.inspect
      response[:result]
    end
  end

  def ranges_for(locations, uri)
    locations.select { |location| location[:uri] == uri.to_s }.map { |location| location[:range] }
  end

  def range(line, first, last)
    { start: { line: line, character: first }, end: { line: line, character: last } }
  end

  def source_range(source, offset, length)
    byte_range(Slim::Positions.new(source, @state.encoding), offset, offset + length)
  end

  def byte_range(positions, first, last)
    { start: positions.position(first), end: positions.position(last) }
  end

  def apply_edits(source, edits)
    positions = Slim::Positions.new(source, @state.encoding)
    edits.sort_by { |edit| positions.byte_offset(edit[:range][:start]) }.reverse.inject(source.dup) do |text, edit|
      first = positions.byte_offset(edit[:range][:start])
      last = positions.byte_offset(edit[:range][:end])
      text.byteslice(0...first) + edit[:newText] + text.byteslice(last..)
    end
  end
end
