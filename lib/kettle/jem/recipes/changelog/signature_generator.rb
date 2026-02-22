# frozen_string_literal: true

# Signature generator for CHANGELOG merging.
#
# Matches:
# - H1 headings by normalized text (e.g., "Changelog")
# - H2 headings by version label or "[Unreleased]"
# - H3 headings by text (Added, Changed, Deprecated, Removed, Fixed, Security)
# - List items by their text content
#
# @param node [Object] A Markly AST node
# @return [Array, Object] Signature array for matching, or node for default behavior

lambda do |node|
  return node unless defined?(Markly) && node.respond_to?(:type)

  case node.type
  when :header, :heading
    level = node.respond_to?(:header_level) ? node.header_level : nil
    text = if node.respond_to?(:to_plaintext)
      node.to_plaintext.to_s.strip
    elsif node.respond_to?(:string_content)
      node.string_content.to_s.strip
    else
      ""
    end
    normalized = text.downcase.gsub(/[^a-z0-9\s\[\]]/, "").strip
    [:header, level, normalized]

  when :list
    # Lists match by position within their parent section
    node

  when :link_definition
    if node.respond_to?(:to_commonmark)
      cm = node.to_commonmark.to_s.strip
      if cm =~ /^\[([^\]]+)\]:/
        return [:link_definition, $1]
      end
    end
    node

  else
    node
  end
end
