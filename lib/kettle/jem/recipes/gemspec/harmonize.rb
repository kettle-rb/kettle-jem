# frozen_string_literal: true

lambda do |content:, template_content:, destination_content:, **|
  Kettle::Jem::PrismGemspec.harmonize_merged_content(
    content,
    template_content: template_content,
    destination_content: destination_content,
  )
end
