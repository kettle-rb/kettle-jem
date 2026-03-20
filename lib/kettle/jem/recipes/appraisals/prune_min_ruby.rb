# frozen_string_literal: true

lambda do |content:, context:, **|
  min_ruby = context[:min_ruby]
  Kettle::Jem::PrismAppraisals.prune_ruby_appraisals(content, min_ruby: min_ruby).first
end
