# frozen_string_literal: true

# Signature generator for gemspec file merging.
#
# Handles:
# - `spec.foo =` assignments: Match by method name
# - `spec.add_dependency()`: Match by gem name
# - `spec.add_development_dependency()`: Match by gem name
# - `spec.add_runtime_dependency()`: Match by gem name
# - `Gem::Specification.new`: Match as singleton
#
# @param node [Prism::Node] A Prism AST node
# @return [Array, Object] Signature array for matching, or node for default behavior

# Helper to extract receiver name from a call node
def extract_receiver_name(node)
  receiver = node.receiver
  case receiver
  when Prism::CallNode
    # For chained calls like spec.metadata["key"]
    inner_name = receiver.name.to_s
    if inner_name == "metadata"
      inner_receiver = extract_receiver_name(receiver)
      inner_receiver ? "#{inner_receiver}.metadata" : "metadata"
    else
      inner_name
    end
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

# The lambda must be the last expression so it's returned
lambda do |node|
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

  # spec.files = ... or spec.test_files = ... etc (common array assignments)
  if receiver_name == "spec" && %i[files test_files require_paths executables extensions extra_rdoc_files].include?(node.name)
    return [:spec_files, node.name]
  end

  # spec.metadata["key"] = value
  if node.name == :[]= && receiver_name&.include?("metadata")
    first_arg = node.arguments&.arguments&.first
    if first_arg.is_a?(Prism::StringNode)
      return [:spec_metadata, first_arg.unescaped]
    end
  end

  node
end
