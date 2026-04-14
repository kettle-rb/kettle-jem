# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      module LiteralDirAssignmentPolicy
        def union_literal_dir_assignment(content, field:, template_content:, destination_content:)
          return content if template_content.to_s.strip.empty? || destination_content.to_s.strip.empty?

          merged_context = gemspec_context(content)
          template_context = gemspec_context(template_content)
          destination_context = gemspec_context(destination_content)
          raise_malformed_dir_assignment_content!(:merged, field) unless merged_context
          raise_malformed_dir_assignment_content!(:template, field) unless template_context
          raise_malformed_dir_assignment_content!(:destination, field) unless destination_context

          template_node = find_field_node(template_context[:stmt_nodes], template_context[:blk_param], field)
          destination_node = find_field_node(destination_context[:stmt_nodes], destination_context[:blk_param], field)
          return content unless template_node && destination_node

          merged_node = find_field_node(merged_context[:stmt_nodes], merged_context[:blk_param], field)
          return content unless merged_node

          replacement = merge_dir_assignment_source(
            merged_node: merged_node,
            merged_content: content,
            template_node: template_node,
            template_content: template_content,
            destination_node: destination_node,
            destination_content: destination_content,
          )
          replacement_start_line = merged_node.location.start_line
          replacement_end_line = merged_node.location.end_line
          replacement ||= replace_destination_nonliteral_assignment_source(
            merged_node: merged_node,
            merged_content: content,
            template_node: template_node,
            template_content: template_content,
            destination_node: destination_node,
            destination_content: destination_content,
          )
          if replacement.is_a?(Hash)
            replacement_start_line = replacement.fetch(:start_line, replacement_start_line)
            replacement_end_line = replacement.fetch(:end_line, replacement_end_line)
            replacement = replacement[:replacement]
          end
          return content unless replacement

          apply_dir_assignment_replacement(
            content: content,
            replacement: replacement,
            start_line: replacement_start_line,
            end_line: replacement_end_line,
            field: field,
          )
        end

        def cleanup_destination_nonliteral_dir_assignment(content, field:, template_content:, destination_content:)
          return content if template_content.to_s.strip.empty? || destination_content.to_s.strip.empty?

          merged_context = gemspec_context(content)
          template_context = gemspec_context(template_content)
          destination_context = gemspec_context(destination_content)
          raise_malformed_dir_assignment_content!(:merged, field) unless merged_context
          raise_malformed_dir_assignment_content!(:template, field) unless template_context
          raise_malformed_dir_assignment_content!(:destination, field) unless destination_context

          template_node = find_field_node(template_context[:stmt_nodes], template_context[:blk_param], field)
          destination_node = find_field_node(destination_context[:stmt_nodes], destination_context[:blk_param], field)
          merged_node = find_field_node(merged_context[:stmt_nodes], merged_context[:blk_param], field)
          return content unless template_node && destination_node && merged_node

          replacement = replace_destination_nonliteral_assignment_source(
            merged_node: merged_node,
            merged_content: content,
            template_node: template_node,
            template_content: template_content,
            destination_node: destination_node,
            destination_content: destination_content,
          )
          return content unless replacement

          apply_dir_assignment_replacement(
            content: content,
            replacement: replacement[:replacement],
            start_line: replacement.fetch(:start_line, merged_node.location.start_line),
            end_line: replacement.fetch(:end_line, merged_node.location.end_line),
            field: field,
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

        def raise_malformed_dir_assignment_content!(role, field)
          raise Kettle::Jem::Error, "Malformed #{role} gemspec content while harmonizing #{field.inspect}."
        end

        def merge_dir_assignment_source(merged_node:, merged_content:, template_node:, template_content:, destination_node:, destination_content:)
          merged_parts = literal_dir_assignment_parts(merged_node, content: merged_content)
          template_parts = literal_dir_assignment_parts(template_node, content: template_content)
          destination_parts = literal_dir_assignment_parts(destination_node, content: destination_content)
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

        def literal_dir_assignment_parts(field_node, content:)
          rhs_node = literal_dir_assignment_rhs_node(field_node)
          return unless literal_dir_call_node?(rhs_node)

          lines = full_field_assignment_source(field_node, content).lines
          return if lines.length < 3

          groups = literal_collection_groups(field_node: field_node, rhs_node: rhs_node, lines: lines)
          return unless groups

          {
            opening: lines.first,
            closing: lines.last,
            groups: groups,
          }
        end

        def literal_collection_groups(field_node:, rhs_node:, lines:)
          pending = []
          groups = []
          body_lines = lines[1...-1]
          entry_nodes = Array(rhs_node.arguments&.arguments)

          body_lines.each_with_index do |line, body_index|
            current_entry = entry_nodes.first

            if current_entry && literal_collection_entry_line_index(field_node, current_entry) == body_index + 1
              next unless literal_collection_entry_node?(current_entry)

              groups << {
                key: current_entry.slice,
                lines: pending + [line],
              }
              pending = []
              entry_nodes.shift
              next
            end

            if line.strip.empty? || line.lstrip.start_with?("#")
              pending << line
              next
            end

            next
          end

          return if entry_nodes.any?

          groups
        end

        def literal_dir_assignment_rhs_node(field_node)
          field_node.arguments&.arguments&.first
        end

        def literal_dir_call_node?(node)
          node.is_a?(Prism::CallNode) &&
            node.name == :[] &&
            node.block.nil? &&
            Kettle::Jem::PrismUtils.extract_const_name(node.receiver) == "Dir"
        end

        def literal_collection_entry_node?(node)
          node.is_a?(Prism::StringNode) && node.location.start_line == node.location.end_line
        end

        def literal_collection_entry_line_index(field_node, entry_node)
          entry_node.location.start_line - field_node.location.start_line
        end

        def exact_field_assignment_source(field_node, content)
          Kettle::Jem::PrismUtils.node_slice_with_trailing_comment(field_node, content)
        end

        def full_field_assignment_source(field_node, content)
          content.lines[(field_node.location.start_line - 1)...field_node.location.end_line].join
        end

        def field_source_with_attached_comments(field_node, content)
          lines = content.lines
          start_index = field_node.location.start_line - 1

          while start_index.positive? && lines[start_index - 1].lstrip.start_with?("#")
            start_index -= 1
          end

          lines[start_index...field_node.location.end_line].join
        end

        def attached_comment_lines(field_node, content)
          lines = content.lines
          start_index = field_node.location.start_line - 1

          while start_index.positive? && lines[start_index - 1].lstrip.start_with?("#")
            start_index -= 1
          end

          lines[start_index...(field_node.location.start_line - 1)]
        end

        def field_source_start_line_with_attached_comments(field_node, content)
          lines = content.lines
          start_index = field_node.location.start_line - 1

          while start_index.positive? && lines[start_index - 1].lstrip.start_with?("#")
            start_index -= 1
          end

          start_index + 1
        end

        def generic_bundler_files_boilerplate_start_line(field_node, content, preserved_comment_lines: [])
          lines = content.lines
          current_index = field_node.location.start_line - 2
          start_index = field_node.location.start_line - 1

          Array(preserved_comment_lines).reverse_each do |line|
            next unless current_index >= 0 && lines[current_index] == line

            current_index -= 1
          end

          if current_index >= 0 && generic_bundler_files_gemspec_assignment_line?(lines[current_index])
            start_index = current_index
            current_index -= 1
          end

          [
            "# The `git ls-files -z` loads the files in the RubyGem that have been added into git.",
            "# Specify which files should be added to the gem when it is released.",
          ].each do |expected_line|
            next unless current_index >= 0 && lines[current_index].strip == expected_line

            start_index = current_index
            current_index -= 1
          end

          return if start_index == field_node.location.start_line - 1

          start_index + 1
        end

        def generic_bundler_files_gemspec_assignment_line?(line)
          line.to_s.match?(/^\s*gemspec\s*=\s*File\.basename\(__FILE__\)\s*$/)
        end

        def generic_bundler_files_assignment?(field_node, content)
          source = full_field_assignment_source(field_node, content)
          source.include?("IO.popen(%w[git ls-files -z]") || source.include?("IO.popen(%w[git ls-files")
        end

        def replace_destination_nonliteral_assignment_source(
          merged_node:,
          merged_content:,
          template_node:,
          template_content:,
          destination_node:,
          destination_content:
        )
          return if literal_dir_assignment_parts(destination_node, content: destination_content)
          return unless literal_dir_assignment_parts(template_node, content: template_content)

          unless generic_bundler_files_assignment?(destination_node, destination_content)
            replacement = field_source_with_attached_comments(destination_node, destination_content)
            cleanup_start_line = field_source_start_line_with_attached_comments(destination_node, destination_content)
            return if cleanup_start_line.nil? && field_source_with_attached_comments(merged_node, merged_content) == replacement

            return {
              replacement: replacement,
              start_line: cleanup_start_line || merged_node.location.start_line,
              end_line: merged_node.location.end_line,
            }
          end

          replacement = field_source_with_attached_comments(template_node, template_content)
          cleanup_start_line = generic_bundler_files_boilerplate_start_line(
            merged_node,
            merged_content,
            preserved_comment_lines: attached_comment_lines(template_node, template_content),
          )
          return if cleanup_start_line.nil? && field_source_with_attached_comments(merged_node, merged_content) == replacement

          {
            replacement: replacement,
            start_line: cleanup_start_line || merged_node.location.start_line,
            end_line: merged_node.location.end_line,
          }
        end
      end
    end
  end
end
