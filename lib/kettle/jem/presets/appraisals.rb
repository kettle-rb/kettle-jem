# frozen_string_literal: true

module Kettle
  module Jem
    module Presets
      # MergerConfig preset for Appraisals file merging.
      #
      # Extends Gemfile handling with support for `appraise` blocks.
      # Each appraisal block is matched by its name (the first argument).
      #
      # @example Basic usage
      #   config = Appraisals.destination_wins
      #   merger = Prism::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @example Template wins for specific appraisals
      #   config = Appraisals.custom(
      #     preference: {
      #       default: :destination,
      #       "ruby-3-3" => :template,  # Update Ruby 3.3 appraisal from template
      #       "head" => :template       # Update head appraisal from template
      #     },
      #     add_template_only: true
      #   )
      #
      # @see Kettle::Jem::Signatures.appraisals
      class Appraisals < Base
        class << self
          # Returns the signature generator for Appraisals file merging.
          #
          # @return [Proc] Lambda that generates signatures for Appraisals nodes
          def signature_generator
            Signatures.appraisals
          end

          # Returns node typing for categorizing different types of appraisals.
          #
          # Categorizes appraisals into:
          # - `:ruby_version`: Ruby version-specific appraisals (ruby-X-Y)
          # - `:deps_appraisal`: Dependency management appraisals (unlocked_deps, dep-heads)
          # - `:feature_appraisal`: Feature-specific appraisals (coverage, audit, style)
          # - `:runtime_appraisal`: Runtime environment appraisals (head, current)
          #
          # @return [Hash] Node typing configuration
          def default_node_typing
            {
              CallNode: ->(node) {
                return node unless node.name == :appraise

                first_arg = node.arguments&.arguments&.first
                return node unless first_arg.respond_to?(:unescaped)

                appraisal_name = first_arg.unescaped.to_s
                merge_type = categorize_appraisal(appraisal_name)

                merge_type ? Ast::Merge::NodeTyping.with_merge_type(node, merge_type) : node
              },
            }
          end

          private

          # Categorize an appraisal by its name.
          #
          # @param appraisal_name [String] The appraisal name
          # @return [Symbol, nil] The category or nil for uncategorized
          def categorize_appraisal(appraisal_name)
            case appraisal_name
            when /\Aruby[-_]?\d/, /\Ajruby/, /\Atruffle/
              :ruby_version
            when /deps/, /dep[-_]heads/, /locked/, /unlocked/
              :deps_appraisal
            when /coverage/, /audit/, /style/, /lint/
              :feature_appraisal
            when /\Ahead\z/, /\Acurrent\z/, /\Anightly/
              :runtime_appraisal
            end
          end
        end
      end
    end
  end
end
