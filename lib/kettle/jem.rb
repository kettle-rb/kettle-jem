# frozen_string_literal: true

# External gems
require "ast-merge"
require "dotenv-merge"
require "json-merge"
require "kettle-dev"
require "markly-merge"
require "prism-merge"
require "psych-merge"
require "rbs-merge"
require "token-resolver"
require "version_gem"

# Shared merge infrastructure
require "ast/merge"

# This gem - only version can be required (never autoloaded)
require_relative "jem/version"

module Kettle
  # Kettle::Jem provides MergerConfig presets for common file type merging scenarios.
  #
  # These presets encapsulate signature generators, node typing configurations,
  # and section classifiers for merging various file types used in gem templating:
  #
  # - Ruby files (Gemfile, Appraisals, gemspec)
  # - Markdown files (README.md, CHANGELOG.md)
  # - YAML files (.github/workflows/*.yml, .rubocop.yml)
  # - JSON files (package.json, .eslintrc.json)
  # - RBS files (sig/*.rbs)
  # - Dotenv files (.env, .env.example)
  #
  # @example Using a Gemfile preset
  #   config = Kettle::Jem::Presets::Gemfile.destination_wins
  #   merger = Prism::Merge::SmartMerger.new(template, dest, **config.to_h)
  #
  # @example Using a Markdown preset with fenced code block handling
  #   config = Kettle::Jem::Presets::Markdown.template_wins
  #   merger = Markly::Merge::SmartMerger.new(template, dest, **config.to_h)
  #
  # @see Kettle::Jem::Presets
  # @see Ast::Merge::MergerConfig
  module Jem
    # Base error class for all kettle-jem operations.
    # @api public
    class Error < StandardError; end

    # Autoload presets module
    autoload :Presets, "kettle/jem/presets"

    # Autoload classifier helpers
    autoload :Classifiers, "kettle/jem/classifiers"

    # Autoload signature generators
    autoload :Signatures, "kettle/jem/signatures"

    # Autoload recipe loader for YAML-based recipes
    autoload :RecipeLoader, "kettle/jem/recipe_loader"

    # Prism AST utilities (moved from kettle-dev)
    autoload :PrismUtils, "kettle/jem/prism_utils"
    autoload :PrismGemspec, "kettle/jem/prism_gemspec"
    autoload :PrismGemfile, "kettle/jem/prism_gemfile"
    autoload :PrismAppraisals, "kettle/jem/prism_appraisals"
    autoload :SourceMerger, "kettle/jem/source_merger"

    # Templating and setup (moved from kettle-dev)
    autoload :TemplateHelpers, "kettle/jem/template_helpers"
    autoload :ModularGemfiles, "kettle/jem/modular_gemfiles"
    autoload :SetupCLI, "kettle/jem/setup_cli"

    # Recipe-driven mergers
    autoload :MarkdownMerger, "kettle/jem/markdown_merger"
    autoload :ChangelogMerger, "kettle/jem/changelog_merger"

    # Task modules (moved from kettle-dev)
    module Tasks
      autoload :InstallTask, "kettle/jem/tasks/install_task"
      autoload :SelfTestTask, "kettle/jem/tasks/self_test_task"
      autoload :TemplateTask, "kettle/jem/tasks/template_task"
    end

    # Self-test tooling for validating the templating process
    module SelfTest
      autoload :Manifest, "kettle/jem/self_test/manifest"
      autoload :Reporter, "kettle/jem/self_test/reporter"
    end

    class << self
      # Load a recipe by name.
      #
      # @param name [Symbol, String] Recipe name (e.g., :gemfile, :gemspec)
      # @return [Ast::Merge::Recipe::Config] Loaded recipe configuration
      # @raise [ArgumentError] If recipe not found
      def recipe(name)
        RecipeLoader.load(name)
      end

      # List all available recipes.
      #
      # @return [Array<Symbol>]
      def available_recipes
        RecipeLoader.available
      end

      # Install Rake tasks shipped by kettle-jem.
      #
      # Loads the gem-shipped rakelib directory so host projects that depend
      # on kettle-jem automatically get the kettle:jem:* tasks (template,
      # install, selftest, etc.).
      # @return [void]
      def install_tasks
        load("kettle/jem/tasks.rb")
      end
    end
  end
end

Kettle::Jem::Version.class_eval do
  extend VersionGem::Basic
end

# Auto-install Rake tasks when loaded under the rake executable,
# mirroring the pattern used by kettle-dev.
Kettle::Jem.install_tasks if Kettle::Dev::RUNNING_AS == "rake"
