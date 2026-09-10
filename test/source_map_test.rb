# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_lsp/ruby_lsp_slim/source_map"

class SourceMapTest < Minitest::Test
  Core = RubyLsp::RubyLspSlim

  def test_immutable_span
    span = Core::Span.new(2, 5)
    assert span.frozen?
    assert_equal 3, span.length
    assert_equal 2...5, span.range
    assert span.cover?(4)
    refute span.cover?(5)
    assert_raises(FrozenError) { span.start_offset = 3 }
  end

  def test_unicode_positions_round_trip_and_reject_split_characters
    source = "| é😀\r\n= footer"
    [Encoding::UTF_8, Encoding::UTF_16LE, Encoding::UTF_32].each do |encoding|
      positions = Core::Positions.new(source, encoding)
      [0, 2, 4, 8, 10, source.bytesize].each do |byte|
        assert_equal byte, positions.byte_offset(positions.position(byte)), [encoding, byte].inspect
      end
      assert_raises(Core::InvalidPosition) { positions.position(5) }
      assert_raises(Core::InvalidPosition) { positions.position(9) }
      assert_raises(Core::InvalidPosition) { positions.byte_offset(line: 2, character: 0) }
    end
    positions = Core::Positions.new(source, Encoding::UTF_16LE)
    assert_raises(Core::InvalidPosition) { positions.byte_offset(line: 0, character: 4) }
    assert_equal({ line: 0, character: 5 }, positions.position(8))
  end

  def test_copies_and_endpoint_affinity
    map = Core::SourceMap.new("= foo")
    map.copy(Core::Span.new(2, 5))
    map.synthetic(";\n", :separator, Core::Span.new(2, 5))
    map.finish
    assert_equal "foo;\n", map.ruby
    assert_equal 0, map.generated_offset(2)
    assert_equal 3, map.generated_offset(5)
    assert_equal 5, map.original_offset(3)
    assert_equal Core::Span.new(5, 5), map.edit_span(Core::Span.new(3, 3))
    assert_raises(Core::UnmappedPosition) { map.generated_offset(1) }
    assert_raises(Core::UnsafeEdit) { map.edit_span(Core::Span.new(4, 4)) }
    assert map.segments.all?(&:frozen?)
  end

  def test_contiguous_copy_segments_can_map_exactly_but_host_gaps_cannot
    map = Core::SourceMap.new("= foo\n= bar")
    map.copy(Core::Span.new(2, 3))
    map.copy(Core::Span.new(3, 5))
    map.copy(Core::Span.new(8, 11))
    map.finish
    assert_equal Core::Span.new(2, 5), map.exact_span(Core::Span.new(0, 3))
    assert_raises(Core::UnsafeEdit) { map.edit_span(Core::Span.new(0, 6)) }
    assert_raises(Core::UnsafeEdit) { map.edit_span(Core::Span.new(3, 3)) }
    mapped = map.read_range(Core::Span.new(0, 6))
    assert_equal :envelope, mapped.kind
    assert_equal Core::Span.new(2, 11), mapped.span
  end

  def test_value_wrappers_preserve_token_end_affinity_but_are_not_editable
    owner = Core::Span.new(2, 5)
    map = Core::SourceMap.new("= foo")
    map.synthetic("[(", :value_open, owner)
    map.copy(owner)
    map.synthetic(")]", :value_close, owner)
    map.finish
    assert_equal 2, map.generated_offset(2)
    assert_equal 5, map.generated_offset(5)
    assert_equal owner, map.exact_span(Core::Span.new(2, 5))
    assert_equal Core::Span.new(5, 5), map.edit_span(Core::Span.new(5, 5))
    assert_raises(Core::UnsafeEdit) { map.edit_span(Core::Span.new(6, 6)) }
    [Core::Span.new(0, 2), Core::Span.new(5, 7)].each do |span|
      assert_equal :owner, map.read_range(span).kind
      assert_equal owner, map.read_range(span).span
      assert_raises(Core::UnmappedPosition) { map.exact_span(span) }
      assert_raises(Core::UnsafeEdit) { map.edit_span(span) }
    end
    assert_equal :envelope, map.read_range(Core::Span.new(0, 7)).kind
  end

  def test_synthetic_ranges_have_owners_not_edit_locations
    owner = Core::Span.new(2, 10)
    map = Core::SourceMap.new("- if ready")
    map.copy(owner)
    map.synthetic("\n", :separator, owner)
    map.synthetic("end\n", :end, owner)
    map.finish
    span = Core::Span.new(9, 12)
    assert_equal :owner, map.read_range(span).kind
    assert_equal owner, map.read_range(span).span
    assert_equal owner, map.read_range(Core::Span.new(13, 13)).span
    assert_raises(Core::UnmappedPosition) { map.exact_span(span) }
    assert_raises(Core::UnsafeEdit) { map.edit_span(span) }
    assert_raises(Core::UnsafeEdit) { map.edit_span(Core::Span.new(9, 9)) }
    assert_raises(Core::UnmappedPosition) { map.read_range(Core::Span.new(13, 14)) }
    assert_raises(Core::UnmappedPosition) { map.read_range(Core::Span.new(-1, 0)) }
  end
end
