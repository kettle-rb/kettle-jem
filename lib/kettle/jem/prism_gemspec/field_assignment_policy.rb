# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      module FieldAssignmentPolicy
        # Replace scalar or array assignments inside a Gem::Specification.new block.
        # `replacements` is a hash mapping symbol field names to string or array values.
        # Operates only inside the Gem::Specification block to avoid accidental matches.
        def replace_gemspec_fields(content, replacements = {})
          return content if replacements.nil? || replacements.empty?

          context = gemspec_context(content)
          return content unless context

          build_literal = method(:build_literal_value)
          plans = []
          insertions = []
          lines = content.lines

          replacements.each do |field_sym, value|
            next if value.nil?

            field = field_sym.to_s
            found_node = find_field_node(context[:stmt_nodes], context[:blk_param], field)

            plan = if found_node
              build_replacement_plan(content, found_node, context[:blk_param], field, field_sym, value, build_literal)
            else
              build_insertion_plan(context[:stmt_nodes], context[:gemspec_call], context[:blk_param], field, field_sym, value, build_literal)
            end

            if plan.is_a?(Hash)
              insertions << plan
            elsif plan
              plans << plan
            end
          end

          plans = add_field_insertion_plans(plans, content: content, lines: lines, insertions: insertions)

          # When spec.licenses (plural) is being set, remove any conflicting spec.license (singular)
          if replacements.key?(:licenses)
            singular_license_node = context[:stmt_nodes].find do |node|
              node.is_a?(Prism::CallNode) &&
                node.receiver&.slice&.strip&.end_with?(context[:blk_param]) &&
                node.name.to_s == "license="
            end
            if singular_license_node
              plans << Ast::Merge::StructuralEdit::RemovePlan.new(
                source: content,
                remove_start_line: singular_license_node.location.start_line,
                remove_end_line: singular_license_node.location.end_line,
                metadata: {
                  source: :kettle_jem_prism_gemspec,
                  edit: :remove_singular_license,
                  field: "license",
                },
              )
            end
          end

          return content if plans.empty?

          merged_content_from_plans(content: content, plans: plans, metadata: {source: :kettle_jem_prism_gemspec})
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        def build_replacement_plan(content, found_node, blk_param, field, field_sym, value, build_literal)
          existing_arg = found_node.arguments&.arguments&.first
          existing_literal = PrismUtils.extract_literal_value(existing_arg)

          if [:summary, :description].include?(field_sym)
            return if placeholder?(value) && existing_literal && !placeholder?(existing_literal)
          end

          if existing_literal.nil? && !value.nil?
            debug_error(StandardError.new("Skipping replacement for #{field} because existing RHS is non-literal"), __method__)
            return
          end

          loc = found_node.location
          indent = content.lines[loc.start_line - 1].to_s[/^(\s*)/, 1] || ""
          rhs = build_literal.call(value)
          replacement = "#{indent}#{blk_param}.#{field} = #{rhs}\n"

          build_splice_plan(
            content: content,
            replacement: replacement,
            start_line: loc.start_line,
            end_line: loc.end_line,
            metadata: {
              source: :kettle_jem_prism_gemspec,
              edit: :replace_gemspec_field,
              field: field,
            },
          )
        end

        def build_insertion_plan(stmt_nodes, gemspec_call, blk_param, field, field_sym, value, build_literal)
          return if [:summary, :description].include?(field_sym) && placeholder?(value)

          version_node = stmt_nodes.find do |node|
            node.is_a?(Prism::CallNode) && node.name.to_s.start_with?("version", "version=") && node.receiver && node.receiver.slice.strip.end_with?(blk_param)
          end

          {
            anchor_line: version_node ? version_node.location.end_line : gemspec_call.location.end_line,
            field: field,
            position: version_node ? :after : :before,
            text: "  #{blk_param}.#{field} = #{build_literal.call(value)}\n",
          }
        end

        def add_field_insertion_plans(plans, content:, lines:, insertions:)
          return plans if insertions.empty?

          insertions.group_by { |insertion| [insertion[:anchor_line], insertion[:position]] }.each_value do |group|
            anchor_line = group.first[:anchor_line]
            position = group.first[:position]
            insertion_text = group.map { |insertion| insertion[:text] }.join
            fields = group.map { |insertion| insertion[:field] }

            plans = add_anchor_splice_plan(
              plans: plans,
              content: content,
              lines: lines,
              anchor_line: anchor_line,
              insertion_text: insertion_text,
              position: position,
              metadata: {
                source: :kettle_jem_prism_gemspec,
                edit: :insert_gemspec_fields,
                inserted_fields: fields,
              },
            ) do |plan|
              plan.metadata.merge(inserted_fields: Array(plan.metadata[:inserted_fields]) + fields)
            end
          end

          plans
        end

        # Escape a string for safe inclusion in a Ruby double-quoted literal.
        # Backslashes are escaped first so they cannot act as escape prefixes
        # for the subsequent quote-escaping pass.
        # @param str [#to_s]
        # @return [String]
        def escape_double_quoted_string(str)
          str.to_s.gsub("\\", "\\\\").gsub('"', '\\"')
        end

        def build_literal_value(value)
          if value.is_a?(Array)
            array = value.compact.map { |entry| '"' + escape_double_quoted_string(entry) + '"' }
            "[" + array.join(", ") + "]"
          else
            '"' + escape_double_quoted_string(value) + '"'
          end
        end

        def placeholder?(value)
          return false unless value.is_a?(String)

          value.strip.match?(/\A[^\x00-\x7F]{1,4}\s*\z/)
        end
      end
    end
  end
end
