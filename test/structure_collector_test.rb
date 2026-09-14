# frozen_string_literal: true

require "test_helper"
require "ruby_lsp/ruby_lsp_slim/structure_collector"

module RubyLsp
  module RubyLspSlim
    class StructureCollectorTest < Minitest::Test
      CASES = {
        "div\n  section\n    p Hello\np Tail\n" => [[0, 2], [1, 2]],
        "- if ok\n  p Yes\n- else\n  p No\np Tail\n" => [[0, 1], [2, 3]],
        "= items.each do |item|\n  p = item\n" => [[0, 1]],
        "javascript:\n  alert(1)\n\np Tail\n" => [[0, 1]],
        "css:\n  p {\n    color: red;\n  }\n" => [[0, 3]],
        "ruby:\n  if ok\n    work\n  end\n" => [[0, 3]],
        "div\n  p Body\n\n\np Tail\n" => [[0, 1]],
        "div\r\n  p café 😀\r\n" => [[0, 1]],
        "- if (\n  p Body\np Tail\n" => [[0, 1]],
        "div\n  p Body\np Tail\np(class=\n" => [[0, 1]],
        "div\n  p(class=\n" => [],
        "div\n  p Body\nsection\n   div\n  p Invalid\n" => [[0, 1]],
        "div\n  p Body\np Tail\n   p Child\n  p Invalid\n" => [[0, 1], [2, 4]],
        "div\n  p Body" => [[0, 1]],
        "" => [],
        "p Alone\n\n" => []
      }.freeze

      def test_canonical_ranges
        CASES.each { |source, expected| assert_equal(expected, ranges(source), source.inspect) }
      end

      def test_collects_sibling_ruby_branches
        assert_equal [[0, 1], [2, 3], [4, 5]], ranges("- if one\n  p One\n- elsif two\n  p Two\n- else\n  p Other\n")
        assert_equal [[0, 1], [2, 3], [4, 5], [6, 7]],
                     ranges("- case value\n  p Case\n- when 1\n  p One\n- in String\n  p String\n- else\n  p Other\n")
        assert_equal [[0, 1], [2, 3], [4, 5]], ranges("- begin\n  p Body\n- rescue\n  p Error\n- ensure\n  p Cleanup\n")
      end

      def test_collects_every_registered_filter_as_an_opaque_container
        Slim::Embedded.engines.each_key do |engine|
          assert_equal [[0, 1]], ranges("#{engine}:\n  payload\n"), engine.to_s
        end

        %w[ruby javascript css].each do |engine|
          assert_equal [[0, 3]], ranges("#{engine}:\n  outer\n    nested\n  tail\n")
        end
        assert_equal [[0, 1]], ranges("javascript(type=\"module\"):\n  alert(1)\n")
      end

      def test_collects_tag_text_continuation_and_avoids_expansion_duplicates
        assert_equal [[0, 1]], ranges("p Hello\n  continued\n")
        assert_equal [[0, 1]], ranges("div: section\n  p Body\n")
      end

      def test_closes_structurally_equal_sibling_stacks_independently
        assert_equal [[0, 1], [2, 3]], ranges("ul\n  li\nul\n  li\n")
      end

      def test_keeps_a_fold_closed_by_a_malformed_dedented_line
        assert_equal [[0, 1]], ranges("div\n  p Body\np(class=\n")
      end

      def test_ignores_non_structural_multiline_constructs
        ["/ comment\n  hidden\n", "| text\n  continuation\n", "<div>\n  text\n",
         "div(\n  class=\"box\"\n)\n"].each do |source|
          assert_empty ranges(source), source.inspect
        end
      end

      def test_results_are_immutable_values
        result = collector.call("div\n  p Body\n")
        assert_predicate result, :frozen?
        assert_predicate result.first, :frozen?
        assert_raises(FrozenError) { result.first.end_line = 3 }
      end

      def test_rejects_unsupported_source_encodings
        assert_empty collector.call("div\r  p Body")
        assert_empty collector.call("\xFF".dup.force_encoding(Encoding::UTF_8))
      end

      def test_unexpected_exceptions_propagate
        klass = Class.new(StructureCollector) do
          private

          def parse_line_indicators = raise("unexpected")
        end

        assert_raises(RuntimeError) { klass.new(default_tag: "div").call("p Hello\n") }
      end

      private

      def collector = StructureCollector.new(default_tag: "div")
      def ranges(source) = collector.call(source).map { |region| [region.start_line, region.end_line] }
    end
  end
end
