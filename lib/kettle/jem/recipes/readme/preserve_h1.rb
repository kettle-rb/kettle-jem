# frozen_string_literal: true

lambda do |content:, destination_content:, **|
  Kettle::Jem::MarkdownMerger.preserve_h1(content, destination_content)
end
