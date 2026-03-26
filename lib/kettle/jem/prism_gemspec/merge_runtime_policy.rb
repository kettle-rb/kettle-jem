# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      # Runtime contract for gemspec recipe execution and runtime-context wiring.
      module MergeRuntimePolicy
        # Emit a debug warning for rescued errors when debugging is enabled.
        # @param error [Exception]
        # @param context [String, Symbol, nil] optional label, often __method__
        # @return [void]
        def debug_error(error, context = nil)
          Kettle::Dev.debug_error(error, context)
        end

        # Merge template and destination gemspec content through the shared recipe
        # runner so smart-merge orchestration and post-merge harmonization live in
        # the recipe surface instead of SourceMerger hooks.
        def merge(template_content, dest_content, preset: nil, min_ruby: nil, entrypoint_require: nil, namespace: nil, **options)
          template_content ||= ""
          dest_content ||= ""

          return dest_content if template_content.strip.empty?

          runtime_context = build_runtime_context(
            options.delete(:context),
            min_ruby: min_ruby,
            entrypoint_require: entrypoint_require,
            namespace: namespace,
          )
          return template_content if dest_content.strip.empty? && runtime_context.empty?

          recipe = preset || Kettle::Jem.recipe(:gemspec)
          run_options = {
            template_content: template_content,
            destination_content: dest_content,
            relative_path: "project.gemspec",
          }
          run_options[:context] = runtime_context unless runtime_context.empty?

          merged_content = Ast::Merge::Recipe::Runner.new(recipe, **options).run_content(**run_options).content
          validate_merged_gemspec_content!(merged_content)
        rescue Kettle::Jem::Error
          raise
        rescue StandardError => e
          Kernel.warn("[#{__method__}] Gemspec recipe merge failed: #{e.message}")
          template_content
        end

        def validate_merged_gemspec_content!(content)
          return content if content.to_s.strip.empty? || gemspec_context(content)

          raise Kettle::Jem::Error, "Malformed merged gemspec content after recipe execution."
        end

        def build_runtime_context(context, min_ruby:, entrypoint_require:, namespace:)
          RecipeRuntimeContext.build(
            context,
            min_ruby: min_ruby,
            entrypoint_require: entrypoint_require,
            namespace: namespace,
          )
        end
      end
    end
  end
end
