# frozen_string_literal: true

# Node typing for CallNode in Gemfiles.
#
# Categorizes gem() calls by the gem name to enable per-category
# merge preferences (e.g., lint gems vs test gems vs dev gems).
#
# @param node [Prism::CallNode] A Prism CallNode
# @return [Object] The node wrapped with merge type, or unchanged node

# Categorize a gem by its name.
#
# @param gem_name [String] The gem name
# @return [Symbol, nil] The category or nil for uncategorized
def categorize_gem(gem_name)
  case gem_name
  when /\Arubocop/, /\Astandard/, /\Areek/, /\Aflay/, /\Aflog/, /\Abrakeman/
    :lint_gem
  when /\Arspec/, /\Aminitest/, /\Atest-unit/, /\Acucumber/, /\Afactory/, /\Afaker/
    :test_gem
  when /\Ayard/, /\Ardoc/, /\Akramdown/, /\Amaruku/
    :doc_gem
  when /\Adebug/, /\Apry/, /\Airb/, /\Arake/, /\Abundler/
    :dev_gem
  when /\Asimplecov/, /\Acoveralls/, /\Acodecov/
    :coverage_gem
  when /\Akettle/, /\Aversion_gem/
    :kettle_gem
  end
end

# The lambda must be the last expression so it's returned
lambda do |node|
  return node unless node.name == :gem

  first_arg = node.arguments&.arguments&.first
  return node unless first_arg.respond_to?(:unescaped)

  gem_name = first_arg.unescaped.to_s
  merge_type = categorize_gem(gem_name)

  if merge_type
    Ast::Merge::NodeTyping.with_merge_type(node, merge_type)
  else
    node
  end
end
