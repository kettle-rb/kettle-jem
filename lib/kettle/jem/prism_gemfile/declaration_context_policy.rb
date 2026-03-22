# frozen_string_literal: true


module Kettle
  module Jem
    module PrismGemfile
      # Named contract for Gemfile declaration traversal, nesting-context labels,
      # and cross-nesting duplicate validation.
      module DeclarationContextPolicy
        module_function

        def validate_no_cross_nesting_duplicates(merged_content, template_content, path: "Gemfile")
          merged_decls = collect_gem_declarations(merged_content)
          return if merged_decls.empty?

          by_name = merged_decls.group_by { |d| d[:name] }

          conflicts = {}
          by_name.each do |name, decls|
            contexts = decls.map { |d| d[:context] }.uniq
            conflicts[name] = decls if contexts.size > 1
          end

          return if conflicts.empty?

          template_decls = collect_gem_declarations(template_content)
          template_by_name = template_decls.group_by { |d| d[:name] }

          lines = ["Gemfile merge produced duplicate gem declarations in blocks with different signatures in #{path}:"]
          conflicts.each do |name, decls|
            lines << ""
            lines << "  gem #{name.inspect} appears in #{decls.map { |d| d[:context] }.uniq.size} different block contexts:"
            decls.each_with_index do |d, i|
              lines << "    #{i + 1}. #{d[:slice]}"
              lines << "       Block signature: #{d[:context]} (line #{d[:line]})"
            end

            next unless template_by_name[name]

            lines << ""
            lines << "  Template version (use as guide to resolve):"
            template_by_name[name].each do |td|
              lines << "    #{td[:slice]}"
              lines << "       Block signature: #{td[:context]} (line #{td[:line]})"
            end
          end

          lines << ""
          lines << "  Resolution: reconcile the gem declarations in the destination file"
          lines << "  so each gem appears in only one block context, then re-run."

          raise Kettle::Jem::Error, lines.join("\n")
        end

        def collect_gem_declarations(content)
          result = PrismUtils.parse_with_comments(content)
          return [] unless result.success?

          declarations = []
          walk_for_declarations(result.value.statements, [], declarations)
          declarations
        end

        def walk_for_declarations(body_node, context_stack, declarations)
          Prism::Merge::NestedStatementWalker.walk_with_context(
            body_node,
            context_stack: context_stack,
            next_context: method(:next_context_stack_for_child),
          ) do |node, current_context|
            next unless node.is_a?(Prism::CallNode) && node.name == :gem

            first_arg = node.arguments&.arguments&.first
            gem_name = begin
              PrismUtils.extract_literal_value(first_arg)
            rescue StandardError
              nil
            end
            next unless gem_name

            declarations << {
              name: gem_name.to_s,
              context: current_context.empty? ? "top-level" : current_context.join(" > "),
              slice: node.slice.strip,
              line: node.location.start_line,
              start_offset: node.location.start_offset,
              end_offset: node.location.end_offset,
              end_line: node.location.end_line,
            }
          end

          declarations
        end

        def describe_call_context(node)
          args = node.arguments&.arguments
          if args && args.any?
            first = args.first
            arg_str = case first
            when Prism::SymbolNode then ":#{first.unescaped}"
            when Prism::StringNode then first.unescaped.inspect
            else first.slice
            end
            "#{node.name}(#{arg_str})"
          else
            node.name.to_s
          end
        rescue StandardError
          node.name.to_s
        end

        def describe_condition(node)
          pred = node.predicate
          text = pred.slice.to_s.strip
          (text.length > 40) ? text[0..37] + "..." : text
        rescue StandardError
          "..."
        end

        def collect_context_ranges(body_node, context_stack = [], ranges = [])
          walker = Prism::Merge::NestedStatementWalker

          walker.walk_with_context(
            body_node,
            context_stack: context_stack,
            next_context: method(:next_context_stack_for_child),
          ) do |node, current_context|
            child_contexts = walker
              .nested_statement_children(node)
              .map { |child| next_context_stack_for_child(node: node, child_kind: child[:kind], current_context: current_context) }
              .uniq
              .reject { |child_context| child_context == current_context }

            child_contexts.each do |child_context|
              ranges << build_context_range(node, child_context)
            end
          end

          ranges
        end

        def next_context_stack_for_child(node:, child_kind:, current_context:)
          case node
          when Prism::CallNode
            child_kind == :call_block ? current_context + [describe_call_context(node)] : current_context
          when Prism::IfNode
            current_context + ["if #{describe_condition(node)}"]
          when Prism::UnlessNode
            current_context + ["unless #{describe_condition(node)}"]
          else
            current_context
          end
        end

        def build_context_range(node, context_stack)
          {
            context: context_stack.join(" > "),
            start_line: node.location.start_line,
            end_line: node.location.end_line,
            depth: context_stack.length,
          }
        end

        def context_for_line(line_number, ranges)
          range = ranges
            .select { |candidate| line_number.between?(candidate[:start_line], candidate[:end_line]) }
            .max_by { |candidate| [candidate[:depth], -(candidate[:end_line] - candidate[:start_line])] }

          range ? range[:context] : "top-level"
        end
      end
    end
  end
end
