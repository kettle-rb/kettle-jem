# frozen_string_literal: true

lambda do |content:, **|
  {
    content: Kettle::Jem::RakefileScaffoldSelectors.remove(
      content,
      Prism::Merge::ScaffoldChunkRemover::RSPEC_SPEC,
    ),
  }
end
