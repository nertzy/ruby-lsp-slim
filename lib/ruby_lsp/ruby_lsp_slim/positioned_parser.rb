# frozen_string_literal: true

require "slim"
require_relative "source_map"

module RubyLsp
  module RubyLspSlim
    SourcePiece = Struct.new(:text, :original, :kind) do
      include ImmutableValue
    end

    # Slim normalizes some payloads (continuations, indentation, quoted text).
    # Preserve exact slices piecewise; introduced bytes remain synthetic even
    # when they look like whitespace from the source. owner is attribution only.
    class MappedCode
      attr_reader :text, :pieces, :owner

      def initialize(text, pieces, owner)
        @text = text.dup.freeze
        @pieces = pieces.freeze
        @owner = owner
        freeze
      end

      def append(text, kind: :normalized)
        self.class.new(@text + text, @pieces + [SourcePiece.new(text.freeze, nil, kind)], @owner)
      end

      def slice(start, length)
        finish = start + length
        cursor = 0
        pieces = @pieces.filter_map do |piece|
          piece_start = cursor
          cursor += piece.text.bytesize
          left = [start, piece_start].max
          right = [finish, cursor].min
          next unless left < right

          original = if piece.original
                       first = piece.original.start_offset + left - piece_start
                       Span.new(first, first + right - left)
                     end
          text = piece.text.byteslice((left - piece_start)...(right - piece_start)).freeze
          SourcePiece.new(text, original, piece.kind)
        end
        originals = pieces.filter_map(&:original)
        owner = if originals.empty?
                  @owner
                else
                  Span.new(originals.first.start_offset, originals.last.end_offset)
                end
        self.class.new(@text.byteslice(start, length), pieces, owner)
      end
    end

    # Instrument Slim's parser without replacing its grammar or indentation rules.
    # Projection's structural-pass subclasses also depend on private Slim hooks.
    class PositionedParser < Slim::Parser
      class MappingError < Error
        attr_reader :span

        def initialize(message, span)
          @span = span
          super(message)
        end
      end

      Capture = Struct.new(:kind, :start, :cursor, :pieces)
      attr_reader :payloads, :owners, :failure_span

      def call(source)
        @source = source
        @source_lines = Positions.new(source, Encoding::UTF_8).lines
        # Equal Ruby strings at different template locations are different
        # occurrences. Slim's passes preserve or explicitly carry this identity;
        # a value-keyed hash would silently assign one occurrence another's span.
        @payloads = {}.compare_by_identity
        @owners = {}.compare_by_identity
        @captures = []
        @failure_span = Span.new(0, 0)
        super
      end

      protected

      def next_line
        result = super
        @view_end = @orig_line.bytesize if @orig_line
        result
      end

      def parse_line_indicators
        start = cursor
        stack = @stacks.last
        old_length = stack.length
        inline = @line if @line.start_with?("<")
        result = super
        owner = Span.new(start, @source_lines.fetch(@lineno - 1).content_end)
        stack.drop(old_length).each { |node| mark_owners(node, owner) }
        register(inline, [copy_piece(start, start + inline.bytesize)], owner) if inline
        result
      end

      def parse_broken_line
        start = cursor + @line.bytesize - @line.lstrip.bytesize
        capture = Capture.new(:broken, start, start, [])
        @captures << capture
        code = super
        finish = line_start + @orig_line.rstrip.bytesize
        finish_capture(capture, code, finish)
      ensure
        @captures.pop
      end

      def parse_ruby_code(delimiter)
        start = cursor
        capture = Capture.new(:attribute, start, start, [])
        @captures << capture
        code = super
        finish_capture(capture, code, cursor)
      ensure
        @captures.pop
      end

      def parse_quoted_attribute(quote)
        start = cursor
        capture = Capture.new(:quoted, start, start, [])
        @captures << capture
        text = super
        finish_capture(capture, text, cursor - quote.bytesize)
      ensure
        @captures.pop
      end

      def expect_next_line
        capture = @captures.last
        if capture
          finish = line_start + @view_end
          finish = line_start + @orig_line.rstrip.bytesize if capture.kind == :broken
          continued_quote = capture.kind == :quoted && @line == "\\"
          finish -= 1 if continued_quote
          capture.pieces << copy_piece(capture.cursor, finish)
          line = @source_lines.fetch(@lineno - 1)
          if continued_quote
            capture.pieces << SourcePiece.new(" ", nil)
          elsif line.end_offset > line.content_end
            capture.pieces << copy_piece(line.end_offset - 1, line.end_offset)
          end
          @failure_span = Span.new(capture.start, line.content_end)
        end
        result = super
        @view_end = @orig_line.rstrip.bytesize
        capture.cursor = cursor if capture
        result
      end

      def parse_text_block(first_line = nil, text_indent = nil)
        first_lineno = @lineno
        start = line_start + @orig_line.bytesize - first_line.to_s.bytesize
        tree = super
        lineno = first_lineno
        tree.drop(1).each do |node|
          if node == [:newline]
            lineno += 1
            next
          end
          next unless node[0..1] == %i[slim interpolate]

          text = node[2]
          line = @source_lines.fetch(lineno - 1)
          raw = @source.byteslice(line.start_offset...line.content_end)
          if lineno == first_lineno && first_line && !first_line.empty?
            pieces = [copy_piece(start, start + first_line.bytesize)]
            owner = Span.new(start, line.content_end)
          elsif text.match?(/\A\s*\z/)
            pieces = [SourcePiece.new(text.dup.freeze, nil)]
            owner = Span.new(line.start_offset, line.content_end)
          else
            suffix = raw.lstrip
            owner = Span.new(line.content_end - suffix.bytesize, line.content_end)
            raise MappingError.new("Unsupported Slim text normalization", owner) unless text.end_with?(suffix)

            prefix = text.byteslice(0, text.bytesize - suffix.bytesize)
            pieces = [SourcePiece.new(prefix.freeze, nil), copy_piece(owner.start_offset, owner.end_offset)]
          end
          register(text, pieces, owner)
          @owners[node] = owner
        end
        tree
      end

      def syntax_error!(message)
        @failure_span = Span.new(cursor, cursor) if @orig_line && @line
        super
      end

      private

      def line_start
        @source_lines.fetch(@lineno - 1).start_offset
      end

      def cursor
        offset = line_start + @view_end - @line.bytesize
        span = Span.new([offset, line_start].max, line_start + @orig_line.bytesize)
        unless offset >= line_start && @source.byteslice(offset, @line.bytesize) == @line
          raise MappingError.new("Unsupported Slim source normalization", span)
        end

        offset
      end

      def copy_piece(start, finish)
        raise MappingError.new("Unsupported Slim source span", Span.new(start, start)) if finish < start

        SourcePiece.new(@source.byteslice(start...finish).freeze, Span.new(start, finish))
      end

      def finish_capture(capture, text, finish)
        capture.pieces << copy_piece(capture.cursor, finish)
        register(text, capture.pieces, Span.new(capture.start, finish))
        text
      end

      def mark_owners(node, owner)
        @owners[node] ||= owner
        node.grep(Array).each { |child| mark_owners(child, owner) }
      end

      # Refuse normalization we cannot account for. A plausible substring match
      # is not provenance, especially when an expression occurs more than once.
      def register(text, pieces, owner)
        unless pieces.map(&:text).join == text
          raise MappingError.new("Unsupported Slim expression normalization", owner)
        end

        @payloads[text] = MappedCode.new(text, pieces, owner)
      end
    end
  end
end
