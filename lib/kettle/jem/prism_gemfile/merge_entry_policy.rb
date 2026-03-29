# frozen_string_literal: true


module Kettle
  module Jem
    module PrismGemfile
      # Named contract for which top-level Gemfile statements participate in the
      # merge pre-filter, and how they are matched by signature.
      module MergeEntryPolicy
        MERGEABLE_CALLS = %i[gem source gemspec git_source eval_gemfile].freeze
        SINGLETON_CALLS = %i[source gemspec].freeze

        module_function

        def mergeable_statement?(stmt)
          return false if stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode)
          return false unless stmt.is_a?(Prism::CallNode)
          return false if stmt.block && stmt.name != :git_source

          MERGEABLE_CALLS.include?(stmt.name)
        end

        def signature_for(node)
          return unless node.is_a?(Prism::CallNode)
          return unless MERGEABLE_CALLS.include?(node.name)
          return [node.name] if SINGLETON_CALLS.include?(node.name)

          first_arg = node.arguments&.arguments&.first

          if node.name == :eval_gemfile && first_arg.is_a?(Prism::StringNode)
            return [:eval_gemfile, normalize_eval_gemfile_path(first_arg.unescaped.to_s)]
          end

          arg_value = case first_arg
          when Prism::StringNode
            first_arg.unescaped.to_s
          when Prism::SymbolNode
            first_arg.unescaped.to_sym
          end

          arg_value ? [node.name, arg_value] : nil
        end

        def filter_content(content, tombstone_line_ranges:)
          parse_result = PrismUtils.parse_with_comments(content)
          return content unless parse_result.success?

          lines = content.to_s.lines
          top_level_stmts = PrismUtils.extract_statements(parse_result.value.statements)

          ranges = top_level_stmts.filter_map do |stmt|
            next unless mergeable_statement?(stmt)

            {
              start_line: attached_leading_comment_start_line(lines, stmt.location.start_line),
              end_line: stmt.location.end_line,
            }
          end
          ranges.concat(tombstone_line_ranges.call(lines))

          return "" if ranges.empty?

          merge_line_ranges(ranges).map do |range|
            lines[(range[:start_line] - 1)..(range[:end_line] - 1)].join.rstrip
          end.join("\n\n") + "\n"
        end

        def attached_leading_comment_start_line(lines, line_number)
          cursor = line_number - 1

          while cursor.positive?
            previous = lines[cursor - 1]
            break if previous.to_s.strip.empty?
            break unless previous.match?(/^\s*#/)

            cursor -= 1
          end

          cursor + 1
        end

        def merge_line_ranges(ranges)
          ranges
            .sort_by { |range| [range[:start_line], range[:end_line]] }
            .each_with_object([]) do |range, merged|
              previous = merged.last
              if previous && range[:start_line] <= (previous[:end_line] + 1)
                previous[:end_line] = [previous[:end_line], range[:end_line]].max
              else
                merged << range.dup
              end
            end
        end

        # Normalize an eval_gemfile path by stripping Ruby-version bucket segments.
        #
        # Modular gemfile subdirectories follow the pattern:
        #   ../../<gem_name>/<ruby_bucket>/<version>.gemfile
        # where <ruby_bucket> is a directory like `r3`, `r4`, `r33`, etc.
        # (the major Ruby version for which the constraint applies).
        #
        # When the project's minimum Ruby version changes, the template emits paths
        # with a different bucket (e.g. r4 vs r3). Without normalization, SmartMerger
        # treats those as distinct nodes and appends the new one alongside the old
        # one, duplicating the dependency.
        #
        # By stripping the bucket, ../../erb/r3/v5.0.gemfile and
        # ../../erb/r4/v5.0.gemfile both map to the canonical signature
        # ../../erb/v5.0.gemfile, so SmartMerger recognizes them as the same
        # dependency and lets the template version win.
        #
        # @param path [String] Raw eval_gemfile path
        # @return [String] Canonicalized path with ruby-version bucket removed
        def normalize_eval_gemfile_path(path)
          path.gsub(%r{/r\d+/}, "/")
        end
      end
    end
  end
end
