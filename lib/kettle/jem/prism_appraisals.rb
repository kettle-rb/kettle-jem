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
      def merge(template_content, dest_content)
        template_content ||= ""
        dest_content ||= ""

        return template_content if dest_content.strip.empty?
        return dest_content if template_content.strip.empty?

        require "prism/merge" unless defined?(Prism::Merge)

        merger = Prism::Merge::SmartMerger.new(
          template_content,
          dest_content,
          preference: :template,
          add_template_only_nodes: true,
        )
        merger.merge
      rescue Prism::Merge::Error => e
        Kernel.warn("[#{__method__}] Prism::Merge failed for Appraisals merge: #{e.message}")
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

        out = content.dup

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

            if arg_val && arg_val.to_s == gem_name.to_s
              out = out.sub(stmt.slice, "")
            end
          end
        end

        out
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
        result = PrismUtils.parse_with_comments(content)
        return [content, []] unless result&.success?

        stmts = PrismUtils.extract_statements(result.value.statements)
        edits = []
        removed = []

        stmts.each do |node|
          next unless appraise_call?(node)
          next unless node.arguments&.arguments&.first

          name = PrismUtils.extract_literal_value(node.arguments.arguments.first)
          next unless name

          if (m = name.to_s.match(/\Aruby-(\d+)-(\d+)\z/))
            version = Gem::Version.new("#{m[1]}.#{m[2]}")
            if version < min_version
              removed << name.to_s
              loc = node.location
              edits << [loc.start_offset, loc.end_offset - loc.start_offset] if loc
            end
          end
        end

        pruned = content.dup
        edits.sort_by { |(start, _len)| -start }.each do |start, len|
          pruned = pruned[0...start] + pruned[(start + len)..-1].to_s
        end

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
    end
  end
end
