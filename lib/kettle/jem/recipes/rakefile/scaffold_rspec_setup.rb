# frozen_string_literal: true

lambda do |content:, **|
  {content: Prism::Merge::ScaffoldChunkRemover.remove(content, [Prism::Merge::ScaffoldChunkRemover::RSPEC_SPEC])}
end
