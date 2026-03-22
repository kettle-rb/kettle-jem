# frozen_string_literal: true


module Kettle
  module Jem
    module PrismGemfile
      # Named contract for materializing Gemfile structural removals via ast-merge.
      module RemovalEditPolicy
        module_function

        def remove_github_git_source(content)
          result = PrismUtils.parse_with_comments(content)
          return content unless result.success?

          stmts = PrismUtils.extract_statements(result.value.statements)

          declarations = stmts.filter_map do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :git_source

            first_arg = node.arguments&.arguments&.first
            next unless first_arg.is_a?(Prism::SymbolNode) && first_arg.unescaped == "github"

            {
              name: :github,
              line: node.location.start_line,
              end_line: node.location.end_line,
              context: :remove_github_git_source,
            }
          end

          remove_declarations(content, declarations)
        end

        def remove_declarations(content, declarations)
          return content if declarations.empty?


          plans = declarations.map do |declaration|
            Ast::Merge::StructuralEdit::RemovePlan.new(
              source: content,
              remove_start_line: declaration[:line],
              remove_end_line: declaration[:end_line] || declaration[:line],
              metadata: {
                source: :kettle_jem_prism_gemfile,
                declaration_name: declaration[:name],
                declaration_context: declaration[:context],
              },
            )
          end

          Ast::Merge::StructuralEdit::PlanSet.new(
            source: content,
            plans: plans,
            metadata: {source: :kettle_jem_prism_gemfile},
          ).merged_content
        end
      end
    end
  end
end
