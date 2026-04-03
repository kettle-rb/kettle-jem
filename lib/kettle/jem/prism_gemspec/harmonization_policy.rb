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
