# frozen_string_literal: true

module Kettle
  module Jem
    # Signature generator factories for various file types.
    #
    # Signature generators determine how nodes are matched during merging.
    # Each generator returns a lambda suitable for use with SmartMerger's
    # `signature_generator:` option.
    #
    # @example Creating a Gemfile signature generator
    #   generator = Signatures.gemfile
    #   merger = Prism::Merge::SmartMerger.new(
    #     template, dest,
    #     signature_generator: generator
    #   )
    #
    # @see Ast::Merge::MergerConfig
    module Signatures
      class << self
        # Create a signature generator for Gemfile/Appraisals merging.
        #
        # Handles:
        # - `source()` calls: Match by method name only (singleton)
        # - `gem()` calls: Match by gem name (first argument)
        # - Assignment methods (`spec.foo =`): Match by receiver and method name
        # - `eval_gemfile()` calls: Match by file path argument
        # - Other calls with arguments: Match by method name and first argument
        #
        # @return [Proc] Signature generator lambda
        def gemfile
          ->(node) do
            return node unless defined?(Prism) && node.is_a?(Prism::CallNode)

            case node.name
            when :source
              # source() should be singleton
              [:source]
            when :gem
              # gem() matches by gem name
              first_arg = node.arguments&.arguments&.first
              if first_arg.is_a?(Prism::StringNode)
                [:gem, first_arg.unescaped]
              else
                node
              end
            when :eval_gemfile
              # eval_gemfile() matches by path
              first_arg = node.arguments&.arguments&.first
              if first_arg.is_a?(Prism::StringNode)
                [:eval_gemfile, first_arg.unescaped]
              else
                node
              end
            when :ruby
              # ruby() version specifier is singleton
              [:ruby]
            when :git_source
              # git_source() matches by source name
              first_arg = node.arguments&.arguments&.first
              if first_arg.is_a?(Prism::SymbolNode)
                [:git_source, first_arg.unescaped]
              else
                node
              end
            else
              # Handle assignment methods and other calls
              method_name = node.name.to_s
              receiver_name = extract_receiver_name(node)

              if method_name.end_with?("=")
                # Assignment methods match by receiver and method
                [:call, node.name, receiver_name]
              else
                # Other methods with arguments match by first arg
                first_arg_value = extract_first_arg_value(node)
                first_arg_value ? [node.name, first_arg_value] : node
              end
            end
          end
        end

        # Create a signature generator for Appraisals file merging.
        #
        # Extends Gemfile signatures with:
        # - `appraise()` calls: Match by appraisal name
        #
        # @return [Proc] Signature generator lambda
        def appraisals
          gemfile_gen = gemfile

          ->(node) do
            return node unless defined?(Prism) && node.is_a?(Prism::CallNode)

            if node.name == :appraise
              first_arg = node.arguments&.arguments&.first
              if first_arg.is_a?(Prism::StringNode)
                return [:appraise, first_arg.unescaped]
              end
            end

            # Fall back to gemfile signature generator
            gemfile_gen.call(node)
          end
        end

        # Create a signature generator for gemspec file merging.
        #
        # Handles:
        # - `spec.foo =` assignments: Match by method name
        # - `spec.add_dependency()`: Match by gem name
        # - `spec.add_development_dependency()`: Match by gem name
        # - `Gem::Specification.new`: Match as singleton
        #
        # @return [Proc] Signature generator lambda
        def gemspec
          ->(node) do
            return node unless defined?(Prism) && node.is_a?(Prism::CallNode)

            method_name = node.name.to_s
            receiver_name = extract_receiver_name(node)

            # spec.foo = "value" assignments
            if method_name.end_with?("=") && receiver_name == "spec"
              return [:spec_attr, node.name]
            end

            # spec.add_dependency and spec.add_development_dependency
            if %i[add_dependency add_development_dependency add_runtime_dependency].include?(node.name)
              first_arg = node.arguments&.arguments&.first
              if first_arg.is_a?(Prism::StringNode)
                return [node.name, first_arg.unescaped]
              end
            end

            # Gem::Specification.new block
            if receiver_name&.include?("Gem::Specification") && node.name == :new
              return [:gem_specification_new]
            end

            node
          end
        end

        # Create a signature generator for Rakefile merging.
        #
        # Handles:
        # - `task()` definitions: Match by task name
        # - `namespace()` blocks: Match by namespace name
        # - `desc()` calls: Match as part of task context
        #
        # @return [Proc] Signature generator lambda
        def rakefile
          ->(node) do
            return node unless defined?(Prism) && node.is_a?(Prism::CallNode)

            case node.name
            when :task
              first_arg = node.arguments&.arguments&.first
              case first_arg
              when Prism::SymbolNode
                [:task, first_arg.unescaped]
              when Prism::HashNode, Prism::KeywordHashNode
                # Handle task :name => [:deps]
                if first_arg.respond_to?(:elements)
                  first_elem = first_arg.elements.first
                  if first_elem.respond_to?(:key) && first_elem.key.is_a?(Prism::SymbolNode)
                    return [:task, first_elem.key.unescaped]
                  end
                end
                node
              else
                node
              end
            when :namespace
              first_arg = node.arguments&.arguments&.first
              if first_arg.is_a?(Prism::SymbolNode)
                [:namespace, first_arg.unescaped]
              else
                node
              end
            when :desc
              # desc calls typically paired with task, treat as context
              [:desc]
            else
              node
            end
          end
        end

        private

        # Extract receiver name from a call node.
        #
        # @param node [Prism::CallNode] The call node
        # @return [String, nil] The receiver name or nil
        def extract_receiver_name(node)
          receiver = node.receiver
          case receiver
          when Prism::CallNode
            receiver.name.to_s
          when Prism::ConstantReadNode
            receiver.name.to_s
          when Prism::ConstantPathNode
            receiver.slice
          else
            receiver&.slice
          end
        end

        # Extract the value of the first argument from a call node.
        #
        # @param node [Prism::CallNode] The call node
        # @return [String, Symbol, nil] The argument value or nil
        def extract_first_arg_value(node)
          first_arg = node.arguments&.arguments&.first
          case first_arg
          when Prism::StringNode
            first_arg.unescaped.to_s
          when Prism::SymbolNode
            first_arg.unescaped.to_sym
          end
        end
      end
    end
  end
end
