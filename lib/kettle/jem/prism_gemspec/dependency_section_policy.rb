# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    module PrismGemspec
      # Explicit contract for gemspec dependency-section normalization.
      #
      # Given merged gemspec content plus template/destination source content,
      # this helper normalizes dependency sections by restoring preferred
      # formatting for matched dependency signatures, suppressing development
      # dependencies that are now runtime dependencies, and keeping runtime
      # dependency blocks above the development-dependency note block while
      # carrying attached comments and spacing.
      module DependencySectionPolicy
        module_function

        GEMSPEC_DEPENDENCY_LINE_RE = /^(?<indent>\s*)spec\.(?<method>add_(?:development_|runtime_)?dependency)\s*\(?\s*(?<args>(?<quote>["'])(?<gem>[^"']+)\k<quote>.*?)(?:\s*\))?\s*(?<comment>#.*)?(?:\n|\z)/
        GEMSPEC_NOTE_BLOCK_START_RE = /^\s*# NOTE: It is preferable to list development dependencies in the gemspec due to increased/

        def normalize(content:, template_content:, destination_content:, prefer_template: false)
          lines = content.to_s.lines
          return content if lines.empty?

          preferred_lines = preferred_dependency_line_lookup(
            template_content: template_content,
            destination_content: destination_content,
            prefer_template: prefer_template,
          )

          records = dependency_records(lines)
          lines = apply_preferred_dependency_lines(lines, records, preferred_lines)
          lines = remove_runtime_shadowed_development_dependency_blocks(lines, records)

          relocate_runtime_dependency_blocks_before_note(lines)
        end

        def apply_preferred_dependency_lines(lines, records, preferred_lines)
          updated_lines = Array(lines).dup

          Array(records).each do |record|
            apply_preferred_dependency_line(updated_lines, record, preferred_lines)
          end

          updated_lines
        end

        def apply_preferred_dependency_line(updated_lines, record, preferred_lines)
          preferred = preferred_lines[dependency_lookup_key(record)]
          updated_lines[record[:line_index]] = preferred.dup if preferred
        end

        def remove_runtime_shadowed_development_dependency_blocks(lines, records)
          duplicate_dev_ranges = duplicate_runtime_shadowed_development_dependency_ranges(lines, records)
          Kettle::Jem::PrismGemspec.remove_line_ranges_with_plans(
            content: Array(lines).join,
            lines: lines,
            ranges: duplicate_dev_ranges,
            metadata: {
              source: :kettle_jem_prism_gemspec_dependency_section,
              reason: :runtime_shadowed_development_dependency,
            },
          )
        end

        def duplicate_runtime_shadowed_development_dependency_ranges(lines, records)
          index = build_dependency_index(records)

          ranges = Array(records).filter_map do |record|
            duplicate_runtime_shadowed_development_dependency_range(lines, record, runtime_gems: index[:runtime_gems])
          end

          collapse_line_ranges(ranges)
        end

        def duplicate_runtime_shadowed_development_dependency_range(lines, record, runtime_gems:)
          return unless record[:method] == "add_development_dependency" && runtime_gems.include?(record[:gem])

          range = dependency_block_range(lines, record[:line_index])
          return range unless range.begin.positive?
          return range unless lines[range.begin - 1].to_s.strip.empty?

          (range.begin - 1)..range.end
        end

        def collapse_line_ranges(ranges)
          sorted = Array(ranges).sort_by(&:begin)
          return [] if sorted.empty?

          sorted.each_with_object([]) do |range, merged|
            if merged.empty? || range.begin > merged.last.end + 1
              merged << range
            else
              previous = merged.pop
              merged << (previous.begin..[previous.end, range.end].max)
            end
          end
        end

        def relocate_runtime_dependency_blocks_before_note(lines)
          relocation_snapshot = runtime_dependency_relocation_snapshot(lines)
          return Array(lines).join unless relocation_snapshot

          moved_blocks, remaining_lines = extract_runtime_dependency_blocks_after_note(
            lines,
            relocation_snapshot[:runtime_after_note],
            relocation_snapshot[:note_end_index],
          )

          insert_blocks_before_note(remaining_lines, moved_blocks)
        end

        def runtime_dependency_relocation_snapshot(lines)
          note_index = note_block_start_index(lines)
          return unless note_index

          note_end_index = note_block_end_index(lines, note_index)
          runtime_after_note = runtime_records_after_note(lines, note_end_index)
          return if runtime_after_note.empty?

          {
            note_end_index: note_end_index,
            runtime_after_note: runtime_after_note,
          }
        end

        def extract_runtime_dependency_blocks_after_note(lines, runtime_after_note, note_end_index)
          updated_lines = Array(lines).dup
          moved_blocks = []

          Array(runtime_after_note).reverse_each do |record|
            moved_block, updated_lines = extract_runtime_dependency_block_after_note(updated_lines, record, note_end_index)
            moved_blocks.unshift(moved_block)
          end

          [moved_blocks, updated_lines]
        end

        def extract_runtime_dependency_block_after_note(lines, record, note_end_index)
          range = dependency_block_range(lines, record[:line_index], stop_above_index: note_end_index)
          moved_block = lines[range].map(&:dup)

          [
            moved_block,
            Kettle::Jem::PrismGemspec.remove_line_ranges_with_plans(
              content: Array(lines).join,
              lines: lines,
              ranges: [range],
              metadata: {
                source: :kettle_jem_prism_gemspec_dependency_section,
                reason: :runtime_dependency_relocation,
                dependency_signature: record[:signature],
              },
            ),
          ]
        end

        def note_block_start_index(lines)
          Array(lines).index { |line| GEMSPEC_NOTE_BLOCK_START_RE.match?(line) }
        end

        def note_block_end_index(lines, note_index)
          end_index = note_index

          while lines[end_index + 1]&.lstrip&.match?(/^#\s{2,}/)
            end_index += 1
          end

          end_index += 1 if lines[end_index + 1]&.strip&.empty?

          end_index
        end

        def runtime_records_after_note(lines, note_index, records: nil)
          Array(records || dependency_records(lines))
            .select { |record| runtime_record_after_note?(record, note_index) }
        end

        def runtime_record_after_note?(record, note_index)
          runtime_dependency_method?(record[:method]) && record[:line_index] > note_index
        end

        def insert_blocks_before_note(lines, blocks)
          note_index = note_block_start_index(lines)
          return lines.join unless note_index

          insertion = build_dependency_block_insertion(
            blocks,
            before_line: note_index.positive? ? lines[note_index - 1] : nil,
            after_line: lines[note_index],
          )

          (lines[0...note_index] + insertion + lines[note_index..]).join
        end

        def insertion_line_index(lines)
          note_index = note_block_start_index(lines)
          return note_block_end_index(lines, note_index) + 1 if note_index

          Array(lines).rindex { |line| line.strip == "end" } || Array(lines).length
        end

        def dependency_line_lookup(content)
          dependency_scan(content)[:lookup]
        end

        def preferred_dependency_line_lookup(template_content:, destination_content:, prefer_template: false)
          preferred_lines, fallback_lines = preferred_dependency_lookup_sources(
            template_content: template_content,
            destination_content: destination_content,
            prefer_template: prefer_template,
          )

          fill_preferred_dependency_lookup(preferred_lines, fallback_lines)
        end

        def preferred_dependency_lookup_sources(template_content:, destination_content:, prefer_template: false)
          if prefer_template
            [dependency_line_lookup(template_content), dependency_line_lookup(destination_content)]
          else
            [dependency_line_lookup(destination_content), dependency_line_lookup(template_content)]
          end
        end

        def fill_preferred_dependency_lookup(preferred_lines, fallback_lines)
          fallback_lines.each do |signature, line|
            preferred_lines[signature] ||= line
          end

          preferred_lines
        end

        def dependency_records(lines_or_content)
          dependency_scan(lines_or_content)[:records]
        end

        def development_dependency_records(lines_or_content)
          dependency_records(lines_or_content)
            .select { |record| record[:method] == "add_development_dependency" }
        end

        def dependency_record_index(lines_or_content)
          build_dependency_index(dependency_records(lines_or_content))
        end

        def build_dependency_index(records)
          Array(records).each_with_object({development_by_gem: {}, runtime_gems: Set.new}) do |record, memo|
            index_dependency_record(memo, record)
          end
        end

        def index_dependency_record(memo, record)
          if runtime_dependency_method?(record[:method])
            memo[:runtime_gems] << record[:gem]
          elsif record[:method] == "add_development_dependency"
            memo[:development_by_gem][record[:gem]] ||= record
          end

          memo
        end

        def dependency_scan(lines_or_content)
          dependency_line_source(lines_or_content).each_with_object({lookup: {}, records: []}) do |(line, idx), memo|
            payload = dependency_scan_record(line, idx)
            next unless payload

            memo[:lookup][payload[:lookup_key]] ||= payload[:normalized_line]
            memo[:records] << payload[:record]
          end
        end

        def dependency_scan_record(line, idx)
          match = dependency_line_match(line)
          return unless match

          {
            lookup_key: dependency_lookup_key(match),
            normalized_line: line.end_with?("\n") ? line : "#{line}\n",
            record: {
              line_index: idx,
              method: match[:method],
              gem: match[:gem],
              line: line.to_s,
              signature: match[:signature],
            },
          }
        end

        def dependency_line_source(lines_or_content)
          if lines_or_content.is_a?(Array)
            lines_or_content.each_with_index
          else
            lines_or_content.to_s.each_line.each_with_index
          end
        end

        def dependency_line_match(line)
          match = GEMSPEC_DEPENDENCY_LINE_RE.match(line.to_s)
          return unless match

          {
            method: match[:method],
            gem: match[:gem],
            signature: normalize_dependency_signature(match[:args]),
          }
        end

        def dependency_lookup_key(match)
          [match[:method], match[:signature]]
        end

        def normalize_dependency_signature(args_source)
          args_source.to_s.strip.gsub(/\s+/, " ")
        end

        def runtime_dependency_method?(method_name)
          %w[add_dependency add_runtime_dependency].include?(method_name.to_s)
        end

        def dependency_block_range(lines, line_index, stop_above_index: nil)
          attached_comment_start_index(lines, line_index, stop_above_index: stop_above_index)..trailing_blank_line_end_index(lines, line_index)
        end


        def build_dependency_block_insertion(blocks, before_line:, after_line:)
          insertion = []
          insertion << "\n" if needs_separator_before_blocks?(before_line)

          Array(blocks).each_with_index do |block, idx|
            insertion.concat(block)
            next if idx == blocks.length - 1

            insertion << "\n" unless block_ends_with_separator?(block)
          end

          insertion << "\n" if needs_separator_after_blocks?(after_line, insertion)
          insertion
        end

        def attached_comment_start_index(lines, line_index, stop_above_index: nil)
          start_index = line_index
          while start_index.positive?
            break if !stop_above_index.nil? && (start_index - 1) <= stop_above_index

            previous_line = lines[start_index - 1]
            break unless previous_line.lstrip.start_with?("#")

            start_index -= 1
          end
          start_index
        end

        def trailing_blank_line_end_index(lines, line_index)
          end_index = line_index
          end_index += 1 if lines[end_index + 1]&.strip&.empty?
          end_index
        end

        def block_ends_with_separator?(block)
          Array(block).last.to_s.strip.empty?
        end

        def needs_separator_before_blocks?(before_line)
          before_line && !before_line.strip.empty?
        end

        def needs_separator_after_blocks?(after_line, insertion)
          after_line && !after_line.strip.empty? && insertion.last.to_s.strip != ""
        end
      end
    end
  end
end
