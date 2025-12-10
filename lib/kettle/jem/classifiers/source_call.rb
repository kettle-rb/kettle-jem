# frozen_string_literal: true

module Kettle
  module Jem
    module Classifiers
      # Classifier for `source` calls in Gemfiles.
      #
      # Identifies `source "url"` calls. There should typically be
      # only one source, so this is treated as a singleton section.
      #
      # @example Usage with SectionTyping
      #   classifier = SourceCall.new
      #   sections = classifier.classify_all(prism_tree.statements.body)
      #
      # @see Ast::Merge::SectionTyping::Classifier
      class SourceCall < Ast::Merge::SectionTyping::Classifier
        # Classify a node as a source call.
        #
        # @param node [Object] A Prism AST node
        # @return [Ast::Merge::SectionTyping::TypedSection, nil]
        def classify(node)
          return nil unless defined?(Prism) && node.is_a?(Prism::CallNode)
          return nil unless node.name == :source

          first_arg = node.arguments&.arguments&.first
          return nil unless first_arg.respond_to?(:unescaped)

          source_url = first_arg.unescaped

          Ast::Merge::SectionTyping::TypedSection.new(
            type: :source,
            name: :source, # Singleton - always matches
            node: node,
            metadata: { url: source_url }
          )
        end
      end
    end
  end
end
