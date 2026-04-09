# frozen_string_literal: true

lambda do |content:, **|
  {content: Prism::Merge::ScaffoldChunkRemover.remove(content, [Prism::Merge::ScaffoldChunkRemover::DEFAULT_TASK_SPEC])}
end
