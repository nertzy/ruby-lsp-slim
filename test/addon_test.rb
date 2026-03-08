# frozen_string_literal: true

require "test_helper"

class AddonTest < Minitest::Test
  def test_addon_name
    addon = RubyLsp::RubyLspSlim::Addon.new
    assert_equal "Ruby LSP Slim", addon.name
  end

  def test_addon_version
    addon = RubyLsp::RubyLspSlim::Addon.new
    assert_equal RubyLspSlim::VERSION, addon.version
  end

  def test_store_patch_module_defined
    assert_kind_of Module, RubyLsp::RubyLspSlim::StorePatch
  end

  def test_server_patch_module_defined
    assert_kind_of Module, RubyLsp::RubyLspSlim::ServerPatch
  end

  def test_store_set_creates_slim_document
    global_state = RubyLsp::GlobalState.new
    global_state.apply_options({})

    store = RubyLsp::Store.new(global_state)
    store.singleton_class.prepend(RubyLsp::RubyLspSlim::StorePatch)

    uri = URI::Generic.from_path(path: "/fake/test.slim")
    document = store.set(uri: uri, source: "- x = 1", version: 1, language_id: :slim)

    assert_kind_of RubyLsp::RubyLspSlim::SlimDocument, document
  end

  def test_store_set_passes_through_non_slim
    global_state = RubyLsp::GlobalState.new
    global_state.apply_options({})

    store = RubyLsp::Store.new(global_state)
    store.singleton_class.prepend(RubyLsp::RubyLspSlim::StorePatch)

    uri = URI::Generic.from_path(path: "/fake/test.rb")
    document = store.set(uri: uri, source: "x = 1", version: 1, language_id: :ruby)

    assert_kind_of RubyLsp::RubyDocument, document
    refute_kind_of RubyLsp::RubyLspSlim::SlimDocument, document
  end
end
