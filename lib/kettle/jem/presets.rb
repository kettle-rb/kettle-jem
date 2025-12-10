# frozen_string_literal: true

module Kettle
  module Jem
    # MergerConfig presets for common file types in gem templating.
    #
    # Each preset provides:
    # - A signature_generator for matching nodes between files
    # - Optional node_typing configuration for per-node-type preferences
    # - Optional section classifiers for AST-aware section handling
    #
    # @example Using the Gemfile preset
    #   config = Presets::Gemfile.destination_wins(freeze_token: "kettle-dev")
    #   merger = Prism::Merge::SmartMerger.new(template, dest, **config.to_h)
    #
    # @see Ast::Merge::MergerConfig
    module Presets
      autoload :Base, "kettle/jem/presets/base"
      autoload :Gemfile, "kettle/jem/presets/gemfile"
      autoload :Appraisals, "kettle/jem/presets/appraisals"
      autoload :Gemspec, "kettle/jem/presets/gemspec"
      autoload :Markdown, "kettle/jem/presets/markdown"
      autoload :Yaml, "kettle/jem/presets/yaml"
      autoload :Json, "kettle/jem/presets/json"
      autoload :Rbs, "kettle/jem/presets/rbs"
      autoload :Dotenv, "kettle/jem/presets/dotenv"
      autoload :Rakefile, "kettle/jem/presets/rakefile"
    end
  end
end
