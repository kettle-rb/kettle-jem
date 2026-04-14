# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    # AST-driven merger for Appraisals files using Prism.
    # Delegates to Prism::Merge for the heavy lifting.
    # Uses PrismUtils for shared Prism AST operations.
    module PrismAppraisals
      module_function

      # Merge template and destination Appraisals files preserving comments
      def merge(template_content, dest_content, preset: nil, min_ruby: nil, **options)
        template_content ||= ""
        dest_content ||= ""

        return template_content if dest_content.strip.empty?
        return dest_content if template_content.strip.empty?

        runtime_context = build_runtime_context(options.delete(:context), min_ruby: min_ruby)
        recipe = preset || Kettle::Jem.recipe(:appraisals)
        run_options = {
          template_content: template_content,
          destination_content: dest_content,
          relative_path: "Appraisals",
        }
        run_options[:context] = runtime_context unless runtime_context.empty?

        Ast::Merge::Recipe::Runner.new(recipe, **options).run_content(**run_options).content
      rescue StandardError => e
        Kernel.warn("[#{__method__}] Appraisals recipe merge failed: #{e.message}")
        template_content
      end

      # Remove gem calls that reference the given gem name (to prevent self-dependency).
      # @param content [String] Appraisals content
      # @param gem_name [String] the gem name to remove
      # @return [String] modified content with self-referential gem calls removed
      def remove_gem_dependency(content, gem_name)
        return content if gem_name.to_s.strip.empty?

        result = PrismUtils.parse_with_comments(content)
        root = result.value
        return content unless root&.statements&.body

        nodes_to_remove = []

        root.statements.body.each do |node|
          next unless appraise_call?(node)
          next unless node.block&.body

          body_stmts = PrismUtils.extract_statements(node.block.body)

          body_stmts.each do |stmt|
            next unless stmt.is_a?(Prism::CallNode) && stmt.name == :gem

            first_arg = stmt.arguments&.arguments&.first
            arg_val = begin
              PrismUtils.extract_literal_value(first_arg)
            rescue StandardError
              nil
            end

            nodes_to_remove << stmt if arg_val && arg_val.to_s == gem_name.to_s
          end
        end

        remove_nodes(content, nodes_to_remove, source: :kettle_jem_prism_appraisals_remove_gem_dependency) do |stmt|
          {
            declaration_name: gem_name.to_s,
            declaration_line: stmt.location.start_line,
          }
        end
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        end
        content
      end

      # Remove ruby-X-Y appraise blocks that are below the minimum Ruby version.
      # @param content [String]
      # @param min_ruby [Gem::Version, String, nil]
      # @return [Array(String, Array<String>)] pruned content and removed appraisal names
      def prune_ruby_appraisals(content, min_ruby: nil)
        return [content, []] if content.to_s.strip.empty?
        return [content, []] if min_ruby.nil? || min_ruby.to_s.strip.empty?

        min_version = Gem::Version.new(min_ruby.to_s)
        actor = Kettle::Jem::Crispr::Delete.call(
          content: content,
          target: ruby_appraisal_prune_selector(min_version),
          source_label: "Appraisals",
        )
        removed = actor.matches.filter_map { |match| match.metadata[:appraisal_name] }
        pruned = actor.updated_content

        # Collapse runs of 3+ consecutive newlines down to 2 (one blank line)
        pruned.gsub!(/\n{3,}/, "\n\n")

        [pruned, removed]
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        end
        [content, []]
      end

      # Helper: Check if node is an appraise block call
      def appraise_call?(node)
        PrismUtils.block_call_to?(node, :appraise)
      end

      def ruby_appraisal_prune_selector(min_version)
        Kettle::Jem::Crispr::Selectors.owner_filter(
          id: "appraisals_ruby_min_prune",
          limit: {at_least: 0},
        ) do |_context, owner|
          next unless appraise_call?(owner)
          next unless owner.arguments&.arguments&.first

          name = PrismUtils.extract_literal_value(owner.arguments.arguments.first)
          next unless name

          match = name.to_s.match(/\Aruby-(\d+)-(\d+)\z/)
          next unless match

          version = Gem::Version.new("#{match[1]}.#{match[2]}")
          next unless version < min_version

          {
            appraisal_name: name.to_s,
            appraisal_line: owner.location.start_line,
          }
        end
      end

      def build_runtime_context(context, min_ruby:)
        RecipeRuntimeContext.build(context, min_ruby: min_ruby)
      end

      def remove_nodes(content, nodes, source:, &metadata_block)
        return content if nodes.empty?

        plans = nodes.filter_map do |node|
          next unless node.respond_to?(:location) && node.location

          Ast::Merge::StructuralEdit::RemovePlan.new(
            source: content,
            remove_start_line: node.location.start_line,
            remove_end_line: node.location.end_line,
            metadata: {source: source}.merge(metadata_block ? metadata_block.call(node) : {}),
          )
        end

        return content if plans.empty?

        Ast::Merge::StructuralEdit::PlanSet.new(
          source: content,
          plans: plans,
          metadata: {source: source},
        ).merged_content
      end
    end
  end
end
