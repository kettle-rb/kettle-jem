# frozen_string_literal: true

module Kettle
  module Jem
    module Presets
      # MergerConfig preset for JSON file merging.
      #
      # Designed for use with json-merge, providing intelligent merging
      # of JSON configuration files including:
      # - package.json
      # - tsconfig.json
      # - ESLint configuration (.eslintrc.json)
      # - VS Code settings
      #
      # @example Basic usage
      #   config = Json.destination_wins
      #   merger = JSON::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @see JSON::Merge::SmartMerger
      class Json < Base
        class << self
          # Returns the signature generator for JSON merging.
          #
          # For JSON files, signatures are based on:
          # - Key paths for object properties
          # - Position for array elements
          # - Special handling for known structures
          #
          # @return [Proc, nil] Signature generator or nil for defaults
          def signature_generator
            # JSON merging uses key-based matching
            # json-merge handles this internally
            nil
          end

          # Returns the default freeze token for JSON files.
          #
          # JSON doesn't support comments, so freeze tokens aren't applicable.
          #
          # @return [nil] No freeze token for JSON
          def default_freeze_token
            nil
          end

          # Create a config preset optimized for package.json files.
          #
          # Package.json files have:
          # - Version and name that are identity fields
          # - Dependencies that may be customized
          # - Scripts that may be extended
          #
          # @param add_template_scripts [Boolean] Whether to add new scripts from template
          # @return [Ast::Merge::MergerConfig] Config preset
          def package_json_config(add_template_scripts: true)
            Ast::Merge::MergerConfig.new(
              preference: {
                default: :destination,
                "engines" => :template,       # Engine requirements from template
                "license" => :template,       # License from template
                "repository" => :template     # Repository info from template
              },
              add_template_only_nodes: add_template_scripts
            )
          end

          # Create a config preset optimized for VS Code settings.
          #
          # VS Code settings should generally preserve user customizations.
          #
          # @return [Ast::Merge::MergerConfig] Config preset
          def vscode_settings_config
            Ast::Merge::MergerConfig.new(
              preference: :destination,
              add_template_only_nodes: true # Add new recommended settings
            )
          end
        end
      end
    end
  end
end
