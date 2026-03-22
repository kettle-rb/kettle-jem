# frozen_string_literal: true


module Kettle
  module Jem
    module PrismGemfile
      # Named contract for removing self-referential gem dependencies from
      # Gemfile-like content across nested block/conditional structures.
      module DependencyRemovalPolicy
        module_function

        def remove_gem_dependency(content, gem_name)
          return content if gem_name.to_s.strip.empty?

          result = PrismUtils.parse_with_comments(content)
          return content unless result.success?

          gem_nodes = find_gem_nodes_recursive(result.value.statements, gem_name)

          declarations = gem_nodes.map do |node|
            {
              name: gem_name.to_s,
              line: node.location.start_line,
              end_line: node.location.end_line,
              context: :remove_gem_dependency,
            }
          end

          RemovalEditPolicy.remove_declarations(content, declarations)
        end

        def find_gem_nodes_recursive(body_node, gem_name)
          found = []

          Prism::Merge::NestedStatementWalker.walk(body_node) do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :gem

            first_arg = node.arguments&.arguments&.first
            arg_val = begin
              PrismUtils.extract_literal_value(first_arg)
            rescue StandardError
              nil
            end
            found << node if arg_val && arg_val.to_s == gem_name.to_s
          end


          found
        end
      end
    end
  end
end
