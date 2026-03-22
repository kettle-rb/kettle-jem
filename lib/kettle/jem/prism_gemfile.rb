# frozen_string_literal: true

module Kettle
  module Jem
    # Prism helpers for Gemfile-like merging.
    module PrismGemfile
      autoload :DeclarationContextPolicy, "kettle/jem/prism_gemfile/declaration_context_policy"
      autoload :DependencyRemovalPolicy, "kettle/jem/prism_gemfile/dependency_removal_policy"
      autoload :LocalOverridePolicy, "kettle/jem/prism_gemfile/local_override_policy"
      autoload :MergeEntryPolicy, "kettle/jem/prism_gemfile/merge_entry_policy"
      autoload :MergePipelinePolicy, "kettle/jem/prism_gemfile/merge_pipeline_policy"
      autoload :MergeRuntimePolicy, "kettle/jem/prism_gemfile/merge_runtime_policy"
      autoload :RemovalEditPolicy, "kettle/jem/prism_gemfile/removal_edit_policy"
      autoload :TombstoneEditPolicy, "kettle/jem/prism_gemfile/tombstone_edit_policy"
      autoload :TombstonePolicy, "kettle/jem/prism_gemfile/tombstone_policy"

      module_function

      def merge(src_content, dest_content, merger_options: {}, filter_template: false, path: "Gemfile", force: false)
        options = merger_options.dup
        signature_for = options.delete(:signature_generator) || Kettle::Jem::Signatures.gemfile

        merged = MergePipelinePolicy.merge(
          src_content,
          dest_content,
          runtime: MergeRuntimePolicy,
          filter_template: filter_template,
          signature_for: signature_for,
          merge_body: lambda { |template_content, destination_content|
            Prism::Merge::SmartMerger.new(
              template_content,
              destination_content,
              **options,
              signature_generator: signature_for,
            ).merge
          },
        )

        validate_merged_result(merged, template_content: src_content, path: path, force: force)
      end

      # Merge top-level Gemfile declarations from src_content into dest_content.
      # - Replaces dest `source` / `gemspec` calls with src's when present.
      # - Replaces or inserts non-comment `git_source` definitions.
      # - Appends missing `gem` / `eval_gemfile` calls (by signature) from src to dest preserving dest content and newlines.
      # Uses Prism::Merge with pre-filtering to only merge top-level statements.
      def merge_gem_calls(src_content, dest_content)
        merge(
          src_content,
          dest_content,
          merger_options: {
            preference: :template,
            add_template_only_nodes: true,
            signature_generator: MergeEntryPolicy.method(:signature_for),
          },
          filter_template: true,
        )
      end

      # Remove gem calls that reference the given gem name (to prevent self-dependency).
      # Recursively walks the AST to find gem calls inside platform/group/if/else blocks.
      # @param content [String] Gemfile-like content
      # @param gem_name [String] the gem name to remove
      # @return [String] modified content with self-referential gem calls removed
      def remove_gem_dependency(content, gem_name)
        DependencyRemovalPolicy.remove_gem_dependency(content, gem_name)
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        else
          Kernel.warn("[#{__method__}] #{e.class}: #{e.message}")
        end
        content
      end


      def merge_local_gem_overrides(content, destination_content, excluded_gems: [])
        LocalOverridePolicy.merge(content, destination_content, excluded_gems: excluded_gems)
      end

      def merge_bootstrap_local_gem_overrides(source_content, destination_content, excluded_gems: [])
        LocalOverridePolicy.merge_bootstrap(source_content, destination_content, excluded_gems: excluded_gems)
      end


      # Validate that the merged content does not contain the same gem nested
      # inside block nodes with different signatures.
      #
      # When the merger encounters blocks with different signatures (e.g.,
      # `platform(:mri) do ... end` vs top-level, or `if ENV[...]` vs
      # `platform(:mri)`), it treats them as distinct nodes and keeps both.
      # If the same gem appears inside both, Bundler will reject the result:
      # "You cannot specify the same gem twice coming from different sources".
      #
      # Mutually exclusive branches (if/else of the same conditional) are NOT
      # flagged — they share the same block signature since only one executes.
      #
      # @param merged_content [String] The merged gemfile content
      # @param template_content [String] The template content (shown as reference in error)
      # @param path [String] File path (for error messages)
      # @raise [Kettle::Jem::Error] when a gem appears at different nesting levels
      # @return [void]
      def validate_no_cross_nesting_duplicates(merged_content, template_content, path: "Gemfile")
        DeclarationContextPolicy.validate_no_cross_nesting_duplicates(merged_content, template_content, path: path)
      end

      def validate_merged_result(merged_content, template_content:, path:, force: false)
        validate_no_cross_nesting_duplicates(merged_content, template_content, path: path)
        merged_content
      rescue Kettle::Jem::Error => e
        raise unless truthy_option?(force)

        $stderr.puts("[kettle-jem] WARNING: #{e.message}")
        $stderr.puts("[kettle-jem] Falling back to template content for #{path} (--force)")
        template_content.to_s
      end

      def truthy_option?(value)
        return value if value == true || value == false

        %w[1 true y yes].include?(value.to_s.strip.downcase)
      end


    end
  end
end
