# frozen_string_literal: true

lambda do |content:, **|
  Kettle::Jem::ChangelogMerger.finalize_content(content)
end
