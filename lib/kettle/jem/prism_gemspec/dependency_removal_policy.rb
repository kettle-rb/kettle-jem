# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      module DependencyRemovalPolicy
        # Remove spec.add_dependency / add_development_dependency calls that name the given gem.
        def remove_spec_dependency(content, gem_name)
          return content if gem_name.to_s.strip.empty?

          context = gemspec_context(content)
          return content unless context

          dependency_nodes = self_dependency_nodes(context[:stmt_nodes], context[:blk_param], gem_name)
          return content if dependency_nodes.empty?

          merged_content_from_plans(
            content: content,
            plans: dependency_removal_plans(content, dependency_nodes, gem_name),
            metadata: {
              source: :kettle_jem_prism_gemspec,
              gem_name: gem_name.to_s,
            },
          )
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        private

        def dependency_removal_plans(content, dependency_nodes, gem_name)
          Array(dependency_nodes).map do |node|
            dependency_removal_plan(content, node, gem_name)
          end
        end

        def dependency_removal_plan(content, node, gem_name)
          Ast::Merge::StructuralEdit::RemovePlan.new(
            source: content,
            remove_start_line: node.location.start_line,
            remove_end_line: node.location.end_line,
            metadata: {
              source: :kettle_jem_prism_gemspec,
              gem_name: gem_name.to_s,
              dependency_method: node.name,
            },
          )
        end
      end
    end
  end
end
