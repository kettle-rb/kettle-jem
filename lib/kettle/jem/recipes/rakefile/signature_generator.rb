# frozen_string_literal: true

# Signature generator for Rakefile merging.
#
# Handles:
# - `task()` definitions: Match by task name
# - `namespace()` blocks: Match by namespace name
# - `desc()` calls: Match as part of task context
# - `require` statements: Match by required file
#
# @param node [Prism::Node] A Prism AST node
# @return [Array, Object] Signature array for matching, or node for default behavior

lambda do |node|
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

  when :require, :require_relative
    first_arg = node.arguments&.arguments&.first
    if first_arg.is_a?(Prism::StringNode)
      [node.name, first_arg.unescaped]
    else
      node
    end

  when :load
    first_arg = node.arguments&.arguments&.first
    if first_arg.is_a?(Prism::StringNode)
      [:load, first_arg.unescaped]
    else
      node
    end

  when :import
    # Rake import statement
    first_arg = node.arguments&.arguments&.first
    if first_arg.is_a?(Prism::StringNode)
      [:import, first_arg.unescaped]
    else
      node
    end

  else
    node
  end
end
