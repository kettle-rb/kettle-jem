# frozen_string_literal: true

lambda do |template_content:, destination_content:, context: nil, **|
  preserve_config = context.is_a?(Hash) ? context[:preserve_config] : nil
  Kettle::Jem::MarkdownMerger.preserve_sections(template_content, destination_content, preserve_config: preserve_config)
end
