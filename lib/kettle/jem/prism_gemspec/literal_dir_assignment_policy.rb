# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      module LiteralDirAssignmentPolicy
        def union_literal_dir_assignment(content, field:, template_content:, destination_content:)
          merged_context = gemspec_context(content)
          template_context = gemspec_context(template_content)
          destination_context = gemspec_context(destination_content)
          return content unless template_context && destination_context

          template_node = find_field_node(template_context[:stmt_nodes], template_context[:blk_param], field)
          destination_node = find_field_node(destination_context[:stmt_nodes], destination_context[:blk_param], field)
          return content unless template_node && destination_node

          merged_node = merged_context && find_field_node(merged_context[:stmt_nodes], merged_context[:blk_param], field)

          if merged_node
            exact_destination_source = fallback_field_assignment(destination_content, field)&.fetch(:source) || destination_node.slice

            replacement = merge_dir_assignment_source(
              merged_source: merged_node.slice,
              template_source: template_node.slice,
              destination_source: destination_node.slice,
            )
            replacement ||= preserve_destination_nonliteral_assignment_source(
              merged_source: merged_node.slice,
              destination_source: exact_destination_source,
            )
            return content unless replacement

            return apply_dir_assignment_replacement(
              content: content,
              replacement: replacement,
              start_line: merged_node.location.start_line,
              end_line: merged_node.location.end_line,
              field: field,
            )
          end

          fallback_nonliteral_destination_assignment(
            content: content,
            field: field,
            template_source: template_node.slice,
            destination_source: destination_node.slice,
            destination_content: destination_content,
          )
        end

        def apply_dir_assignment_replacement(content:, replacement:, start_line:, end_line:, field:)
          return content unless replacement

          merged_content_from_plans(
            content: content,
            plans: [
              build_splice_plan(
                content: content,
                replacement: replacement,
                start_line: start_line,
                end_line: end_line,
                metadata: {
                  source: :kettle_jem_prism_gemspec,
                  edit: :union_literal_dir_assignment,
                  field: field,
                },
              ),
            ],
            metadata: {source: :kettle_jem_prism_gemspec, edit: :union_literal_dir_assignment, field: field},
          )
        end

        def fallback_nonliteral_destination_assignment(content:, field:, template_source:, destination_source:, destination_content:)
          return content unless multiline_collection_parts(template_source)
          return content if multiline_collection_parts(destination_source)

          assignment = fallback_field_assignment(content, field)
          return content unless assignment

          exact_destination_source = fallback_field_assignment(destination_content, field)&.fetch(:source) || destination_source

          replacement = preserve_destination_nonliteral_assignment_source(
            merged_source: assignment[:source],
            destination_source: exact_destination_source,
          )
          return content unless replacement

          apply_dir_assignment_replacement(
            content: content,
            replacement: replacement + assignment[:trailing_source].to_s,
            start_line: assignment[:start_line],
            end_line: assignment[:end_line],
            field: field,
          )
        end

        def fallback_field_assignment(content, field)
          lines = content.to_s.lines
          start_index = lines.index { |line| line.match?(field_assignment_start_pattern(field)) }
          return unless start_index

          end_index = lines.length - 1
          trailing_source = nil

          if lines[end_index].to_s.strip == "endend"
            trailing_source = "end\n"
          elsif lines[end_index].to_s.match?(/^\s*end\s*$/) && end_index > start_index
            end_index -= 1
            trailing_source = lines.last
          end

          {
            source: lines[start_index..end_index].join,
            start_line: start_index + 1,
            end_line: end_index + 1,
            trailing_source: trailing_source,
          }
        end


        def field_assignment_start_pattern(field)
          /^\s*[\w:]+\.#{Regexp.escape(field)}\s*=/
        end

        def merge_dir_assignment_source(merged_source:, template_source:, destination_source:)
          merged_parts = multiline_collection_parts(merged_source)
          template_parts = multiline_collection_parts(template_source)
          destination_parts = multiline_collection_parts(destination_source)
          return unless merged_parts && template_parts && destination_parts

          combined_groups = []
          seen = {}

          [destination_parts[:groups], merged_parts[:groups], template_parts[:groups]].each do |groups|
            groups.each do |group|
              next if seen[group[:key]]

              combined_groups << group
              seen[group[:key]] = true
            end
          end

          merged_parts[:opening] + combined_groups.flat_map { |group| group[:lines] }.join + merged_parts[:closing]
        end

        def multiline_collection_parts(source)
          lines = source.to_s.lines
          return if lines.length < 3

          return unless literal_dir_collection_boundaries?(lines)

          groups = literal_collection_groups(lines[1...-1])
          return unless groups

          {
            opening: lines.first,
            closing: lines.last,
            groups: groups,
          }
        end

        def literal_collection_groups(lines)
          pending = []
          groups = []

          lines.each do |line|
            if line.strip.empty? || line.lstrip.start_with?("#")
              pending << line
              next
            end

            return unless literal_collection_entry_line?(line)

            groups << {
              key: normalize_collection_entry_key(line),
              lines: pending + [line],
            }
            pending = []
          end

          groups
        end

        def literal_dir_collection_boundaries?(lines)
          opening = lines.first.to_s
          closing = lines.last.to_s

          opening.match?(/^\s*[\w.]+\s*=\s*Dir\[\s*(?:#.*)?$/) &&
            closing.match?(/^\s*\]\s*(?:#.*)?$/)
        end

        def literal_collection_entry_line?(line)
          line.to_s.strip.match?(/\A(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'),?\s*(?:#.*)?\z/)
        end

        def preserve_destination_nonliteral_assignment_source(merged_source:, destination_source:)
          return if multiline_collection_parts(destination_source)
          return if merged_source.to_s == destination_source.to_s

          destination_source
        end

        def normalize_collection_entry_key(line)
          line.to_s.sub(/\s+#.*$/, "").strip.sub(/,\z/, "")
        end
      end
    end
  end
end
