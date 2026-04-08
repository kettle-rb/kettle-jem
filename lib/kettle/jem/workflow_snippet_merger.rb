# frozen_string_literal: true

module Kettle
  module Jem
    # Applies workflow snippet templates to custom (non-fully-templated) workflow
    # files using Psych::Merge::PartialTemplateMerger for surgical section merging.
    #
    # Top-level snippets (triggers, concurrency, permissions) are merged at their
    # YAML key paths. Step snippets update action SHA pins in existing step sequences
    # by matching on the `uses:` key prefix.
    #
    # @example Apply all snippets to a custom workflow
    #   merger = WorkflowSnippetMerger.new(
    #     snippet_root: helpers.template_root + "/.github/workflow-snippets",
    #     destination_content: File.read("dynamoid/.github/workflows/ci.yml"),
    #   )
    #   result = merger.apply_all
    #   # result.content has updated action pins, triggers, concurrency
    class WorkflowSnippetMerger
      # Snippets that map directly to top-level YAML key paths.
      # Each entry: [snippet filename, key_path for PTM]
      SECTION_SNIPPETS = [
        ["triggers.yml", ["on"]],
        ["concurrency.yml", ["concurrency"]],
        ["permissions.yml", ["permissions"]],
      ].freeze

      # Snippets containing step sequences whose `uses:` SHA pins should be
      # propagated into destination job steps. These are NOT merged via PTM
      # key paths — instead, they update matching steps by action name prefix.
      STEP_SNIPPETS = %w[
        steps-checkout.yml
        steps-setup-ruby.yml
        steps-appraisal-retry.yml
        steps-coverage-reporting.yml
      ].freeze

      # @param snippet_root [String] path to workflow-snippets directory
      # @param destination_content [String] current workflow YAML content
      # @param preference [Symbol] PTM preference (:template or :destination)
      def initialize(snippet_root:, destination_content:, preference: :template)
        @snippet_root = snippet_root
        @content = destination_content.dup
        @preference = preference
      end

      # Apply all section snippets and step-pin updates.
      # Returns the merged content string.
      #
      # @return [String] merged workflow YAML
      def apply_all
        apply_section_snippets
        apply_step_pin_updates
        @content
      end

      # Apply only section snippets (triggers, concurrency, permissions).
      #
      # @return [String] merged workflow YAML
      def apply_sections_only
        apply_section_snippets
        @content
      end

      # Apply only step SHA pin updates.
      #
      # @return [String] merged workflow YAML
      def apply_pins_only
        apply_step_pin_updates
        @content
      end

      private

      # Merge each section snippet at its key path using PTM.
      def apply_section_snippets
        SECTION_SNIPPETS.each do |filename, key_path|
          snippet_path = File.join(@snippet_root, filename)
          next unless File.exist?(snippet_path)

          snippet_yaml = File.read(snippet_path)
          # Extract just the value at the key path from the snippet
          parsed = Psych.safe_load(snippet_yaml)
          next unless parsed.is_a?(Hash)

          # PTM merges template content at a specific key path in the destination.
          # The template content is the value at the key path in the snippet.
          value_at_path = dig_path(parsed, key_path)
          next unless value_at_path

          # Build a minimal YAML document with just the value for PTM
          result = Psych::Merge::PartialTemplateMerger.new(
            template: Psych.dump(value_at_path).sub(/\A---\n?/, ""),
            destination: @content,
            key_path: key_path,
            preference: @preference,
            add_missing: true,
            when_missing: :add,
          ).merge

          @content = result.content if result.changed || !result.key_path_found?
        end
      end

      # Update SHA-pinned action references in destination steps.
      # For each step snippet, find matching steps in the destination by
      # action name prefix (e.g. "actions/checkout@") and replace the
      # full `uses:` value with the template's pinned version.
      def apply_step_pin_updates
        template_pins = collect_step_pins

        # Replace action pins in the destination content using string matching.
        # This is intentionally simple — action pins are single-line `uses:` values.
        template_pins.each do |action_prefix, pinned_value|
          # Match: uses: <action_prefix>@<any-sha-or-tag> with optional comment
          @content = @content.gsub(
            /(?<=uses:\s)#{Regexp.escape(action_prefix)}@\S+/,
            pinned_value,
          )
        end
      end

      # Collect all action pins from step snippets.
      # @return [Hash<String, String>] action_prefix => full "action@sha # comment"
      def collect_step_pins
        pins = {}
        STEP_SNIPPETS.each do |filename|
          snippet_path = File.join(@snippet_root, filename)
          next unless File.exist?(snippet_path)

          content = File.read(snippet_path)
          # Extract uses: lines from step snippets
          content.scan(/uses:\s*(\S+@\S+.*)$/).each do |match|
            full_ref = match[0].strip
            action_prefix = full_ref.split("@").first
            pins[action_prefix] = full_ref
          end
        end
        pins
      end

      # Dig into a nested hash by key path.
      # @param hash [Hash]
      # @param path [Array<String>]
      # @return [Object, nil]
      def dig_path(hash, path)
        path.reduce(hash) do |current, key|
          return nil unless current.is_a?(Hash)

          current[key]
        end
      end
    end
  end
end
