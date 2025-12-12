# frozen_string_literal: true

module Kettle
  module Jem
    module Presets
      # MergerConfig preset for gemspec file merging.
      #
      # Provides intelligent signature matching for gemspec constructs:
      # - `spec.name =`, `spec.version =`, etc. assignments
      # - `spec.add_dependency`, `spec.add_development_dependency` calls
      # - `Gem::Specification.new` blocks
      #
      # @example Basic usage
      #   config = Gemspec.destination_wins
      #   merger = Prism::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @example Template wins for metadata, destination for dependencies
      #   config = Gemspec.custom(
      #     preference: {
      #       default: :destination,
      #       spec_metadata: :template  # Update metadata from template
      #     },
      #     add_template_only: true
      #   )
      #
      # @see Kettle::Jem::Signatures.gemspec
      class Gemspec < Base
        class << self
          # Returns the signature generator for gemspec file merging.
          #
          # @return [Proc] Lambda that generates signatures for gemspec nodes
          def signature_generator
            Signatures.gemspec
          end

          # Returns node typing for categorizing gemspec attributes.
          #
          # Categorizes spec attributes into:
          # - `:spec_identity`: name, version
          # - `:spec_metadata`: summary, description, homepage, license, authors, email
          # - `:spec_files`: files, require_paths, executables, bindir
          # - `:spec_dependency`: add_dependency, add_development_dependency
          # - `:spec_requirements`: required_ruby_version, required_rubygems_version
          #
          # @return [Hash] Node typing configuration
          def default_node_typing
            {
              CallNode: ->(node) {
                method_name = node.name.to_s
                receiver = node.receiver

                # Check if this is a spec.foo call
                is_spec_call = receiver.respond_to?(:name) && receiver.name == :spec

                unless is_spec_call
                  # Check for spec_something receiver
                  is_spec_call = receiver&.slice&.to_s&.start_with?("spec")
                end

                return node unless is_spec_call

                merge_type = categorize_spec_attribute(method_name)
                merge_type ? Ast::Merge::NodeTyping.with_merge_type(node, merge_type) : node
              },
            }
          end

          private

          # Categorize a gemspec attribute by its method name.
          #
          # @param method_name [String] The method name (e.g., "name=", "add_dependency")
          # @return [Symbol, nil] The category or nil for uncategorized
          def categorize_spec_attribute(method_name)
            # Remove trailing = for assignment methods
            attr_name = method_name.delete_suffix("=")

            case attr_name
            when "name", "version"
              :spec_identity
            when "summary", "description", "homepage", "license", "licenses",
                 "authors", "email", "metadata"
              :spec_metadata
            when "files", "require_paths", "executables", "bindir", "test_files",
                 "extra_rdoc_files", "rdoc_options"
              :spec_files
            when "add_dependency", "add_development_dependency", "add_runtime_dependency"
              :spec_dependency
            when "required_ruby_version", "required_rubygems_version"
              :spec_requirements
            when "cert_chain", "signing_key"
              :spec_signing
            end
          end
        end
      end
    end
  end
end
