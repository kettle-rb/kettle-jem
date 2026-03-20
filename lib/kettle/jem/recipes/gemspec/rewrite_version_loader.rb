# frozen_string_literal: true

lambda do |content:, context:, **|
  min_ruby = context[:min_ruby]
  entrypoint_require = context[:entrypoint_require]
  namespace = context[:namespace]

  next content if min_ruby.nil?
  next content if entrypoint_require.to_s.strip.empty?
  next content if namespace.to_s.strip.empty?

  Kettle::Jem::PrismGemspec.rewrite_version_loader(
    content,
    min_ruby: min_ruby,
    entrypoint_require: entrypoint_require,
    namespace: namespace,
  )
end
