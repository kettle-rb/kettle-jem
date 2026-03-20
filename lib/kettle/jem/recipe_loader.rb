# frozen_string_literal: true

module Kettle
  module Jem
    # Recipe loader for kettle-jem recipe configurations.
    #
    # Provides a simple interface for loading YAML-based recipes that define
    # merge behavior for various file types (Gemfile, gemspec, Rakefile, etc.).
    #
    # kettle-jem loads these files as `Ast::Merge::Recipe::Config` instances,
    # even when they omit template/target bindings. That allows a single YAML
    # contract to serve both as SmartMerger options (`#to_h`) and as an
    # executable content recipe (`Runner#run_content`).
    #
    # @example Loading a recipe
    #   recipe = Kettle::Jem.recipe(:gemfile)
    #   merger = Prism::Merge::SmartMerger.new(
    #     template, destination,
    #     **recipe.to_h
    #   )
    #
    # @example Using a recipe with SmartMerger directly
    #   recipe = Kettle::Jem.recipe(:gemspec)
    #   merger = Prism::Merge::SmartMerger.new(
    #     template, destination,
    #     signature_generator: recipe.signature_generator,
    #     node_typing: recipe.node_typing,
    #     preference: recipe.preference
    #   )
    #
    # @example Executing a content recipe in memory
    #   recipe = Kettle::Jem.recipe(:readme)
    #   merged = Ast::Merge::Recipe::Runner.new(recipe).run_content(
    #     template_content: template,
    #     destination_content: destination,
    #   ).content
    #
    # @see Ast::Merge::Recipe::Config
    module RecipeLoader
      # Directory containing recipe YAML files
      RECIPES_DIR = File.expand_path("recipes", __dir__)

      # Available recipe names
      AVAILABLE_RECIPES = %i[gemfile gemspec rakefile appraisals markdown readme changelog dotenv].freeze

      class << self
        # Load a recipe by name.
        #
        # @param name [Symbol, String] Recipe name (e.g., :gemfile, :gemspec)
        # @return [Ast::Merge::Recipe::Config] Loaded recipe configuration
        # @raise [ArgumentError] If recipe not found
        def load(name)
          name = name.to_sym
          path = recipe_path(name)

          unless File.exist?(path)
            available = AVAILABLE_RECIPES.join(", ")
            raise ArgumentError, "Unknown recipe: #{name}. Available: #{available}"
          end

          require "ast-merge" unless defined?(Ast::Merge::Recipe::Config)
          Ast::Merge::Recipe::Config.load(path)
        end

        # Check if a recipe exists.
        #
        # @param name [Symbol, String] Recipe name
        # @return [Boolean]
        def exists?(name)
          File.exist?(recipe_path(name.to_sym))
        end

        # List all available recipes.
        #
        # @return [Array<Symbol>]
        def available
          Dir.glob(File.join(RECIPES_DIR, "*.yml")).map do |path|
            File.basename(path, ".yml").to_sym
          end
        end

        # Get the path to a recipe file.
        #
        # @param name [Symbol] Recipe name
        # @return [String] Absolute path to recipe YAML file
        def recipe_path(name)
          File.join(RECIPES_DIR, "#{name}.yml")
        end
      end
    end
  end
end
