# frozen_string_literal: true

module Kettle
  module Jem
    # Recipe loader for kettle-jem preset configurations.
    #
    # Provides a simple interface for loading YAML-based presets that define
    # merge behavior for various file types (Gemfile, gemspec, Rakefile, etc.).
    #
    # These presets use `Ast::Merge::Recipe::Preset` (not `Config`) because
    # they define merge configuration without specifying template/target files.
    #
    # @example Loading a preset
    #   preset = Kettle::Jem.recipe(:gemfile)
    #   merger = Prism::Merge::SmartMerger.new(
    #     template, destination,
    #     **preset.to_h
    #   )
    #
    # @example Using preset with SmartMerger directly
    #   preset = Kettle::Jem.recipe(:gemspec)
    #   merger = Prism::Merge::SmartMerger.new(
    #     template, destination,
    #     signature_generator: preset.signature_generator,
    #     node_typing: preset.node_typing,
    #     preference: preset.preference
    #   )
    #
    # @see Ast::Merge::Recipe::Preset
    module RecipeLoader
      # Directory containing recipe YAML files
      RECIPES_DIR = File.expand_path("recipes", __dir__)

      # Available recipe names
      AVAILABLE_RECIPES = %i[gemfile gemspec rakefile appraisals markdown readme changelog dotenv].freeze

      class << self
        # Load a preset by name.
        #
        # @param name [Symbol, String] Preset name (e.g., :gemfile, :gemspec)
        # @return [Ast::Merge::Recipe::Preset] Loaded preset configuration
        # @raise [ArgumentError] If preset not found
        def load(name)
          name = name.to_sym
          path = recipe_path(name)

          unless File.exist?(path)
            available = AVAILABLE_RECIPES.join(", ")
            raise ArgumentError, "Unknown preset: #{name}. Available: #{available}"
          end

          require "ast-merge" unless defined?(Ast::Merge::Recipe::Preset)
          Ast::Merge::Recipe::Preset.load(path)
        end

        # Check if a preset exists.
        #
        # @param name [Symbol, String] Preset name
        # @return [Boolean]
        def exists?(name)
          File.exist?(recipe_path(name.to_sym))
        end

        # List all available presets.
        #
        # @return [Array<Symbol>]
        def available
          Dir.glob(File.join(RECIPES_DIR, "*.yml")).map do |path|
            File.basename(path, ".yml").to_sym
          end
        end

        # Get the path to a preset file.
        #
        # @param name [Symbol] Preset name
        # @return [String] Absolute path to preset YAML file
        def recipe_path(name)
          File.join(RECIPES_DIR, "#{name}.yml")
        end
      end
    end
  end
end
