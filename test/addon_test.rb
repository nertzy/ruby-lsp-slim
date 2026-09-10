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

  def test_store_detects_slim_extension_even_when_native_loader_says_ruby
    state = RubyLsp::GlobalState.new
    state.apply_options({})
    store = RubyLsp::Store.new(state)
    store.singleton_class.prepend(RubyLsp::RubyLspSlim::StorePatch)
    uri = URI("file:///fake/test.html.slim")
    document = store.set(uri: uri, source: "= title".b, version: 0, language_id: :ruby)

    assert_instance_of RubyLsp::RubyLspSlim::SlimDocument, document
    assert_equal Encoding::UTF_8, document.source.encoding
    refute document.syntax_error?
  end

  def test_disk_loaded_slim_uses_the_projection_document
    state = RubyLsp::GlobalState.new
    state.apply_options({})
    store = RubyLsp::Store.new(state)
    store.singleton_class.prepend(RubyLsp::RubyLspSlim::StorePatch)
    uri = URI::Generic.from_path(path: File.expand_path("fixtures/basic.slim", __dir__))

    assert File.file?(uri.to_standardized_path)
    document = store.get(uri)
    assert_instance_of RubyLsp::RubyLspSlim::SlimDocument, document
    assert_equal File.binread(uri.to_standardized_path).force_encoding(Encoding::UTF_8), document.source
  end

  def test_activation_does_not_confuse_watching_with_text_sync_registration
    state = RubyLsp::GlobalState.new
    state.apply_options(capabilities: {
                          workspace: { didChangeWatchedFiles: { dynamicRegistration: true,
                                                                relativePatternSupport: true } }
                        })
    queue = Thread::Queue.new
    RubyLsp::RubyLspSlim::Addon.new.activate(state, queue)

    assert_equal 1, queue.length
    assert_instance_of RubyLsp::Notification, queue.pop
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
