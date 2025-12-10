# frozen_string_literal: true

module Kettle
  module Jem
    module Classifiers
      # Classifier for `group` blocks in Gemfiles.
      #
      # Identifies `group :name do ... end` blocks and extracts
      # the group name for section-based merging.
      #
      # @example Usage with SectionTyping
      #   classifier = GemGroup.new
      #   sections = classifier.classify_all(prism_tree.statements.body)
      #
      # @see Ast::Merge::SectionTyping::Classifier
      class GemGroup < Ast::Merge::SectionTyping::Classifier
        # Classify a node as a gem group block.
        #
        # @param node [Object] A Prism AST node
        # @return [Ast::Merge::SectionTyping::TypedSection, nil]
        def classify(node)
          return nil unless defined?(Prism) && node.is_a?(Prism::CallNode)
          return nil unless node.name == :group
          return nil unless node.block # Must have a block

          first_arg = node.arguments&.arguments&.first
          group_name = case first_arg
                       when Prism::SymbolNode
                         first_arg.unescaped.to_sym
                       when Prism::StringNode
                         first_arg.unescaped
                       else
                         return nil
                       end

          Ast::Merge::SectionTyping::TypedSection.new(
            type: :gem_group,
            name: group_name,
            node: node,
            metadata: extract_metadata(node)
          )
        end

        private

        # Extract metadata from a group block.
        #
        # @param node [Prism::CallNode] The group call node
        # @return [Hash] Metadata about the group
        def extract_metadata(node)
          metadata = {}

          # Extract all group names (group :test, :development do)
          if node.arguments&.arguments
            groups = node.arguments.arguments.filter_map do |arg|
              case arg
              when Prism::SymbolNode
                arg.unescaped.to_sym
              when Prism::StringNode
                arg.unescaped
              end
            end
            metadata[:groups] = groups if groups.length > 1
          end

          # Extract gem names within the group
          if node.block.respond_to?(:body) && node.block.body
            gems = []
            traverse_body(node.block.body) do |child|
              if child.is_a?(Prism::CallNode) && child.name == :gem
                gem_name = child.arguments&.arguments&.first
                gems << gem_name.unescaped if gem_name.respond_to?(:unescaped)
              end
            end
            metadata[:gems] = gems if gems.any?
          end

          metadata
        end

        # Traverse a node body recursively.
        def traverse_body(body, &block)
          return unless body

          children = if body.respond_to?(:body)
                       Array(body.body)
                     elsif body.respond_to?(:child_nodes)
                       body.child_nodes
                     else
                       []
                     end

          children.compact.each do |child|
            yield child
            traverse_body(child, &block)
          end
        end
      end
    end
  end
end
