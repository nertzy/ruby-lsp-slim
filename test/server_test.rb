# frozen_string_literal: true

require "test_helper"
require "timeout"

class ServerTest < Minitest::Test
  Slim = RubyLsp::RubyLspSlim

  def setup
    @input, @output = IO.pipe
    @server = RubyLsp::Server.new(test_mode: true, reader: @input)
    @server.global_state.apply_options(capabilities: {})
    Slim::Addon.new.activate(@server.global_state, Thread::Queue.new)
    @uri = URI("untitled:ServerSlim")
    @request_id = 0
  end

  def teardown
    @output.close unless @output.closed?
    @reader_thread&.join(2)
    @reader_thread&.kill if @reader_thread&.alive?
    @input.close unless @input.closed?
    @server.run_shutdown
  end

  def test_reader_loop_survives_typing_invalid_then_valid_with_fresh_results
    @reader_thread = Thread.new { @server.start }
    write(method: "textDocument/didOpen", params: {
            textDocument: { uri: @uri.to_s, languageId: "slim", version: 1, text: "- title = 1\n= title\n" }
          })
    assert_empty wire_request("textDocument/diagnostic")[:items]
    refute_empty wire_request("textDocument/semanticTokens/full")[:data]

    write(method: "textDocument/didChange", params: {
            textDocument: { uri: @uri.to_s, version: 2 }, contentChanges: [{ text: "p Host\n= user.\n" }]
          })
    2.times do
      diagnostic = wire_request("textDocument/diagnostic")
      refute_empty diagnostic[:items]
      assert_empty wire_request("textDocument/semanticTokens/full")[:data]
    end
    write(method: "textDocument/didChange", params: {
            textDocument: { uri: @uri.to_s, version: 3 }, contentChanges: [{ text: "p Host\n- title = 1\n= tit" }]
          })
    assert_empty wire_request("textDocument/diagnostic")[:items]
    completion = wire_request("textDocument/completion", position: { line: 2, character: 5 })
    item = completion.find { |entry| entry[:label] == "title" }
    refute_nil item
    assert_equal 2, item.dig(:textEdit, :range, :start, :line)
    assert_equal 2, item.dig(:textEdit, :range, :start, :character)
    assert @reader_thread.alive?
  end

  def test_handler_reparses_after_change_without_reader_preparse
    open_document("- Widget = 1\n")
    first = request("textDocument/documentSymbol")
    assert_equal "Widget", first.first[:name]
    @server.process_message(method: "textDocument/didChange", params: {
                              textDocument: { uri: @uri,
                                              version: 2 }, contentChanges: [{ text: "p Host\n- Other = 1\n" }]
                            })
    symbols = request("textDocument/documentSymbol")
    assert_equal "Other", symbols.first[:name]
    assert_equal 1, symbols.first.dig(:selectionRange, :start, :line)
    assert_nil @server.global_state.index["Other"], "Generated declarations must not enter the index"
  end

  def test_unsupported_requests_fail_explicitly_without_generated_edits
    open_document("- Widget = 1\n")
    %w[formatting rangeFormatting onTypeFormatting codeAction selectionRange
       documentLink codeLens inlayHint prepareTypeHierarchy].each do |method|
      error = request("textDocument/#{method}", expect_error: true)
      assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code], method
      assert_match(/Slim/, error[:message], method)
    end
  end

  def test_reader_loop_serves_current_non_ruby_filter_folding_ranges
    @reader_thread = Thread.new { @server.start }
    write(method: "textDocument/didOpen", params: {
            textDocument: { uri: @uri.to_s, languageId: "slim", version: 1,
                            text: "javascript:\n  alert(1)\n" }
          })
    assert_equal [{ startLine: 0, endLine: 1 }], wire_request("textDocument/foldingRange")

    write(method: "textDocument/didChange", params: {
            textDocument: { uri: @uri.to_s, version: 2 }, contentChanges: [{ text: "p Alone\n" }]
          })
    assert_empty wire_request("textDocument/foldingRange")
    assert @reader_thread.alive?
  end

  def test_ruby_origin_cross_document_operations_reject_invalid_slim_without_disabling_safe_ruby_requests
    open_document("= Widget(\n")
    ruby_uri = URI("untitled:RubyCaller")
    open_document("Widget", uri: ruby_uri, language: "ruby")
    @server.global_state.index.index_single(URI("untitled:Declarations"), "class Widget; end")
    @server.global_state.define_singleton_method(:workspace_path) { "/projection/no-disk-files" }
    %w[references rename].each do |method|
      error = request("textDocument/#{method}", uri: ruby_uri,
                                                position: { line: 0, character: 1 }, newName: "Gadget",
                                                expect_error: true)
      assert_equal RubyLsp::Constant::ErrorCodes::REQUEST_FAILED, error[:code]
      assert_match(/Slim/, error[:message])
    end
    assert_equal({ start: { line: 0, character: 0 }, end: { line: 0, character: 6 } },
                 request("textDocument/prepareRename", uri: ruby_uri, position: { line: 0, character: 1 }))
  end

  def test_ordinary_ruby_and_erb_requests_are_unchanged
    { "ruby" => "class Widget; end", "erb" => "<% Widget = 1 %>" }.each do |language, source|
      uri = URI("untitled:#{language}")
      open_document(source, uri: uri, language: language)
      symbols = request("textDocument/documentSymbol", uri: uri)
      assert_equal "Widget", symbols.first[:name]
    end
  end

  def test_invalid_cursor_is_an_invalid_params_response_not_internal_error
    open_document("= title")
    error = request("textDocument/hover", position: { line: 20, character: 0 }, expect_error: true)
    assert_equal RubyLsp::Constant::ErrorCodes::INVALID_PARAMS, error[:code]
  end

  def test_completion_resolve_refuses_stale_mapped_edits
    open_document("- title = 1\n= tit")
    item = request("textDocument/completion", position: { line: 1, character: 5 }).find do |entry|
      entry[:label] == "title"
    end
    refute_nil item
    @server.process_message(method: "textDocument/didChange", params: {
                              textDocument: { uri: @uri, version: 2 }, contentChanges: [{ text: "p Changed\n" }]
                            })
    @request_id += 1
    @server.process_message(id: @request_id, method: "completionItem/resolve", params: item)
    result = pop_result
    assert_equal RubyLsp::Constant::ErrorCodes::CONTENT_MODIFIED, result[:error][:code]
    assert_nil result[:result], "Stale completion edits must not be returned"
  end

  def test_completion_resolve_refuses_edits_after_close_and_reopen_at_the_same_version
    open_document("- title = 1\n= tit")
    item = request("textDocument/completion", position: { line: 1, character: 5 }).find do |entry|
      entry[:label] == "title"
    end
    refute_nil item
    assert_equal "title", item.dig(:textEdit, :newText)
    assert_equal({ start: { line: 1, character: 2 }, end: { line: 1, character: 5 } },
                 item.dig(:textEdit, :range))
    @request_id += 1
    @server.process_message(id: @request_id, method: "completionItem/resolve", params: item)
    unchanged = pop_result
    assert_nil unchanged[:error]
    assert_equal item[:textEdit], unchanged.dig(:result, :textEdit)

    @server.process_message(method: "textDocument/didClose", params: { textDocument: { uri: @uri } })
    open_document("p Header\np abcdef")
    reopened = @server.instance_variable_get(:@store).get(@uri)
    assert_equal item.dig(:data, :rubyLspSlim, :version), reopened.version
    assert_equal "p Header\np abcdef", reopened.source
    @request_id += 1
    @server.process_message(id: @request_id, method: "completionItem/resolve", params: item)
    result = pop_result
    assert_equal RubyLsp::Constant::ErrorCodes::CONTENT_MODIFIED, result.dig(:error, :code), result.inspect
    assert_nil result[:result], "Reopened host text must never receive the old Ruby edit"
  end

  def test_did_close_removes_projection_and_clears_diagnostics
    open_document("= foo(")
    refute_empty request("textDocument/diagnostic")[:items]
    @server.process_message(method: "textDocument/didClose", params: { textDocument: { uri: @uri } })
    message = @server.pop_response
    assert_equal "textDocument/publishDiagnostics", message.to_hash[:method]
    assert_empty message.to_hash[:params][:diagnostics]
    refute @server.instance_variable_get(:@store).key?(@uri)
  end

  private

  def open_document(source, uri: @uri, language: "slim")
    @server.process_message(method: "textDocument/didOpen", params: {
                              textDocument: { uri: uri, languageId: language, version: 1, text: source }
                            })
  end

  def request(method, uri: @uri, expect_error: false, **params)
    @request_id += 1
    @server.process_message(id: @request_id, method: method, params: params.merge(textDocument: { uri: uri }))
    response = pop_result
    if expect_error
      refute_nil response[:error]
      response[:error]
    else
      assert_nil response[:error], response.inspect
      response[:result]
    end
  end

  def wire_request(method, **params)
    @request_id += 1
    write(id: @request_id, method: method, params: params.merge(textDocument: { uri: @uri.to_s }))
    response = pop_result
    assert_nil response[:error], response.inspect
    response[:result]
  end

  def write(message)
    body = message.merge(jsonrpc: "2.0").to_json
    @output.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    @output.flush
  end

  def pop_result
    Timeout.timeout(5) do
      loop do
        message = @server.pop_response
        next unless message.is_a?(RubyLsp::Result) || message.is_a?(RubyLsp::Error)

        return JSON.parse(message.to_hash.to_json, symbolize_names: true)
      end
    end
  end
end
