# frozen_string_literal: true

module Kettle
  module Jem
    module Classifiers
      # Classifier for `appraise` blocks in Appraisals files.
      #
      # Identifies `appraise "name" do ... end` blocks and extracts
      # the appraisal name for section-based merging.
      #
      # @example Usage with SectionTyping
      #   classifier = AppraisalBlock.new
      #   sections = classifier.classify_all(prism_tree.statements.body)
      #
      #   sections.each do |section|
      #     puts "#{section.type}: #{section.name}" if section.type == :appraise
      #   end
      #
      # @see Ast::Merge::SectionTyping::Classifier
      class AppraisalBlock < Ast::Merge::SectionTyping::Classifier
        # Classify a node as an appraise block.
        #
        # @param node [Object] A Prism AST node
        # @return [Ast::Merge::SectionTyping::TypedSection, nil]
        def classify(node)
          return nil unless defined?(Prism) && node.is_a?(Prism::CallNode)
          return nil unless node.name == :appraise
          return nil unless node.block # Must have a block

          first_arg = node.arguments&.arguments&.first
          return nil unless first_arg.respond_to?(:unescaped)

          Ast::Merge::SectionTyping::TypedSection.new(
            type: :appraise,
            name: first_arg.unescaped,
            node: node,
            metadata: extract_metadata(node)
          )
        end

        private

        # Extract metadata from an appraise block.
        #
        # @param node [Prism::CallNode] The appraise call node
        # @return [Hash] Metadata about the appraisal
        def extract_metadata(node)
          metadata = {}

          # Extract gem calls within the block
          if node.block.respond_to?(:body) && node.block.body
            gems = []
            eval_gemfiles = []

            traverse_body(node.block.body) do |child|
              if child.is_a?(Prism::CallNode)
                case child.name
                when :gem
                  gem_name = child.arguments&.arguments&.first
                  gems << gem_name.unescaped if gem_name.respond_to?(:unescaped)
                when :eval_gemfile
                  path = child.arguments&.arguments&.first
                  eval_gemfiles << path.unescaped if path.respond_to?(:unescaped)
                end
              end
            end

            metadata[:gems] = gems if gems.any?
            metadata[:eval_gemfiles] = eval_gemfiles if eval_gemfiles.any?
          end

          metadata
        end

        # Traverse a node body recursively.
        #
        # @param body [Object] The body node
        # @yield [node] Each child node
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
