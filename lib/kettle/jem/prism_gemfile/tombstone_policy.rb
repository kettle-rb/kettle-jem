# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemfile
      # Named contract for explained commented-out Gemfile dependency tombstones.
      module TombstonePolicy
        COMMENTED_GEM_CALL = /^\s*#\s*gem(?:\s+|\()(?<quote>["'])(?<name>[^"']+)\k<quote>/

        module_function

        def collect_commented_gem_tombstones(content, collect_context_ranges:, context_for_line:)
          result = PrismUtils.parse_with_comments(content)
          return [] unless result.success?

          ranges = collect_context_ranges.call(result.value.statements)
          lines = content.to_s.lines

          lines.each_with_index.with_object([]) do |(line, index), tombstones|
            match = COMMENTED_GEM_CALL.match(line)
            next unless match
            next unless explained_commented_gem?(lines, index)

            line_number = index + 1
            block_start_line = commented_gem_block_start_line(lines, index)
            block_end_index = commented_gem_block_end_index(lines, index)
            tombstones << {
              name: match[:name],
              context: context_for_line.call(line_number, ranges),
              slice: line.rstrip,
              line: line_number,
              block_start_line: block_start_line,
              trailing_blank_lines: block_end_index - index,
              block_text: lines[(block_start_line - 1)..block_end_index].join,
            }
          end
        end

        def explained_commented_gem?(lines, index)
          cursor = index - 1
          saw_explanatory_comment = false

          while cursor >= 0
            line = lines[cursor]
            break unless line.match?(/^\s*#/)

            saw_explanatory_comment ||= !COMMENTED_GEM_CALL.match?(line)
            cursor -= 1
          end

          saw_explanatory_comment
        end

        def commented_gem_tombstone_line_ranges(lines)
          lines.each_with_index.with_object([]) do |(line, index), ranges|
            next unless COMMENTED_GEM_CALL.match?(line)
            next unless explained_commented_gem?(lines, index)

            ranges << {
              start_line: commented_gem_block_start_line(lines, index),
              end_line: index + 1,
            }
          end
        end

        def commented_gem_block_start_line(lines, index)
          cursor = index

          while cursor.positive?
            previous = lines[cursor - 1]
            break if previous.to_s.strip.empty?
            break unless previous.match?(/^\s*#/)

            cursor -= 1
          end

          cursor + 1
        end

        def commented_gem_block_end_index(lines, index)
          finish = index

          while finish + 1 < lines.length && lines[finish + 1].strip.empty?
            finish += 1
          end

          finish
        end
      end
    end
  end
end
