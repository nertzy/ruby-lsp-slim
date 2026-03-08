# frozen_string_literal: true

module RubyLsp
  module RubyLspSlim
    # Scanner that extracts Ruby code from Slim templates while preserving byte positions.
    # Produces two same-length strings: `@ruby` contains Ruby code (with spaces where host language is)
    # and `@host_language` contains Slim markup (with spaces where Ruby code is).
    class SlimScanner
      attr_reader :ruby, :host_language

      def initialize(source)
        @source = source
        @ruby = +"" # Ruby code with spaces for non-Ruby portions
        @host_language = +"" # Host language with spaces for Ruby portions
        @current_pos = 0
        @line_start = true
        @in_ruby_filter = false
        @ruby_filter_indent = 0
      end

      def scan
        while @current_pos < @source.length
          if @line_start
            scan_line_start
          else
            scan_inline
          end
        end
      end

      private

      def scan_line_start
        # Track position at beginning of line to measure indentation
        line_begin = @current_pos

        # Consume leading whitespace
        consume_whitespace

        indent_level = @current_pos - line_begin

        # Check if we're at end of source
        return if @current_pos >= @source.length

        char = @source[@current_pos]

        # Handle ruby: filter continuation
        if @in_ruby_filter
          if indent_level > @ruby_filter_indent
            # This line is part of the ruby: filter - treat as Ruby
            scan_ruby_line_to_end
            return
          else
            # Indentation decreased, we've left the ruby: filter
            @in_ruby_filter = false
          end
        end

        case char
        when "-"
          # Control code: - ruby_code
          push_host(" ")
          @current_pos += 1

          # Consume optional space after -
          if @current_pos < @source.length && @source[@current_pos] == " "
            push_host(" ")
            @current_pos += 1
          end

          scan_ruby_line_to_end
        when "="
          # Output code: = expression or == expression
          push_host(" ")
          @current_pos += 1

          if @current_pos < @source.length && @source[@current_pos] == "="
            push_host(" ")
            @current_pos += 1
          end

          # Consume optional space after = or ==
          if @current_pos < @source.length && @source[@current_pos] == " "
            push_host(" ")
            @current_pos += 1
          end

          scan_ruby_line_to_end
        when "\n"
          push_newline
          @current_pos += 1
          @line_start = true
        when "\r"
          push_newline_cr
          @current_pos += 1
          if @current_pos < @source.length && @source[@current_pos] == "\n"
            push_newline
            @current_pos += 1
          end
          @line_start = true
        else
          # Check for ruby: filter
          if looking_at?("ruby:")
            remaining = @source[@current_pos + 5..]
            if remaining.nil? || remaining.empty? || remaining.start_with?("\n") || remaining.start_with?("\r")
              # This is a ruby: filter line
              @in_ruby_filter = true
              @ruby_filter_indent = indent_level
              push_host("ruby:")
              @current_pos += 5
              consume_to_eol_as_host
              return
            end
          end

          # Check for tag with embedded Ruby (tag= expr or tag== expr)
          scan_tag_line
        end
      end

      def scan_tag_line
        # Scan through tag name, classes, ids, etc. until we hit =, space+newline, or newline
        while @current_pos < @source.length
          char = @source[@current_pos]

          case char
          when "\n"
            push_newline
            @current_pos += 1
            @line_start = true
            return
          when "\r"
            push_newline_cr
            @current_pos += 1
            if @current_pos < @source.length && @source[@current_pos] == "\n"
              push_newline
              @current_pos += 1
            end
            @line_start = true
            return
          when "="
            # Tag output: tag= expr or tag== expr
            push_host(" ")
            @current_pos += 1

            if @current_pos < @source.length && @source[@current_pos] == "="
              push_host(" ")
              @current_pos += 1
            end

            # Consume optional space
            if @current_pos < @source.length && @source[@current_pos] == " "
              push_host(" ")
              @current_pos += 1
            end

            scan_ruby_line_to_end
            return
          when "#"
            # Check for interpolation in text
            if @current_pos + 1 < @source.length && @source[@current_pos + 1] == "{"
              push_host(" ") # #
              @current_pos += 1
              push_host(" ") # {
              @current_pos += 1
              scan_interpolation
            else
              push_host(char)
              @current_pos += 1
            end
          when " "
            # After space in a tag line, the rest is text content - scan for interpolation
            push_host(" ")
            @current_pos += 1
            scan_text_content
            return
          else
            push_host(char)
            @current_pos += 1
          end
        end
      end

      def scan_text_content
        while @current_pos < @source.length
          char = @source[@current_pos]

          case char
          when "\n"
            push_newline
            @current_pos += 1
            @line_start = true
            return
          when "\r"
            push_newline_cr
            @current_pos += 1
            if @current_pos < @source.length && @source[@current_pos] == "\n"
              push_newline
              @current_pos += 1
            end
            @line_start = true
            return
          when "#"
            if @current_pos + 1 < @source.length && @source[@current_pos + 1] == "{"
              push_host(" ") # #
              @current_pos += 1
              push_host(" ") # {
              @current_pos += 1
              scan_interpolation
            else
              push_host(char)
              @current_pos += 1
            end
          else
            push_host(char)
            @current_pos += 1
          end
        end
      end

      def scan_interpolation
        brace_depth = 1
        while @current_pos < @source.length && brace_depth > 0
          char = @source[@current_pos]

          case char
          when "{"
            brace_depth += 1
            push_ruby(char)
            @current_pos += 1
          when "}"
            brace_depth -= 1
            if brace_depth == 0
              push_host(" ") # closing }
              @current_pos += 1
            else
              push_ruby(char)
              @current_pos += 1
            end
          when "\n"
            push_newline
            @current_pos += 1
          when "\r"
            push_newline_cr
            @current_pos += 1
            if @current_pos < @source.length && @source[@current_pos] == "\n"
              push_newline
              @current_pos += 1
            end
          else
            push_ruby(char)
            @current_pos += 1
          end
        end
      end

      def scan_ruby_line_to_end
        @line_start = false
        while @current_pos < @source.length
          char = @source[@current_pos]

          case char
          when "\n"
            push_newline
            @current_pos += 1
            @line_start = true
            return
          when "\r"
            push_newline_cr
            @current_pos += 1
            if @current_pos < @source.length && @source[@current_pos] == "\n"
              push_newline
              @current_pos += 1
            end
            @line_start = true
            return
          else
            push_ruby(char)
            @current_pos += 1
          end
        end
      end

      def consume_whitespace
        while @current_pos < @source.length
          char = @source[@current_pos]
          break unless char == " " || char == "\t"

          push_host(char)
          @current_pos += 1
        end
      end

      def consume_to_eol_as_host
        while @current_pos < @source.length
          char = @source[@current_pos]
          case char
          when "\n"
            push_newline
            @current_pos += 1
            @line_start = true
            return
          when "\r"
            push_newline_cr
            @current_pos += 1
            if @current_pos < @source.length && @source[@current_pos] == "\n"
              push_newline
              @current_pos += 1
            end
            @line_start = true
            return
          else
            push_host(char)
            @current_pos += 1
          end
        end
      end

      def push_ruby(char)
        @ruby << char
        @host_language << " " * char.length
      end

      def push_host(char)
        @ruby << " " * char.length
        @host_language << char
      end

      def push_newline
        @ruby << "\n"
        @host_language << "\n"
      end

      def push_newline_cr
        @ruby << "\r"
        @host_language << "\r"
      end

      def looking_at?(str)
        @source[@current_pos, str.length] == str
      end
    end
  end
end
