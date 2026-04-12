# frozen_string_literal: true

module Kettle
  module Jem
    module SnippetInjector
      Result = Struct.new(
        :content,
        :changed,
        :relocated,
        :match_count,
        :warning,
        keyword_init: true,
      )

      module_function

      def inject(content:, snippet:, anchor_finder:, replace_existing: false)
        original_content = content.to_s
        managed_snippet = normalize_snippet(snippet)
        matches = snippet_matches(original_content, managed_snippet)

        if replace_existing && matches.size > 1
          return Result.new(
            content: original_content,
            changed: false,
            relocated: false,
            match_count: matches.size,
            warning: "Skipped relocating managed snippet: found #{matches.size} matches.",
          )
        end

        if !replace_existing && matches.any?
          return Result.new(
            content: original_content,
            changed: false,
            relocated: false,
            match_count: matches.size,
          )
        end

        relocated = replace_existing && matches.one?
        working_content =
          if relocated
            remove_snippet_match(original_content, matches.first)
          else
            original_content
          end

        injection_point = anchor_finder.call(working_content)
        injected_content =
          if injection_point
            splice_after_anchor(working_content, injection_point, managed_snippet)
          else
            append_to_end_of_file(working_content, managed_snippet)
          end

        Result.new(
          content: injected_content,
          changed: injected_content != original_content,
          relocated: relocated && injected_content != original_content,
          match_count: matches.size,
        )
      end

      def normalize_snippet(snippet)
        snippet.to_s.rstrip + "\n"
      end
      private_class_method :normalize_snippet

      def snippet_matches(content, managed_snippet)
        matches = []
        offset = 0
        while (index = content.index(managed_snippet, offset))
          matches << {start: index, finish: index + managed_snippet.length}
          offset = index + managed_snippet.length
        end
        matches
      end
      private_class_method :snippet_matches

      def remove_snippet_match(content, match)
        before = content[0...match[:start]]
        after = content[match[:finish]..] || ""
        return after.sub(/\A\n+/, "") if before.empty?

        collapse_joining_newlines(before, after)
      end
      private_class_method :remove_snippet_match

      def collapse_joining_newlines(before, after)
        return before + after unless before.end_with?("\n") && after.start_with?("\n")

        trailing = before[/\n+\z/].length
        stripped_before = before.sub(/\n+\z/, "")
        stripped_after = after.sub(/\A\n+/, "")
        stripped_before + ("\n" * trailing) + stripped_after
      end
      private_class_method :collapse_joining_newlines

      def splice_after_anchor(content, injection_point, managed_snippet)
        lines = content.lines
        start_line = statement_start_line(injection_point.anchor)
        end_line = expand_following_blank_lines(lines, statement_end_line(injection_point.anchor))
        return append_to_end_of_file(content, managed_snippet) unless start_line && end_line

        replacement = lines[(start_line - 1)..(end_line - 1)].join + managed_snippet.rstrip + "\n\n"

        Ast::Merge::StructuralEdit::PlanSet.new(
          source: content,
          plans: [
            Ast::Merge::StructuralEdit::SplicePlan.new(
              source: content,
              replace_start_line: start_line,
              replace_end_line: end_line,
              replacement: replacement,
            ),
          ],
        ).merged_content
      end
      private_class_method :splice_after_anchor

      def statement_start_line(statement)
        statement.start_line || statement.node&.location&.start_line
      end
      private_class_method :statement_start_line

      def statement_end_line(statement)
        statement.end_line || statement.node&.location&.end_line
      end
      private_class_method :statement_end_line

      def expand_following_blank_lines(lines, line_number)
        last_line = line_number
        while blank_line?(lines[last_line])
          last_line += 1
        end
        last_line
      end
      private_class_method :expand_following_blank_lines

      def blank_line?(line)
        !line.nil? && line.strip.empty?
      end
      private_class_method :blank_line?

      def append_to_end_of_file(content, managed_snippet)
        body = content.rstrip
        return managed_snippet if body.empty?

        body + "\n\n" + managed_snippet
      end
      private_class_method :append_to_end_of_file
    end
  end
end
