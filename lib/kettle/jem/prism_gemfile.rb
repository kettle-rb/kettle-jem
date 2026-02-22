# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    # Prism helpers for Gemfile-like merging.
    module PrismGemfile
      module_function

      # Merge gem calls from src_content into dest_content.
      # - Replaces dest `source` call with src's if present.
      # - Replaces or inserts non-comment `git_source` definitions.
      # - Appends missing `gem` calls (by name) from src to dest preserving dest content and newlines.
      # Uses Prism::Merge with pre-filtering to only merge top-level statements.
      def merge_gem_calls(src_content, dest_content)
        require "prism/merge" unless defined?(Prism::Merge)

        # Pre-filter: Extract only top-level gem-related calls from src
        src_filtered = filter_to_top_level_gems(src_content)

        # Always remove :github git_source from dest as it's built-in to Bundler
        dest_processed = remove_github_git_source(dest_content)

        # Custom signature generator that normalizes string quotes
        signature_generator = ->(node) do
          return unless node.is_a?(Prism::CallNode)
          return unless [:gem, :source, :git_source].include?(node.name)

          return [:source] if node.name == :source

          first_arg = node.arguments&.arguments&.first

          arg_value = case first_arg
          when Prism::StringNode
            first_arg.unescaped.to_s
          when Prism::SymbolNode
            first_arg.unescaped.to_sym
          end

          arg_value ? [node.name, arg_value] : nil
        end

        merger = Prism::Merge::SmartMerger.new(
          src_filtered,
          dest_processed,
          preference: :template,
          add_template_only_nodes: true,
          signature_generator: signature_generator,
        )
        merger.merge
      rescue Prism::Merge::Error => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        else
          Kernel.warn("[#{__method__}] Prism::Merge failed: #{e.class}: #{e.message}")
        end
        dest_content
      end

      # Filter source content to only include top-level gem-related calls.
      #
      # Magic comments (frozen_string_literal, encoding, etc.) are NOT preserved
      # in the filtered output — SmartMerger handles them by always preserving
      # destination magic comments regardless of preference.
      def filter_to_top_level_gems(content)
        parse_result = PrismUtils.parse_with_comments(content)
        return content unless parse_result.success?

        top_level_stmts = PrismUtils.extract_statements(parse_result.value.statements)

        filtered_stmts = top_level_stmts.select do |stmt|
          next false if stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode)
          next false unless stmt.is_a?(Prism::CallNode)
          next false if stmt.block && stmt.name != :git_source

          [:gem, :source, :git_source, :eval_gemfile].include?(stmt.name)
        end

        return "" if filtered_stmts.empty?

        # Join statements with single newline. The trailing blank line ensures
        # SmartMerger's trailing blank detection emits a gap after the last
        # filtered statement, preserving separation from dest-only nodes.
        filtered_stmts.map do |stmt|
          src = stmt.slice.rstrip
          inline = begin
            PrismUtils.inline_comments_for_node(parse_result, stmt)
          rescue
            []
          end
          if inline && inline.any?
            src + " " + inline.map(&:slice).map(&:strip).join(" ")
          else
            src
          end
        end.join("\n") + "\n"
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        end
        content
      end

      # Remove git_source(:github) from content
      # @param content [String] Gemfile-like content
      # @return [String] content with git_source(:github) removed
      def remove_github_git_source(content)
        result = PrismUtils.parse_with_comments(content)
        return content unless result.success?

        stmts = PrismUtils.extract_statements(result.value.statements)

        github_node = stmts.find do |n|
          next false unless n.is_a?(Prism::CallNode) && n.name == :git_source

          first_arg = n.arguments&.arguments&.first
          first_arg.is_a?(Prism::SymbolNode) && first_arg.unescaped == "github"
        end

        return content unless github_node

        content.sub(github_node.slice, "")
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        end
        content
      end

      # Remove gem calls that reference the given gem name (to prevent self-dependency).
      # @param content [String] Gemfile-like content
      # @param gem_name [String] the gem name to remove
      # @return [String] modified content with self-referential gem calls removed
      def remove_gem_dependency(content, gem_name)
        return content if gem_name.to_s.strip.empty?

        result = PrismUtils.parse_with_comments(content)
        stmts = PrismUtils.extract_statements(result.value.statements)

        gem_nodes = stmts.select do |n|
          next false unless n.is_a?(Prism::CallNode) && n.name == :gem

          first_arg = n.arguments&.arguments&.first
          arg_val = begin
            PrismUtils.extract_literal_value(first_arg)
          rescue StandardError
            nil
          end
          arg_val && arg_val.to_s == gem_name.to_s
        end

        out = content.dup
        gem_nodes.each do |gn|
          out = out.sub(gn.slice, "")
        end

        out
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        else
          Kernel.warn("[#{__method__}] #{e.class}: #{e.message}")
        end
        content
      end
    end
  end
end
