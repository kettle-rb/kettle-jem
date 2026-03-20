# frozen_string_literal: true

lambda do |template_content:, destination_content:, **|
  Kettle::Jem::ChangelogMerger.merge_unreleased_content(template_content, destination_content)
end
