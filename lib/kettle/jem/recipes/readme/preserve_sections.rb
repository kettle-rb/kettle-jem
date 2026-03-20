# frozen_string_literal: true

lambda do |template_content:, destination_content:, **|
  Kettle::Jem::MarkdownMerger.preserve_sections(template_content, destination_content)
end
