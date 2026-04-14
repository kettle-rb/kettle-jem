# frozen_string_literal: true

lambda do |content:, context:, **|
  min_ruby = context[:min_ruby]
  pruned_content, removed = Kettle::Jem::PrismAppraisals.prune_ruby_appraisals(content, min_ruby: min_ruby)
  {
    content: pruned_content,
    changed: pruned_content != content,
    stats: {removed_appraisals: removed},
  }
end
