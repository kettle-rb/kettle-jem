# frozen_string_literal: true


module Kettle
  module Jem
    module PrismGemfile
      # Runtime contract for Gemfile-specific merge preparation/finalization.
      # Owns pre-filtering, tombstone collection, destination pruning, and
      # post-merge tombstone restoration/suppression with Gemfile-local rescue
      # behavior.
      module MergeRuntimePolicy
        module_function

        def filter_to_top_level_gems(content)
          MergeEntryPolicy.filter_content(
            content,
            tombstone_line_ranges: TombstonePolicy.method(:commented_gem_tombstone_line_ranges),
          )
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        def collect_commented_gem_tombstones(content)
          TombstonePolicy.collect_commented_gem_tombstones(
            content,
            collect_context_ranges: DeclarationContextPolicy.method(:collect_context_ranges),
            context_for_line: DeclarationContextPolicy.method(:context_for_line),
          )
        rescue StandardError => e
          debug_error(e, __method__)
          []
        end

        def remove_tombstoned_gem_declarations(destination_content, template_content)
          TombstoneEditPolicy.remove_tombstoned_gem_declarations(
            destination_content,
            template_content,
            collect_commented_gem_tombstones: method(:collect_commented_gem_tombstones),
            collect_gem_declarations: DeclarationContextPolicy.method(:collect_gem_declarations),
            remove_declarations: RemovalEditPolicy.method(:remove_declarations),
          )
        rescue StandardError => e
          debug_error(e, __method__)
          destination_content
        end

        def restore_tombstone_comment_blocks(content, template_content)
          TombstoneEditPolicy.restore_tombstone_comment_blocks(
            content,
            template_content,
            collect_commented_gem_tombstones: method(:collect_commented_gem_tombstones),
          )
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        def suppress_commented_gem_declarations(content)
          TombstoneEditPolicy.suppress_commented_gem_declarations(
            content,
            collect_commented_gem_tombstones: method(:collect_commented_gem_tombstones),
            collect_gem_declarations: DeclarationContextPolicy.method(:collect_gem_declarations),
            remove_declarations: RemovalEditPolicy.method(:remove_declarations),
          )
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        def prepare_destination(content, template_content)
          out = remove_tombstoned_gem_declarations(content, template_content)
          RemovalEditPolicy.remove_github_git_source(out)
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        def finalize_merged_content(content, template_content)
          out = restore_tombstone_comment_blocks(content, template_content)
          suppress_commented_gem_declarations(out)
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        def debug_error(error, context)
          return unless defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)

          Kettle::Dev.debug_error(error, context)
        end
      end
    end
  end
end
