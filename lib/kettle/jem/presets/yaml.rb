# frozen_string_literal: true

module Kettle
  module Jem
    module Presets
      # MergerConfig preset for YAML file merging.
      #
      # Designed for use with psych-merge, providing intelligent merging
      # of YAML configuration files including:
      # - GitHub Actions workflow files (.github/workflows/*.yml)
      # - RuboCop configuration (.rubocop.yml)
      # - CI/CD configuration files
      #
      # @example Basic usage
      #   config = Yaml.destination_wins
      #   merger = Psych::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @example Merging workflow files
      #   config = Yaml.workflow_config
      #   merger = Psych::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @see Psych::Merge::SmartMerger
      class Yaml < Base
        class << self
          # Returns the signature generator for YAML merging.
          #
          # For YAML files, signatures are typically based on:
          # - Key paths for hash entries
          # - Position for array elements
          # - Special handling for known structures (workflow jobs, etc.)
          #
          # @return [Proc, nil] Signature generator or nil for defaults
          def signature_generator
            # YAML merging typically uses key-based matching
            # psych-merge handles this internally
            nil
          end

          # Returns the default freeze token for YAML files.
          #
          # Uses YAML comment syntax: # kettle-jem:freeze
          #
          # @return [String] The freeze token
          def default_freeze_token
            "kettle-jem"
          end

          # Create a config preset optimized for GitHub Actions workflow files.
          #
          # Workflow files have specific structures:
          # - Jobs that should match by name
          # - Steps that may need special handling
          # - Matrix configurations that may differ
          #
          # The `uses:` key receives special treatment: the template always wins so
          # that SHA-pinned action references propagate from the template to every
          # downstream gem.  All other keys default to destination-wins so that
          # per-project customisations (matrix, env, timeouts, etc.) are preserved.
          #
          # @param freeze_token [String, nil] Override freeze token
          # @return [Ast::Merge::MergerConfig] Config preset
          def workflow_config(freeze_token: nil)
            Ast::Merge::MergerConfig.new(
              preference: { default: :destination, gha_action: :template },
              add_template_only_nodes: true,
              freeze_token: freeze_token || default_freeze_token,
              node_typing: gha_uses_node_typing,
            )
          end

          # Create a config preset optimized for RuboCop configuration.
          #
          # RuboCop configs have:
          # - Inherit directives that should usually come from template
          # - Cop configurations that may be customized
          # - AllCops settings that set defaults
          #
          # @param freeze_token [String, nil] Override freeze token
          # @return [Ast::Merge::MergerConfig] Config preset
          def rubocop_config(freeze_token: nil)
            Ast::Merge::MergerConfig.new(
              preference: {
                :default => :destination,
                :inherit_from => :template,      # Template controls inheritance
                :inherit_mode => :template,      # Template controls inherit mode
                :require => :template,           # Template controls required extensions
                "AllCops" => :destination,     # Local AllCops customizations preserved
              },
              add_template_only_nodes: false, # Don't add new cops from template
              freeze_token: freeze_token || default_freeze_token,
            )
          end

          private

          # Node typing for GitHub Actions workflow files.
          #
          # Tags any YAML mapping entry whose key is `uses` with the merge type
          # `:gha_action`.  Combined with `preference: { gha_action: :template }` in
          # `workflow_config`, this ensures that SHA-pinned action references from the
          # template always overwrite older (floating-tag) values in destination files
          # while every other key continues to use the default (destination-wins) rule.
          #
          # The callable receives `Psych::Merge::FileAnalysis::MappingEntry` nodes.
          # The key name is exposed via `#key_name`.
          #
          # @return [Hash] node_typing configuration for Psych::Merge::SmartMerger
          def gha_uses_node_typing
            {
              MappingEntry: ->(node) {
                node.key_name == "uses" ? Ast::Merge::NodeTyping.with_merge_type(node, :gha_action) : node
              },
            }
          end
        end
      end
    end
  end
end
