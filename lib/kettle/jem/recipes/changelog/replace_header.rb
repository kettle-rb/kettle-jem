# frozen_string_literal: true

lambda do |content:, template_content:, **|
  Kettle::Jem::ChangelogMerger.replace_header_from_template(content, template_content)
end
