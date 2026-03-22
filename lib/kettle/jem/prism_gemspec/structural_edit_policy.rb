# frozen_string_literal: true


module Kettle
  module Jem
    module PrismGemspec
      module StructuralEditPolicy
        def remove_line_ranges_with_plans(content:, lines:, ranges:, metadata: {})
          normalized_ranges = Array(ranges).compact
          return Array(lines).dup if normalized_ranges.empty?

          plans = normalized_ranges.sort_by(&:begin).map do |range|
            Ast::Merge::StructuralEdit::RemovePlan.new(
              source: content,
              remove_start_line: range.begin + 1,
              remove_end_line: range.end + 1,
              preserve_removed_trailing_blank_lines: false,
              metadata: metadata.merge(line_range: range),
            )
          end

          merged_content_from_plans(
            content: content,
            plans: plans,
            metadata: metadata,
          ).lines
        end

        def plan_overlapping_line(plans, line_number)
          Array(plans).find { |plan| plan.line_range.include?(line_number) }
        end

        def add_anchor_splice_plan(plans:, content:, lines:, anchor_line:, insertion_text:, metadata:, position: :before, &overlap_metadata_builder)
          overlap_plan = plan_overlapping_line(plans, anchor_line)
          return merge_anchor_splice_plan(
            plans: plans,
            content: content,
            overlap_plan: overlap_plan,
            insertion_text: insertion_text,
            position: position,
            metadata: overlap_metadata_builder ? overlap_metadata_builder.call(overlap_plan) : overlap_plan.metadata.merge(metadata),
          ) if overlap_plan

          plans + [
            build_anchor_splice_plan(
              content: content,
              lines: lines,
              anchor_line: anchor_line,
              insertion_text: insertion_text,
              position: position,
              metadata: metadata,
            ),
          ]
        end

        def merge_anchor_splice_plan(plans:, content:, overlap_plan:, insertion_text:, position:, metadata:)
          Array(plans).map do |plan|
            next plan unless plan.equal?(overlap_plan)

            build_splice_plan(
              content: content,
              replacement: anchor_splice_replacement(plan.replacement, insertion_text, position: position),
              start_line: plan.replace_start_line,
              end_line: plan.replace_end_line,
              metadata: metadata,
            )
          end
        end

        def build_anchor_splice_plan(content:, lines:, anchor_line:, insertion_text:, position:, metadata:)
          original_line = lines[anchor_line - 1].to_s
          build_splice_plan(
            content: content,
            replacement: anchor_splice_replacement(original_line, insertion_text, position: position),
            start_line: anchor_line,
            end_line: anchor_line,
            metadata: metadata,
          )
        end

        def build_splice_plan(content:, replacement:, start_line:, end_line:, metadata:)
          Ast::Merge::StructuralEdit::SplicePlan.new(
            source: content,
            replacement: replacement,
            replace_start_line: start_line,
            replace_end_line: end_line,
            metadata: metadata,
          )
        end

        def merged_content_from_plans(content:, plans:, metadata:)

          Ast::Merge::StructuralEdit::PlanSet.new(
            source: content,
            plans: plans,
            metadata: metadata,
          ).merged_content
        end

        def anchor_splice_replacement(anchor_text, insertion_text, position:)
          if position == :after
            anchor_text + insertion_text
          else
            insertion_text + anchor_text
          end
        end
      end
    end
  end
end
