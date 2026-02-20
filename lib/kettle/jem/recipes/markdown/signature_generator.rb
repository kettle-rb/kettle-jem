# frozen_string_literal: true

# Signature generator for Markdown merging.
#
# Generates signatures based on:
# - Headings: Match by level and normalized text
# - Tables: Match by structure and first row content
# - Code blocks: Match by language and info string
# - Links: Match by URL
# - Images: Match by URL
# - HTML blocks: Match by content prefix or freeze markers
#
# @param node [Object] A Markly AST node
# @return [Array, Object] Signature array for matching, or node for default behavior

# Extract text from a heading node.
#
# @param node [Object] Markly heading node
# @return [String] Heading text content
def extract_heading_text(node)
  if node.respond_to?(:to_plaintext)
    node.to_plaintext.to_s.strip
  elsif node.respond_to?(:string_content)
    node.string_content.to_s.strip
  else
    ""
  end
end

# Normalize heading text for matching.
#
# @param text [String] Heading text
# @return [String] Normalized text (lowercase, trimmed)
def normalize_heading(text)
  text.to_s.downcase.gsub(/[^a-z0-9\s]/, "").strip
end

# Extract a signature from a table's header row.
#
# @param node [Object] Markly table node
# @return [String, nil] Header signature or nil
def extract_table_header_signature(node)
  return unless node.respond_to?(:each)

  # Find first row (header)
  node.each do |child|
    if child.respond_to?(:type) && child.type == :table_row
      cells = []
      child.each do |cell|
        if cell.respond_to?(:to_plaintext)
          cells << cell.to_plaintext.to_s.strip
        end
      end
      return cells.join("|") if cells.any?
    end
  end

  nil
end

# The lambda must be the last expression so it's returned
lambda do |node|
  # Only handle Markly nodes
  return node unless defined?(Markly) && node.respond_to?(:type)

  case node.type
  when :header, :heading
    level = node.respond_to?(:header_level) ? node.header_level : nil
    text = extract_heading_text(node)
    [:header, level, normalize_heading(text)]

  when :table
    # Match tables by first row content (header row)
    first_row_sig = extract_table_header_signature(node)
    [:table, first_row_sig]

  when :code_block
    # Match code blocks by language and position context
    lang = node.respond_to?(:fence_info) ? node.fence_info.to_s.strip : ""
    [:code_block, lang]

  when :html_block
    # HTML blocks may be comments (freeze markers) or content
    content = node.respond_to?(:string_content) ? node.string_content.to_s.strip : ""
    if content.include?("freeze") || content.include?("unfreeze")
      [:html_comment, :freeze_marker]
    else
      [:html_block, content[0, 50]] # First 50 chars as signature
    end

  when :link
    # Links match by URL
    url = node.respond_to?(:url) ? node.url.to_s : ""
    [:link, url]

  when :image
    # Images match by URL/path
    url = node.respond_to?(:url) ? node.url.to_s : ""
    [:image, url]

  when :link_definition
    # Link definitions match by label
    if node.respond_to?(:to_commonmark)
      text = node.to_commonmark.to_s.strip
      if text =~ /^\[([^\]]+)\]:/
        return [:link_definition, $1]
      end
    end
    node

  else
    # Fall through to default
    node
  end
end
