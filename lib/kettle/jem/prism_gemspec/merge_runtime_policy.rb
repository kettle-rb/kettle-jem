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
        def merge(template_content, dest_content, preset: nil, min_ruby: nil, entrypoint_require: nil, namespace: nil, resolver: nil, **options)
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
          if preserve_destination_nonliteral_files_assignment?(dest_content)
            preserved_content = merge_preserving_destination_structure(
              template_content: template_content,
              destination_content: dest_content,
              runtime_context: runtime_context,
              resolver: resolver,
            )
            return preserved_content if preserved_content
          end

          recipe = preset || Kettle::Jem.recipe(:gemspec)
          run_options = {
            template_content: template_content,
            destination_content: dest_content,
            relative_path: "project.gemspec",
          }
          run_options[:context] = runtime_context unless runtime_context.empty?

          merged_content = Ast::Merge::Recipe::Runner.new(recipe, **options).run_content(**run_options).content

          harmonized_content = harmonize_merged_content(
            merged_content,
            template_content: template_content,
            destination_content: dest_content,
          )
          # The raw recipe output can be temporarily malformed for gemspec-specific
          # constructs that harmonization repairs (for example, restoring helper
          # statements that a preserved assignment depends on). Validate only after
          # those repair passes have run.
          #
          # Post-merge harmonization (DependencySectionPolicy) manipulates lines
          # and can re-introduce consecutive blank lines. Normalize as a final pass.
          harmonized_content = normalize_consecutive_blank_lines(harmonized_content)
          # Optionally align # ruby >= N.N trailing comments on all dep lines.
          harmonized_content = align_dependency_ruby_comments(harmonized_content, resolver: resolver)
          validate_merged_gemspec_content!(harmonized_content)
        rescue Kettle::Jem::Error
          raise
        rescue StandardError => e
          Kernel.warn("[#{__method__}] Gemspec recipe merge failed: #{e.message}")
          template_content
        end

        def preserve_destination_nonliteral_files_assignment?(content)
          context = safe_gemspec_context(content)
          return false unless context

          field_node = find_field_node(context[:stmt_nodes], context[:blk_param], "files")
          return false unless field_node

          literal_dir_assignment_parts(field_node, content: content).nil?
        rescue StandardError => e
          debug_error(e, __method__)
          false
        end

        def merge_preserving_destination_structure(template_content:, destination_content:, runtime_context:, resolver:)
          content = destination_content

          if runtime_context[:min_ruby] && runtime_context[:entrypoint_require].to_s.strip != "" && runtime_context[:namespace].to_s.strip != ""
            content = rewrite_version_loader(
              content,
              min_ruby: runtime_context[:min_ruby],
              entrypoint_require: runtime_context[:entrypoint_require],
              namespace: runtime_context[:namespace],
            )
          end

          harmonized_content = harmonize_merged_content(
            content,
            template_content: template_content,
            destination_content: destination_content,
          )
          harmonized_content = normalize_consecutive_blank_lines(harmonized_content)
          harmonized_content = align_dependency_ruby_comments(harmonized_content, resolver: resolver)
          validate_merged_gemspec_content!(harmonized_content)
        rescue Kettle::Jem::Error
          raise
        rescue StandardError => e
          debug_error(e, __method__)
          nil
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

        private

        # Collapse runs of consecutive blank lines down to at most one.
        # Mirrors Ast::Merge::Recipe::Runner#normalize_consecutive_blank_lines_in_string
        # but lives here so post-harmonization output is always clean.
        def normalize_consecutive_blank_lines(content, max_consecutive: 1)
          return content if content.nil? || content.empty?

          lines = content.split("\n", -1)
          consecutive = 0
          result = lines.each_with_object([]) do |line, acc|
            if line.strip.empty?
              consecutive += 1
              acc << line if consecutive <= max_consecutive
            else
              consecutive = 0
              acc << line
            end
          end
          result.join("\n")
        end

        # Apply DependencyCommentAligner when a resolver is available.
        # Silently skips if resolver is nil or if the aligner fails.
        def align_dependency_ruby_comments(content, resolver:)
          return content unless resolver

          Kettle::Jem::GemRubyFloor::DependencyCommentAligner.align(
            gemspec_content: content,
            resolver: resolver,
          )
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end
      end
    end
  end
end
