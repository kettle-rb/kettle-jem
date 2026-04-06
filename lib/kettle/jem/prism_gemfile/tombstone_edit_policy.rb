# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    module PrismGemfile
      # Named contract for removing active declarations that have been tombstoned
      # and restoring the explanatory comment blocks back into merged Gemfiles.
      module TombstoneEditPolicy
        module_function

        def suppress_commented_gem_declarations(content, collect_commented_gem_tombstones:, collect_gem_declarations:, remove_declarations:)
          tombstones = collect_commented_gem_tombstones.call(content)
          prune_declarations_for_tombstones(
            content,
            tombstones,
            collect_gem_declarations: collect_gem_declarations,
            remove_declarations: remove_declarations,
          )
        end

        def remove_tombstoned_gem_declarations(destination_content, template_content, collect_commented_gem_tombstones:, collect_gem_declarations:, remove_declarations:)
          tombstones = collect_commented_gem_tombstones.call(template_content)
          prune_declarations_for_tombstones(
            destination_content,
            tombstones,
            collect_gem_declarations: collect_gem_declarations,
            remove_declarations: remove_declarations,
          )
        end

        def restore_tombstone_comment_blocks(content, template_content, collect_commented_gem_tombstones:)
          tombstones = collect_commented_gem_tombstones.call(template_content)
          return content if tombstones.empty?

          tombstones.reduce(content) do |updated, tombstone|
            ensure_tombstone_comment_block(updated, tombstone)
          end
        end

        def prune_declarations_for_tombstones(content, tombstones, collect_gem_declarations:, remove_declarations:)
          return content if tombstones.empty?

          tombstone_contexts = tombstones.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |tombstone, contexts|
            contexts[tombstone[:name]] << tombstone[:context]
          end

          declarations = collect_gem_declarations.call(content)
          removals = declarations.select do |declaration|
            tombstone_contexts[declaration[:name]].include?(declaration[:context])
          end
          return content if removals.empty?

          remove_declarations.call(content, removals)
        end

        def ensure_tombstone_comment_block(content, tombstone)
          block_text = tombstone[:block_text].to_s
          return content if block_text.empty? || content.include?(block_text)

          lines = content.lines
          ranges = context_ranges_for_content(content)
          marker_line = block_text.lines.first.to_s.rstrip
          start_index = comment_block_index_for_marker(lines, marker_line, tombstone[:context], ranges)
          start_index ||= comment_block_index_for_marker(lines, tombstone[:slice].to_s, tombstone[:context], ranges)
          start_index = comment_block_start_index(lines, start_index) if start_index

          plan = if start_index
            end_index = comment_block_end_index(lines, start_index, include_trailing_blank_lines: true)
            Ast::Merge::StructuralEdit::SplicePlan.new(
              source: content,
              replacement: block_text,
              replace_start_line: start_index + 1,
              replace_end_line: end_index + 1,
              metadata: {
                source: :kettle_jem_prism_gemfile,
                edit: :ensure_tombstone_comment_block,
                tombstone_name: tombstone[:name],
                tombstone_context: tombstone[:context],
              },
            )
          else
            insertion_index = insertion_index_for_tombstone(lines, tombstone, ranges)
            return block_text if lines.empty?

            anchor_line, replacement = if insertion_index >= lines.length
              [lines.length, lines.fetch(lines.length - 1, "") + block_text]
            else
              [insertion_index + 1, block_text + lines[insertion_index].to_s]
            end

            Ast::Merge::StructuralEdit::SplicePlan.new(
              source: content,
              replacement: replacement,
              replace_start_line: anchor_line,
              replace_end_line: anchor_line,
              metadata: {
                source: :kettle_jem_prism_gemfile,
                edit: :ensure_tombstone_comment_block,
                tombstone_name: tombstone[:name],
                tombstone_context: tombstone[:context],
              },
            )
          end

          Ast::Merge::StructuralEdit::PlanSet.new(
            source: content,
            plans: [plan],
            metadata: {source: :kettle_jem_prism_gemfile, edit: :ensure_tombstone_comment_block},
          ).merged_content
        end

        def context_ranges_for_content(content)
          result = PrismUtils.parse_with_comments(content)
          return [] unless result.success?

          DeclarationContextPolicy.collect_context_ranges(result.value.statements)
        end

        def comment_block_index_for_marker(lines, marker_line, context, ranges)
          lines.each_index.find do |index|
            next false unless lines[index].rstrip == marker_line

            DeclarationContextPolicy.context_for_line(index + 1, ranges) == context
          end
        end

        def comment_block_end_index(lines, start_index, include_trailing_blank_lines: false)
          finish = start_index

          while finish + 1 < lines.length && lines[finish + 1].match?(/^\s*#/)
            finish += 1
          end

          if include_trailing_blank_lines
            while finish + 1 < lines.length && lines[finish + 1].strip.empty?
              finish += 1
            end
          end

          finish
        end

        def comment_block_start_index(lines, start_index)
          cursor = start_index

          while cursor.positive? && lines[cursor - 1].match?(/^\s*#/) && !lines[cursor - 1].strip.empty?
            cursor -= 1
          end

          cursor
        end

        def insertion_index_for_tombstone(lines, tombstone, ranges)
          line_number = if tombstone[:context] == "top-level"
            top_level_tombstone_anchor_index(lines)&.+(1)
          else
            declaration_line_for_context(lines.join, tombstone[:context]) || block_body_start_line_for_context(ranges, tombstone[:context])
          end

          line_number ? line_number - 1 : lines.length
        end

        def top_level_tombstone_anchor_index(lines)
          lines.find_index { |line| line.match?(/\S/) }
        end

        def declaration_line_for_context(content, context)
          DeclarationContextPolicy.collect_gem_declarations(content)
            .select { |declaration| declaration[:context] == context }
            .map { |declaration| declaration[:line] }
            .min
        end

        def block_body_start_line_for_context(ranges, context)
          range = ranges.find { |candidate| candidate[:context] == context }
          range ? range[:start_line] + 1 : nil
        end
      end
    end
  end
end
