# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_lsp/ruby_lsp_slim/positioned_parser"

class PositionedParserTest < Minitest::Test
  Core = RubyLsp::RubyLspSlim

  def test_duplicate_ruby_payloads_have_independent_original_spans
    parser = Core::PositionedParser.new
    parser.call("p first=helper second=helper = helper\n= helper")
    payloads = parser.payloads.values.select { |payload| payload.text == "helper" }
    assert_equal([8, 22, 31, 40], payloads.map { |payload| payload.owner.start_offset })
    assert_equal 4, payloads.map(&:object_id).uniq.length
  end

  def test_broken_lines_retain_normalized_pieces_not_contiguous_raw_code
    source = "= helper(1,\r\n\t  2)  \r\n= footer"
    parser = Core::PositionedParser.new
    parser.call(source)
    payload = parser.payloads.values.find { |item| item.text.start_with?("helper") }
    assert_equal "helper(1,\n2)", payload.text
    assert_equal([2...11, 12...13, 16...18], payload.pieces.map { |piece| piece.original&.range })
    assert_copied_pieces(source, payload)
  end

  def test_attributes_and_text_normalization_keep_each_copy_exact
    source = "p title=\"Hi \#{user.name} \\\r\n  again \#{user.name}\" = title\r\n" \
             "| é😀 \#{name}\r\n\t \#{name}\r\n\r\n     \#{{raw}}\r\n"
    parser = Core::PositionedParser.new
    parser.call(source)
    parser.payloads.each_value { |payload| assert_copied_pieces(source, payload) }
    assert(parser.payloads.values.any? { |payload| payload.text == "Hi \#{user.name}  again \#{user.name}" })
  end

  private

  def assert_copied_pieces(source, payload)
    assert_equal payload.text, payload.pieces.map(&:text).join
    payload.pieces.each do |piece|
      assert_equal piece.text, source.byteslice(piece.original.range) if piece.original
    end
  end
end
