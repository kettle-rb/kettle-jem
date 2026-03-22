# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemfile
      # Shared Gemfile merge pipeline for pre/post processing around Prism merge
      # execution. This centralizes Gemfile-local tombstone and git_source
      # handling so callers do not re-encode the same sequencing.
      module MergePipelinePolicy
        module_function

        def merge(src_content, dest_content, runtime:, filter_template: true,
                  signature_for:, merge_body: nil)

          template_content = filter_template ? runtime.filter_to_top_level_gems(src_content) : src_content
          destination_content = prepare_destination(dest_content, template_content: src_content, runtime: runtime)

          merged = if merge_body
            merge_body.call(template_content, destination_content)
          else
            default_merge(template_content, destination_content, signature_for: signature_for)
          end

          finalize_merged_content(merged, template_content: src_content, runtime: runtime)
        rescue Prism::Merge::Error => e
          if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
            Kettle::Dev.debug_error(e, __method__)
          else
            Kernel.warn("[#{__method__}] Prism::Merge failed: #{e.class}: #{e.message}")
          end
          dest_content
        end

        def prepare_destination(content, template_content:, runtime:)
          runtime.prepare_destination(content, template_content)
        end

        def finalize_merged_content(content, template_content:, runtime:)
          runtime.finalize_merged_content(content, template_content)
        end

        def default_merge(src_content, dest_content, signature_for:)
          Prism::Merge::SmartMerger.new(
            src_content,
            dest_content,
            preference: :template,
            add_template_only_nodes: true,
            signature_generator: ->(node) { signature_for.call(node) },
          ).merge
        end
      end
    end
  end
end
