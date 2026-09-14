# frozen_string_literal: true

require "slim"
require_relative "source_map"

module RubyLsp
  module RubyLspSlim
    FoldRegion = Struct.new(:start_line, :end_line) do
      include ImmutableValue
    end

    # Collects original-template structure while Slim's parser still owns the
    # indentation grammar. Instrumentation is deliberately based on parser tree
    # and stack identity; filter contents never re-enter the Slim line parser.
    class StructureCollector < Slim::Parser
      EMPTY_REGIONS = [].freeze

      def call(source)
        return EMPTY_REGIONS unless source.valid_encoding?
        return EMPTY_REGIONS if source.match?(/\r(?!\n)/)

        @source_lines = source.split(/\r?\n/)
        @regions = []
        @frames = {}.compare_by_identity
        @text_extents = {}.compare_by_identity
        @last_nonblank_line = nil

        super
        close_at_eof
        frozen_regions
      rescue Slim::Parser::SyntaxError
        frozen_regions
      ensure
        @source_lines = @regions = @frames = @text_extents = nil
      end

      protected

      def parse_line
        stacks_before = @stacks.dup
        previous_nonblank = @last_nonblank_line
        current_line = @lineno - 1
        current_line_nonblank = !@orig_line.match?(/\A\s*\z/)

        @line_indicator_syntax_error = false
        begin
          super
        rescue Slim::Parser::SyntaxError
          close_disappeared_frames(stacks_before, previous_nonblank) if @line_indicator_syntax_error
          raise
        end

        close_disappeared_frames(stacks_before, previous_nonblank)
        mark_surviving_frames(stacks_before, current_line) if current_line_nonblank
        @last_nonblank_line = last_nonblank_consumed_since(current_line) || previous_nonblank
      end

      def parse_line_indicators
        opening_line = @lineno - 1
        stacks_before = @stacks.dup
        sizes = stacks_before.to_h { |stack| [stack, stack.length] }.compare_by_identity

        super

        nodes = stacks_before.flat_map { |stack| stack.drop(sizes.fetch(stack)) }
        new_stacks = @stacks.reject { |stack| identity_member?(stacks_before, stack) }
        new_stacks.each do |stack|
          owner = nodes.lazy.map { |node| structural_owner(node, stack) }.find(&:itself)
          @frames[stack] = Frame.new(opening_line, false) if owner
        end
        collect_text_regions(nodes, opening_line)
      rescue Slim::Parser::SyntaxError
        @line_indicator_syntax_error = true
        raise
      end

      def parse_text_block(...)
        opening_line = @lineno - 1
        tree = super
        last_line = (@lineno - 1).downto(opening_line + 1).find do |line|
          !@source_lines.fetch(line, "").match?(/\A\s*\z/)
        end
        @text_extents[tree] = last_line if last_line
        tree
      end

      private

      Frame = Struct.new(:start_line, :has_body)

      def structural_owner(node, stack)
        return unless node.is_a?(Array)
        return node if structural_node?(node) && contains_identity?(node, stack)

        node.each do |child|
          owner = structural_owner(child, stack)
          return owner if owner
        end
        nil
      end

      def structural_node?(node)
        [%i[html tag], %i[slim control], %i[slim output]].include?(node.first(2))
      end

      def contains_identity?(node, sought)
        node.any? { |child| child.equal?(sought) || (child.is_a?(Array) && contains_identity?(child, sought)) }
      end

      def collect_text_regions(nodes, opening_line)
        walk(nodes) do |node|
          next unless node.first(2) == %i[slim embedded] || node.first(3) == %i[slim text inline]

          add_text_region(opening_line, node[3])
        end
      end

      def walk(value, &block)
        return unless value.is_a?(Array)

        yield value
        value.each { |child| walk(child, &block) if child.is_a?(Array) }
      end

      def add_text_region(opening_line, tree)
        end_line = @text_extents[tree]
        @regions << FoldRegion.new(opening_line, end_line) if end_line && end_line > opening_line
      end

      def last_nonblank_consumed_since(first_line)
        (@lineno - 1).downto(first_line).find do |line|
          !@source_lines.fetch(line, "").match?(/\A\s*\z/)
        end
      end

      def close_disappeared_frames(stacks_before, end_line)
        stacks_before.each do |stack|
          close_frame(stack, end_line) unless identity_member?(@stacks, stack)
        end
      end

      def mark_surviving_frames(stacks_before, current_line)
        stacks_before.each do |stack|
          frame = @frames[stack]
          frame.has_body = true if frame && identity_member?(@stacks, stack) && current_line > frame.start_line
        end
      end

      def identity_member?(stacks, sought)
        stacks.any? { |stack| stack.equal?(sought) }
      end

      def close_frame(stack, end_line)
        frame = @frames.delete(stack)
        return unless frame&.has_body && end_line && end_line > frame.start_line

        @regions << FoldRegion.new(frame.start_line, end_line)
      end

      def close_at_eof
        @frames.each_key { |stack| close_frame(stack, @last_nonblank_line) }
      end

      def frozen_regions
        (@regions || []).uniq { |region| [region.start_line, region.end_line] }
                        .sort_by { |region| [region.start_line, region.end_line] }
                        .freeze
      end
    end
  end
end
