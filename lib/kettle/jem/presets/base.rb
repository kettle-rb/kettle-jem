# frozen_string_literal: true

module Kettle
  module Jem
    module Presets
      # Base class for MergerConfig presets.
      #
      # Provides factory methods for common merge configurations:
      # - `destination_wins`: Preserve destination customizations
      # - `template_wins`: Apply template updates
      # - `custom`: Full control over all options
      #
      # Subclasses implement:
      # - `signature_generator`: Returns a proc for signature matching
      # - `node_typing`: Returns a hash for per-node-type preferences (optional)
      # - `default_freeze_token`: Returns the freeze token for this file type
      #
      # @abstract Subclass and implement {.signature_generator}
      class Base
        class << self
          # Create a config preset for "destination wins" merging.
          #
          # Destination customizations are preserved, template-only content is skipped.
          #
          # @param freeze_token [String, nil] Override freeze token (uses default if nil)
          # @param node_typing [Hash, nil] Override node typing (uses default if nil)
          # @return [Ast::Merge::MergerConfig] Config preset
          def destination_wins(freeze_token: nil, node_typing: nil)
            Ast::Merge::MergerConfig.new(
              preference: :destination,
              add_template_only_nodes: false,
              freeze_token: freeze_token || default_freeze_token,
              signature_generator: signature_generator,
              node_typing: node_typing || default_node_typing,
            )
          end

          # Create a config preset for "template wins" merging.
          #
          # Template updates are applied, template-only content is added.
          #
          # @param freeze_token [String, nil] Override freeze token (uses default if nil)
          # @param node_typing [Hash, nil] Override node typing (uses default if nil)
          # @return [Ast::Merge::MergerConfig] Config preset
          def template_wins(freeze_token: nil, node_typing: nil)
            Ast::Merge::MergerConfig.new(
              preference: :template,
              add_template_only_nodes: true,
              freeze_token: freeze_token || default_freeze_token,
              signature_generator: signature_generator,
              node_typing: node_typing || default_node_typing,
            )
          end

          # Create a custom config preset with full control over options.
          #
          # @param preference [Symbol, Hash] Merge preference (:destination, :template, or per-type Hash)
          # @param add_template_only [Boolean] Whether to add template-only nodes
          # @param freeze_token [String, nil] Override freeze token (uses default if nil)
          # @param node_typing [Hash, nil] Override node typing (uses default if nil)
          # @return [Ast::Merge::MergerConfig] Config preset
          def custom(preference:, add_template_only: false, freeze_token: nil, node_typing: nil)
            Ast::Merge::MergerConfig.new(
              preference: preference,
              add_template_only_nodes: add_template_only,
              freeze_token: freeze_token || default_freeze_token,
              signature_generator: signature_generator,
              node_typing: node_typing || default_node_typing,
            )
          end

          # Returns the signature generator for this preset.
          #
          # @abstract Subclasses must implement this method
          # @return [Proc] Lambda that generates signatures for nodes
          def signature_generator
            raise NotImplementedError, "#{self}#signature_generator must be implemented"
          end

          # Returns the default freeze token for this file type.
          #
          # @return [String, nil] The freeze token or nil for gem default
          def default_freeze_token
            "kettle-jem"
          end

          # Returns the default node typing configuration.
          #
          # Override in subclasses to provide per-node-type preferences.
          #
          # @return [Hash, nil] Node typing configuration or nil
          def default_node_typing
            nil
          end
        end
      end
    end
  end
end
