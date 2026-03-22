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

          normalize_dependency_sections(
            updated,
            template_content: template_content,
            destination_content: destination_content,
            prefer_template: false,
          )
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
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end
      end
    end
  end
end
