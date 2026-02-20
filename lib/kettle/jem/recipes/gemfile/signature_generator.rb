# frozen_string_literal: true

# Signature generator for Gemfile merging.
#
# Handles:
# - `source()` calls: Match by method name only (singleton)
# - `gem()` calls: Match by gem name (first argument)
# - `ruby()` version specifier: Singleton
# - `git_source()` calls: Match by source name
# - `eval_gemfile()` calls: Match by file path argument
# - Assignment methods (`spec.foo =`): Match by receiver and method name
#
# @param node [Prism::Node] A Prism AST node
# @return [Array, Object] Signature array for matching, or node for default behavior

# Helper to extract receiver name from a call node
def extract_receiver_name(node)
  receiver = node.receiver
  case receiver
  when Prism::CallNode
    receiver.name.to_s
  when Prism::LocalVariableReadNode
    receiver.name.to_s
  when Prism::ConstantReadNode
    receiver.name.to_s
  when Prism::ConstantPathNode
    extract_constant_path(receiver)
  end
end

# Helper to extract constant path (e.g., "Gem::Specification")
def extract_constant_path(node)
  parts = []
  current = node
  while current
    case current
    when Prism::ConstantPathNode
      parts.unshift(current.name.to_s) if current.respond_to?(:name)
      current = current.parent
    when Prism::ConstantReadNode
      parts.unshift(current.name.to_s)
      break
    else
      break
    end
  end
  parts.join("::")
end

# Helper to extract first argument value
def extract_first_arg_value(node)
  first_arg = node.arguments&.arguments&.first
  case first_arg
  when Prism::StringNode
    first_arg.unescaped
  when Prism::SymbolNode
    first_arg.unescaped
  end
end

# The lambda must be the last expression so it's returned
lambda do |node|
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

  when :group
    # group() matches by group names
    args = node.arguments&.arguments || []
    group_names = args.take_while { |a| a.is_a?(Prism::SymbolNode) }.map(&:unescaped)
    group_names.any? ? [:group, *group_names] : node

  else
    # Handle assignment methods and other calls
    method_name = node.name.to_s

    if method_name.end_with?("=")
      # Assignment methods match by receiver and method
      receiver_name = extract_receiver_name(node)
      [:call, node.name, receiver_name]
    else
      # Other methods with arguments match by first arg
      first_arg_value = extract_first_arg_value(node)
      first_arg_value ? [node.name, first_arg_value] : node
    end
  end
end
