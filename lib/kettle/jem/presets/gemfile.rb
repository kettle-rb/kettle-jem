# frozen_string_literal: true

module Kettle
  module Jem
    module Presets
      # MergerConfig preset for Gemfile merging.
      #
      # Provides intelligent signature matching for Gemfile constructs:
      # - `source()` calls are singleton
      # - `gem()` calls match by gem name
      # - `eval_gemfile()` calls match by file path
      # - `git_source()` calls match by source name
      # - `ruby()` version specifier is singleton
      #
      # @example Basic usage
      #   config = Gemfile.destination_wins
      #   merger = Prism::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @example With custom freeze token
      #   config = Gemfile.template_wins(freeze_token: "my-project")
      #   merger = Prism::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @see Kettle::Jem::Signatures.gemfile
      class Gemfile < Base
        class << self
          # Returns the signature generator for Gemfile merging.
          #
          # @return [Proc] Lambda that generates signatures for Gemfile nodes
          def signature_generator
            Signatures.gemfile
          end

          # Returns node typing for categorizing different types of gems.
          #
          # Categorizes gems into:
          # - `:lint_gem`: RuboCop and related linting gems
          # - `:test_gem`: RSpec, Minitest, and related testing gems
          # - `:doc_gem`: YARD, RDoc, and documentation gems
          # - `:dev_gem`: Development-only gems
          #
          # @return [Hash] Node typing configuration
          def default_node_typing
            {
              CallNode: ->(node) {
                return node unless node.name == :gem

                first_arg = node.arguments&.arguments&.first
                return node unless first_arg.respond_to?(:unescaped)

                gem_name = first_arg.unescaped.to_s
                merge_type = categorize_gem(gem_name)

                merge_type ? Ast::Merge::NodeTyping.with_merge_type(node, merge_type) : node
              }
            }
          end

          private

          # Categorize a gem by its name.
          #
          # @param gem_name [String] The gem name
          # @return [Symbol, nil] The category or nil for uncategorized
          def categorize_gem(gem_name)
            case gem_name
            when /\Arubocop/, /\Astandard/, /\Areek/, /\Aflay/, /\Aflog/, /\Abrakeman/
              :lint_gem
            when /\Arspec/, /\Aminitest/, /\Atest-unit/, /\Acucumber/, /\Afactory/, /\Afaker/
              :test_gem
            when /\Ayard/, /\Ardoc/, /\Akramdown/, /\Amaruku/
              :doc_gem
            when /\Adebug/, /\Apry/, /\Airb/, /\Arake/, /\Abundler/
              :dev_gem
            end
          end
        end
      end
    end
  end
end
