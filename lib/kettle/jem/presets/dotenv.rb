# frozen_string_literal: true

module Kettle
  module Jem
    module Presets
      # MergerConfig preset for dotenv file merging.
      #
      # Designed for use with dotenv-merge, providing intelligent merging
      # of environment variable files like:
      # - .env
      # - .env.example
      # - .env.local
      # - .env.development
      #
      # @example Basic usage
      #   config = Dotenv.destination_wins
      #   merger = Dotenv::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @see Dotenv::Merge::SmartMerger
      class Dotenv < Base
        class << self
          # Returns the signature generator for dotenv file merging.
          #
          # Dotenv files have simple KEY=value structure.
          # Matching is done by environment variable name.
          #
          # @return [Proc, nil] Signature generator or nil for defaults
          def signature_generator
            # Dotenv merging matches by variable name
            # dotenv-merge handles this internally
            nil
          end

          # Returns the default freeze token for dotenv files.
          #
          # Uses shell comment syntax: # kettle-jem:freeze
          #
          # @return [String] The freeze token
          def default_freeze_token
            "kettle-jem"
          end

          # Create a config preset for .env.example files.
          #
          # Example files should generally use template values as they
          # document expected variables.
          #
          # @return [Ast::Merge::MergerConfig] Config preset
          def example_config
            Ast::Merge::MergerConfig.new(
              preference: :template,
              add_template_only_nodes: true,
              freeze_token: default_freeze_token,
            )
          end

          # Create a config preset for actual .env files.
          #
          # Actual env files should preserve user values.
          #
          # @return [Ast::Merge::MergerConfig] Config preset
          def local_config
            Ast::Merge::MergerConfig.new(
              preference: :destination,
              add_template_only_nodes: true, # Add new vars from template
              freeze_token: default_freeze_token,
            )
          end
        end
      end
    end
  end
end
