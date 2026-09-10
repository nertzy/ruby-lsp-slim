# frozen_string_literal: true

module RubyLsp
  module RubyLspSlim
    class Error < StandardError; end
    class InvalidPosition < Error; end
    class UnmappedPosition < Error; end
    class UnsafeEdit < Error; end

    module ImmutableValue
      def initialize(*values)
        super
        freeze
      end
    end

    # All spans are half-open byte intervals, independent of negotiated LSP
    # encoding. Only Positions translates between bytes and line/code-unit pairs.
    Span = Struct.new(:start_offset, :end_offset) do
      include ImmutableValue

      def self.from_location(location)
        new(location.start_offset, location.end_offset)
      end

      def length = end_offset - start_offset
      def empty? = start_offset == end_offset
      def range = start_offset...end_offset
      def cover?(offset) = range.cover?(offset)
    end

    # A copied segment has a byte-for-byte original interval. A synthetic segment
    # has only an owner: useful for explaining an error, never permission to edit.
    Segment = Struct.new(:kind, :generated, :original, :owner) do
      include ImmutableValue
    end

    MappedRange = Struct.new(:kind, :span) do
      include ImmutableValue
    end

    ProjectionDiagnostic = Struct.new(:message, :span, :severity) do
      include ImmutableValue
    end

    # Reject split characters and newline interiors rather than rounding a cursor
    # onto a different token. UTF-8 LSP columns count bytes; UTF-16/32 count units.
    class Positions
      Line = Struct.new(:start_offset, :content_end, :end_offset) do
        include ImmutableValue
      end

      attr_reader :lines

      def initialize(source, encoding)
        raise InvalidPosition unless source.valid_encoding?

        @source = source
        @encoding = encoding
        @lines = []
        offset = 0
        source.each_line do |line|
          content = line.delete_suffix("\n").delete_suffix("\r")
          @lines << Line.new(offset, offset + content.bytesize, offset + line.bytesize)
          offset += line.bytesize
        end
        @lines << Line.new(offset, offset, offset) if source.empty? || source.end_with?("\n")
        @lines.freeze
      end

      def byte_offset(position)
        line_number = position[:line]
        column = position[:character]
        unless line_number.is_a?(Integer) && column.is_a?(Integer) && line_number >= 0 && column >= 0
          raise InvalidPosition
        end

        line = @lines[line_number]
        raise InvalidPosition unless line

        units = 0
        offset = line.start_offset
        @source.byteslice(line.start_offset...line.content_end).each_char do |character|
          return offset if units == column

          units += width(character)
          offset += character.bytesize
        end
        raise InvalidPosition unless units == column

        offset
      end

      def position(offset)
        raise InvalidPosition unless offset.is_a?(Integer) && offset.between?(0, @source.bytesize)

        line_number = @lines.rindex { |line| line.start_offset <= offset }
        line = @lines.fetch(line_number)
        raise InvalidPosition if offset > line.content_end

        prefix = @source.byteslice(line.start_offset...offset)
        raise InvalidPosition unless prefix.valid_encoding?

        { line: line_number, character: width(prefix) }
      end

      private

      def width(text)
        case @encoding
        when Encoding::UTF_8 then text.bytesize
        when Encoding::UTF_16, Encoding::UTF_16LE, Encoding::UTF_16BE
          text.encode(Encoding::UTF_16LE).bytesize / 2
        when Encoding::UTF_32, Encoding::UTF_32LE, Encoding::UTF_32BE then text.length
        else raise InvalidPosition
        end
      end
    end

    # Emission partitions generated Ruby into ordered segments. Original intervals
    # need not be adjacent or ordered: Slim may omit markup or reorder attributes.
    class SourceMap
      attr_reader :ruby, :segments

      def initialize(source)
        @source = source
        @ruby = +""
        @segments = []
      end

      def copy(span)
        unless span.start_offset.between?(0, span.end_offset) && span.end_offset <= @source.bytesize
          raise UnmappedPosition
        end

        append(@source.byteslice(span.range), :copy, span, span)
      end

      def synthetic(text, kind, owner)
        append(text, kind, nil, owner)
      end

      def finish
        @ruby.freeze
        @segments.freeze
        freeze
      end

      def generated_offset(original)
        raise UnmappedPosition unless original.is_a?(Integer) && original.between?(0, @source.bytesize)

        candidates = @segments.filter_map do |segment|
          next unless segment.original && original.between?(segment.original.start_offset, segment.original.end_offset)

          segment.generated.start_offset + original - segment.original.start_offset
        end.uniq
        raise UnmappedPosition unless candidates.length == 1

        candidates.first
      end

      def original_offset(generated)
        insertion_offset(generated)
      end

      # Exactness requires continuity in BOTH domains. Adjacent generated copies
      # can straddle omitted indentation/markup, which must not become an edit.
      def exact_span(span)
        validate_span(span)
        if span.empty?
          offset = insertion_offset(span.start_offset)
          return Span.new(offset, offset)
        end

        touched = overlapping(span)
        cursor = span.start_offset
        original_start = nil
        original_end = nil
        touched.each do |segment|
          raise UnmappedPosition unless segment.original && segment.generated.start_offset <= cursor

          original = original_overlap(segment, span)
          raise UnmappedPosition if original_end && original_end != original.start_offset

          original_start ||= original.start_offset
          original_end = original.end_offset
          cursor += original.length
        end
        raise UnmappedPosition unless original_start && cursor == span.end_offset

        Span.new(original_start, original_end)
      end

      def edit_span(span)
        exact_span(span)
      rescue UnmappedPosition
        raise UnsafeEdit
      end

      # Read-only extents may enclose omitted host text or point at the owner of
      # synthetic Ruby. Keep this fallback out of edit_span, even for diagnostics
      # that happen to resemble fixable Ruby errors.
      def read_range(span)
        MappedRange.new(:exact, exact_span(span))
      rescue UnmappedPosition
        validate_span(span)
        touched = overlapping(span)
        if span.empty?
          touched = @segments.select { |segment| segment.generated.cover?(span.start_offset) }
          touched = [@segments.last].compact if touched.empty? && span.start_offset == @ruby.bytesize
        end
        raise UnmappedPosition if touched.empty?

        originals = touched.map do |segment|
          segment.original ? original_overlap(segment, span) : segment.owner
        end
        raise UnmappedPosition if originals.any?(&:nil?)

        kind = touched.all? { |segment| segment.original.nil? } ? :owner : :envelope
        envelope = Span.new(originals.map(&:start_offset).min, originals.map(&:end_offset).max)
        MappedRange.new(kind, envelope)
      end

      private

      def insertion_offset(offset)
        raise UnmappedPosition unless offset.is_a?(Integer) && offset.between?(0, @ruby.bytesize)

        containing = @segments.find { |segment| segment.generated.cover?(offset) }
        raise UnmappedPosition if containing && !containing.original && !left_affinity?(containing, offset)

        # Insertions include copy endpoints, unlike nonempty half-open spans.
        # At a join, both copies must agree on the same original byte offset.
        candidates = @segments.filter_map do |segment|
          next unless segment.original && offset.between?(segment.generated.start_offset, segment.generated.end_offset)

          segment.original.start_offset + offset - segment.generated.start_offset
        end.uniq
        raise UnmappedPosition unless candidates.length == 1

        candidates.first
      end

      # At a copied expression's end, insertion before its delimiter, value
      # closer, or implicit do has left affinity. Synthetic interiors do not.
      def left_affinity?(segment, offset)
        segment.generated.start_offset == offset && %i[separator do value_close].include?(segment.kind)
      end

      # Clip to one copied interval, then translate by its constant byte delta.
      # Callers decide whether neighboring intervals may be joined or attributed.
      def original_overlap(segment, span)
        start = [span.start_offset, segment.generated.start_offset].max
        finish = [span.end_offset, segment.generated.end_offset].min
        delta = segment.original.start_offset - segment.generated.start_offset
        Span.new(start + delta, finish + delta)
      end

      def overlapping(span)
        @segments.select do |segment|
          segment.generated.start_offset < span.end_offset && segment.generated.end_offset > span.start_offset
        end
      end

      def append(text, kind, original, owner)
        return if text.empty?

        start = @ruby.bytesize
        @ruby << text
        @segments << Segment.new(kind, Span.new(start, @ruby.bytesize), original, owner)
      end

      def validate_span(span)
        unless span.start_offset.is_a?(Integer) && span.end_offset.is_a?(Integer) &&
               span.start_offset.between?(0, span.end_offset) && span.end_offset <= @ruby.bytesize
          raise UnmappedPosition
        end
      end
    end
  end
end
