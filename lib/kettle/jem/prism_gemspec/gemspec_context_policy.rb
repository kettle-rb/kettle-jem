# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      module GemspecContextPolicy
        def safe_gemspec_context(content)
          gemspec_context(content)
        rescue StandardError, LoadError => e
          debug_error(e, __method__)
          nil
        end

        def gemspec_context(content)
          result = PrismUtils.parse_with_comments(content)
          return unless result.success?

          statements = PrismUtils.extract_statements(result.value.statements)
          gemspec_call = statements.find do |statement|
            statement.is_a?(Prism::CallNode) && statement.block && PrismUtils.extract_const_name(statement.receiver) == "Gem::Specification" && statement.name == :new
          end
          return unless gemspec_call

          {
            gemspec_call: gemspec_call,
            blk_param: extract_block_param(gemspec_call) || "spec",
            stmt_nodes: PrismUtils.extract_statements(gemspec_call.block&.body),
          }
        end

        def dependency_node_records(stmt_nodes, blk_param)
          Array(stmt_nodes).filter_map do |node|
            next unless gemspec_dependency_call?(node, blk_param)

            first_arg = node.arguments&.arguments&.first
            gem_name = PrismUtils.extract_literal_value(first_arg)
            next if gem_name.to_s.empty?

            {
              node: node,
              method: node.name.to_s,
              gem: gem_name.to_s,
              start_line: node.location.start_line,
              end_line: node.location.end_line,
            }
          end
        end

        def dependency_indent(node)
          node.slice.lines.first[/^(\s*)/, 1] || ""
        end

        def dependency_signature(node)
          arguments = node.arguments&.arguments || []
          arguments.map { |argument| PrismUtils.normalize_argument(argument) }.join(", ")
        end

        def extract_block_param(gemspec_call)
          return unless gemspec_call.block&.parameters

          params_node = gemspec_call.block.parameters
          return unless params_node.respond_to?(:parameters) && params_node.parameters

          inner_params = params_node.parameters
          return unless inner_params.respond_to?(:requireds) && inner_params.requireds&.any?

          first_param = inner_params.requireds.first
          return unless first_param.respond_to?(:name)

          param_name = first_param.name
          param_name.to_s if param_name && !param_name.to_s.empty?
        end

        def find_field_node(stmt_nodes, blk_param, field)
          stmt_nodes.find do |node|
            next false unless node.is_a?(Prism::CallNode)

            receiver_name = node.receiver&.slice&.strip
            receiver_name&.end_with?(blk_param) && node.name.to_s.start_with?(field)
          end
        end

        def self_dependency_nodes(stmt_nodes, blk_param, gem_name)
          stmt_nodes.select do |node|
            next false unless gemspec_dependency_call?(node, blk_param)

            first_arg = node.arguments&.arguments&.first
            PrismUtils.extract_literal_value(first_arg).to_s == gem_name.to_s
          end
        end

        def gemspec_dependency_call?(node, blk_param)
          return false unless node.is_a?(Prism::CallNode)

          receiver = node.receiver
          return false unless receiver && receiver.slice.strip.end_with?(blk_param)

          %i[add_dependency add_development_dependency add_runtime_dependency].include?(node.name)
        end
      end
    end
  end
end
