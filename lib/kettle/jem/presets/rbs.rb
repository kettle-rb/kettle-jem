# frozen_string_literal: true

module Kettle
  module Jem
    module Presets
      # MergerConfig preset for RBS (Ruby Signature) file merging.
      #
      # Designed for use with rbs-merge, providing intelligent merging
      # of Ruby type signature files.
      #
      # @example Basic usage
      #   config = Rbs.destination_wins
      #   merger = RBS::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @see RBS::Merge::SmartMerger
      class Rbs < Base
        class << self
          # Returns the signature generator for RBS file merging.
          #
          # RBS files are structured with:
          # - Module/class declarations
          # - Method signatures
          # - Type aliases
          # - Interface definitions
          #
          # @return [Proc, nil] Signature generator or nil for defaults
          def signature_generator
            # RBS merging uses declaration-based matching
            # rbs-merge handles this internally
            nil
          end

          # Returns the default freeze token for RBS files.
          #
          # Uses RBS comment syntax: # kettle-jem:freeze
          #
          # @return [String] The freeze token
          def default_freeze_token
            "kettle-jem"
          end
        end
      end
    end
  end
end
