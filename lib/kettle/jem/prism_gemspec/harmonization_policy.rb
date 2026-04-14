# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      # Runtime contract for post-merge gemspec harmonization.
      module HarmonizationPolicy
        def harmonize_merged_content(content, template_content:, destination_content:)
          return content if content.to_s.empty?

          updated = union_literal_dir_assignment(
            content,
            field: "files",
            template_content: template_content,
            destination_content: destination_content,
          )
          updated = cleanup_destination_nonliteral_dir_assignment(
            updated,
            field: "files",
            template_content: template_content,
            destination_content: destination_content,
          )
          updated = preserve_files_assignment_helpers(
            updated,
            field: "files",
            destination_content: destination_content,
          )
          updated = collapse_duplicate_field_assignments(updated, field: "files")

          updated = normalize_dependency_sections(
            updated,
            template_content: template_content,
            destination_content: destination_content,
            prefer_template: false,
          )

          remove_singular_license_if_plural_present(updated)
        rescue Kettle::Jem::Error
          raise
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        private

        def normalize_dependency_sections(content, template_content:, destination_content:, prefer_template: false)
          DependencySectionPolicy.normalize(
            content: content,
            template_content: template_content,
            destination_content: destination_content,
            prefer_template: prefer_template,
          )
        rescue Kettle::Jem::Error
          raise
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        def collapse_duplicate_field_assignments(content, field:)
          context = safe_gemspec_context(content)
          return content unless context

          field_nodes = context[:stmt_nodes].select do |node|
            node.is_a?(Prism::CallNode) &&
              node.receiver&.slice&.strip&.end_with?(context[:blk_param]) &&
              node.name.to_s.start_with?(field)
          end
          return content if field_nodes.length < 2

          kept_node = field_nodes.find do |node|
            !literal_dir_assignment_parts(node, content: content) && !generic_bundler_files_assignment?(node, content)
          end || field_nodes.last

          removal_plans = field_nodes.reject { |node| node.equal?(kept_node) }.map do |node|
            Ast::Merge::StructuralEdit::RemovePlan.new(
              source: content,
              remove_start_line: field_source_start_line_with_attached_comments(node, content),
              remove_end_line: node.location.end_line,
              metadata: {
                source: :kettle_jem_prism_gemspec,
                edit: :remove_duplicate_field_assignment,
                field: field,
              },
            )
          end
          return content if removal_plans.empty?

          merged_content_from_plans(
            content: content,
            plans: removal_plans,
            metadata: {
              source: :kettle_jem_prism_gemspec,
              edit: :remove_duplicate_field_assignments,
              field: field,
            },
          )
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        def preserve_files_assignment_helpers(content, field:, destination_content:)
          return content unless field.to_s == "files"
          return content unless content.include?("enumerate_package_files.call(")
          return content if content.include?("enumerate_package_files = lambda do |root|")

          helper_source = destination_content[/^\s*enumerate_package_files\s*=\s*lambda do \|root\|\n(?:.*\n)*?^\s*end\n/m]
          return content unless helper_source

          context = safe_gemspec_context(content)
          return content unless context

          field_node = find_field_node(context[:stmt_nodes], context[:blk_param], field)
          return content unless field_node

          lines = content.lines
          plans = add_anchor_splice_plan(
            plans: [],
            content: content,
            lines: lines,
            anchor_line: field_node.location.start_line,
            insertion_text: "#{helper_source}\n",
            position: :before,
            metadata: {
              source: :kettle_jem_prism_gemspec,
              edit: :preserve_files_assignment_helper,
              field: field,
            },
          )

          merged_content_from_plans(
            content: content,
            plans: plans,
            metadata: {
              source: :kettle_jem_prism_gemspec,
              edit: :preserve_files_assignment_helper,
              field: field,
            },
          )
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        # Remove spec.license (singular) when spec.licenses (plural) is already present.
        # Having both is invalid: spec.license is the deprecated single-value form and
        # must be dropped whenever the canonical plural form is present.
        def remove_singular_license_if_plural_present(content)
          context = safe_gemspec_context(content)
          return content unless context

          blk_param = context[:blk_param]
          stmt_nodes = context[:stmt_nodes]

          licenses_node = stmt_nodes.find do |node|
            node.is_a?(Prism::CallNode) &&
              node.receiver&.slice&.strip&.end_with?(blk_param) &&
              node.name.to_s == "licenses="
          end
          return content unless licenses_node

          license_node = stmt_nodes.find do |node|
            node.is_a?(Prism::CallNode) &&
              node.receiver&.slice&.strip&.end_with?(blk_param) &&
              node.name.to_s == "license="
          end
          return content unless license_node

          merged_content_from_plans(
            content: content,
            plans: [
              Ast::Merge::StructuralEdit::RemovePlan.new(
                source: content,
                remove_start_line: license_node.location.start_line,
                remove_end_line: license_node.location.end_line,
                metadata: {
                  source: :kettle_jem_prism_gemspec,
                  edit: :remove_singular_license,
                  field: "license",
                },
              ),
            ],
            metadata: {source: :kettle_jem_prism_gemspec, edit: :remove_singular_license},
          )
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end
      end
    end
  end
end
