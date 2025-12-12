# frozen_string_literal: true

module Kettle
  module Jem
    module Classifiers
      # Classifier for `gem` calls in Gemfiles.
      #
      # Identifies `gem "name"` calls and extracts the gem name
      # for signature-based matching.
      #
      # @example Usage with SectionTyping
      #   classifier = GemCall.new
      #   sections = classifier.classify_all(prism_tree.statements.body)
      #
      # @see Ast::Merge::SectionTyping::Classifier
      class GemCall < Ast::Merge::SectionTyping::Classifier
        # Classify a node as a gem call.
        #
        # @param node [Object] A Prism AST node
        # @return [Ast::Merge::SectionTyping::TypedSection, nil]
        def classify(node)
          return unless defined?(Prism) && node.is_a?(Prism::CallNode)
          return unless node.name == :gem

          first_arg = node.arguments&.arguments&.first
          return unless first_arg.respond_to?(:unescaped)

          gem_name = first_arg.unescaped

          Ast::Merge::SectionTyping::TypedSection.new(
            type: :gem,
            name: gem_name,
            node: node,
            metadata: extract_metadata(node, gem_name),
          )
        end

        private

        # Extract metadata from a gem call.
        #
        # @param node [Prism::CallNode] The gem call node
        # @param gem_name [String] The gem name
        # @return [Hash] Metadata about the gem
        def extract_metadata(node, gem_name)
          metadata = {category: categorize_gem(gem_name)}

          # Extract version constraint if present
          args = node.arguments&.arguments
          if args && args.length > 1
            version_arg = args[1]
            if version_arg.respond_to?(:unescaped)
              metadata[:version] = version_arg.unescaped
            end
          end

          # Check for keyword arguments (require:, git:, path:, etc.)
          if node.arguments&.arguments&.last.is_a?(Prism::KeywordHashNode)
            kw_hash = node.arguments.arguments.last
            kw_hash.elements.each do |elem|
              next unless elem.respond_to?(:key) && elem.key.respond_to?(:unescaped)

              key = elem.key.unescaped.to_sym
              value = extract_keyword_value(elem.value)
              metadata[key] = value if value
            end
          end

          metadata
        end

        # Categorize a gem by its name.
        #
        # @param gem_name [String] The gem name
        # @return [Symbol] The category
        def categorize_gem(gem_name)
          case gem_name
          when /\Arubocop/, /\Astandard/, /\Areek/, /\Aflay/, /\Aflog/
            :lint
          when /\Arspec/, /\Aminitest/, /\Atest-unit/, /\Acucumber/
            :test
          when /\Afactory/, /\Afaker/, /\Afixtures/
            :test_data
          when /\Ayard/, /\Ardoc/, /\Akramdown/
            :documentation
          when /\Adebug/, /\Apry/, /\Airb/
            :debugging
          when /\Arake/
            :build
          when /\Abundler/
            :bundler
          when /\Asimplecov/, /\Acoveralls/, /\Acodecov/
            :coverage
          else
            :runtime
          end
        end

        # Extract value from a keyword argument.
        #
        # @param value_node [Object] The value node
        # @return [String, Boolean, nil] The extracted value
        def extract_keyword_value(value_node)
          case value_node
          when Prism::StringNode
            value_node.unescaped
          when Prism::SymbolNode
            value_node.unescaped.to_sym
          when Prism::TrueNode
            true
          when Prism::FalseNode
            false
          when Prism::ArrayNode
            value_node.elements.filter_map do |elem|
              elem.unescaped if elem.respond_to?(:unescaped)
            end
          end
        end
      end
    end
  end
end
