# frozen_string_literal: true

require "test_helper"

class SlimScannerTest < Minitest::Test
  include TestHelper

  def test_ruby_and_host_language_same_length
    source = read_fixture("basic.slim")
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_equal source.length, scanner.ruby.length
    assert_equal source.length, scanner.host_language.length
  end

  def test_control_code_extraction
    source = "- x = 1\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_equal "  x = 1\n", scanner.ruby
    assert_includes scanner.ruby, "x = 1"
  end

  def test_output_code_extraction
    source = "= link_to \"Home\", root_path\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_includes scanner.ruby, 'link_to "Home", root_path'
  end

  def test_double_equals_output
    source = "== raw_html\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_includes scanner.ruby, "raw_html"
  end

  def test_interpolation_extraction
    source = "p Hello \#{user.name}\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_includes scanner.ruby, "user.name"
  end

  def test_ruby_filter
    source = "ruby:\n  x = 1\n  y = 2\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_includes scanner.ruby, "x = 1"
    assert_includes scanner.ruby, "y = 2"
  end

  def test_ruby_filter_ends_on_dedent
    source = "ruby:\n  x = 1\nh1 Hello\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_includes scanner.ruby, "x = 1"
    # "h1" should be in host language, not ruby
    ruby_stripped = scanner.ruby.delete(" \n")
    refute_includes ruby_stripped, "h1"
  end

  def test_tag_with_output
    source = "h1= title\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_includes scanner.ruby, "title"
    assert_includes scanner.host_language, "h1"
  end

  def test_control_flow_fixture
    source = read_fixture("control_flow.slim")
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_equal source.length, scanner.ruby.length
    assert_equal source.length, scanner.host_language.length
    assert_includes scanner.ruby, "current_user"
    assert_includes scanner.ruby, "link_to"
  end

  def test_position_preservation
    source = "- x = 42\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    # "x" should be at the same position in both source and ruby output
    x_pos_in_source = source.index("x")
    x_pos_in_ruby = scanner.ruby.index("x")
    assert_equal x_pos_in_source, x_pos_in_ruby
  end

  def test_empty_source
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new("")
    scanner.scan

    assert_equal "", scanner.ruby
    assert_equal "", scanner.host_language
  end

  def test_nested_interpolation_braces
    source = "p \#{hash[:key]}\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_includes scanner.ruby, "hash[:key]"
    assert_equal source.length, scanner.ruby.length
  end

  def test_indented_control_code
    source = "  - items.each do |item|\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_includes scanner.ruby, "items.each do |item|"
    assert_equal source.length, scanner.ruby.length
  end

  def test_comment_lines_ignored
    source = "/ This is a comment\nh1 Hello\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    ruby_stripped = scanner.ruby.delete(" \n")
    refute_includes ruby_stripped, "comment"
    assert_equal source.length, scanner.ruby.length
  end

  def test_backslash_continuation
    source = "- x = 1 + \\\n  2\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_includes scanner.ruby, "1 + \\"
    assert_includes scanner.ruby, "2"
    assert_equal source.length, scanner.ruby.length
  end

  def test_pipe_text_block
    source = "| Some text \#{name}\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_includes scanner.ruby, "name"
    assert_includes scanner.host_language, "|"
    assert_equal source.length, scanner.ruby.length
  end

  def test_unclosed_interpolation_does_not_crash
    source = "p \#{user.name\n"
    scanner = RubyLsp::RubyLspSlim::SlimScanner.new(source)
    scanner.scan

    assert_equal source.length, scanner.ruby.length
  end
end
