# frozen_string_literal: true

module Kettle
  module Jem
    module Classifiers
      # Classifier for method definitions in Ruby files.
      #
      # Identifies `def method_name` and `def self.method_name` definitions
      # for section-based merging.
      #
      # @example Usage with SectionTyping
      #   classifier = MethodDef.new
      #   sections = classifier.classify_all(prism_tree.statements.body)
      #
      # @see Ast::Merge::SectionTyping::Classifier
      class MethodDef < Ast::Merge::SectionTyping::Classifier
        # Classify a node as a method definition.
        #
        # @param node [Object] A Prism AST node
        # @return [Ast::Merge::SectionTyping::TypedSection, nil]
        def classify(node)
          return unless defined?(Prism)

          case node
          when Prism::DefNode
            classify_def_node(node)
          when Prism::SingletonMethodNode
            classify_singleton_method(node)
          end
        end

        private

        # Classify a regular def node.
        #
        # @param node [Prism::DefNode] The def node
        # @return [Ast::Merge::SectionTyping::TypedSection]
        def classify_def_node(node)
          Ast::Merge::SectionTyping::TypedSection.new(
            type: :method_def,
            name: node.name.to_sym,
            node: node,
            metadata: {
              visibility: infer_visibility(node),
              has_params: node.parameters ? true : false,
              param_count: count_parameters(node.parameters),
            },
          )
        end

        # Classify a singleton method definition (def self.foo).
        #
        # @param node [Prism::SingletonMethodNode] The singleton method node
        # @return [Ast::Merge::SectionTyping::TypedSection]
        def classify_singleton_method(node)
          Ast::Merge::SectionTyping::TypedSection.new(
            type: :singleton_method_def,
            name: node.name.to_sym,
            node: node,
            metadata: {
              has_params: node.parameters ? true : false,
              param_count: count_parameters(node.parameters),
            },
          )
        end

        # Infer visibility from surrounding context.
        # Note: This is a simplified heuristic.
        #
        # @param node [Prism::DefNode] The def node
        # @return [Symbol] :public, :private, :protected, or :unknown
        def infer_visibility(node)
          # In a real implementation, this would check for preceding
          # private/protected/public calls or use location context
          :unknown
        end

        # Count the number of parameters.
        #
        # @param params [Object, nil] The parameters node
        # @return [Integer] Parameter count
        def count_parameters(params)
          return 0 unless params

          count = 0
          count += params.requireds.length if params.respond_to?(:requireds)
          count += params.optionals.length if params.respond_to?(:optionals)
          count += 1 if params.respond_to?(:rest) && params.rest
          count += params.keywords.length if params.respond_to?(:keywords)
          count += 1 if params.respond_to?(:keyword_rest) && params.keyword_rest
          count += 1 if params.respond_to?(:block) && params.block
          count
        end
      end
    end
  end
end
