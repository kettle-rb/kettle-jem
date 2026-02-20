# frozen_string_literal: true

# Signature generator for Appraisals file merging.
#
# Extends Gemfile signatures with:
# - `appraise()` calls: Match by appraisal name
#
# Inherits all Gemfile behaviors:
# - `source()`, `gem()`, `ruby()`, `git_source()`, `eval_gemfile()`, `group()`
#
# @param node [Prism::Node] A Prism AST node
# @return [Array, Object] Signature array for matching, or node for default behavior

lambda do |node|
  return node unless defined?(Prism) && node.is_a?(Prism::CallNode)

  # Handle appraise() calls specifically
  if node.name == :appraise
    first_arg = node.arguments&.arguments&.first
    if first_arg.is_a?(Prism::StringNode)
      return [:appraise, first_arg.unescaped]
    end
  end

  # Fall back to Gemfile-style matching for other calls
  case node.name
  when :source
    [:source]

  when :gem
    first_arg = node.arguments&.arguments&.first
    if first_arg.is_a?(Prism::StringNode)
      [:gem, first_arg.unescaped]
    else
      node
    end

  when :eval_gemfile
    first_arg = node.arguments&.arguments&.first
    if first_arg.is_a?(Prism::StringNode)
      [:eval_gemfile, first_arg.unescaped]
    else
      node
    end

  when :ruby
    [:ruby]

  when :git_source
    first_arg = node.arguments&.arguments&.first
    if first_arg.is_a?(Prism::SymbolNode)
      [:git_source, first_arg.unescaped]
    else
      node
    end

  when :group
    args = node.arguments&.arguments || []
    group_names = args.take_while { |a| a.is_a?(Prism::SymbolNode) }.map(&:unescaped)
    group_names.any? ? [:group, *group_names] : node

  else
    node
  end
end
