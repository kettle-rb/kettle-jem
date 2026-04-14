# frozen_string_literal: true

lambda do |content:, **|
  {
    content: Kettle::Jem::RakefileScaffoldSelectors.remove(
      content,
      Prism::Merge::ScaffoldChunkRemover::RUBOCOP_SPEC,
    ),
  }
end
