# frozen_string_literal: true

require "digest"
require "find"
require "yaml"

module Kettle
  module Jem
    # Computes and compares SHA-256 checksums for all files in the template directory.
    #
    # Checksums are stored in the destination project's .kettle-jem.yml under
    # the `kettle-jem:` top-level key. On each template run the new checksums are
    # compared against the stored values to detect which template files have changed.
    #
    # @example
    #   current  = TemplateChecksums.compute(template_root: template_root)
    #   stored   = TemplateChecksums.load_stored(config_path: config_path)
    #   diff     = TemplateChecksums.diff(current: current, stored: stored)
    #   puts TemplateChecksums.summary(diff)
    #   TemplateChecksums.write_to_config(config_path: config_path, checksums: current, version: "1.2.3")
    module TemplateChecksums
      YAML_KEY = "kettle-jem"
      CHECKSUMS_SUBKEY = "checksums"
      VERSION_SUBKEY = "version"

      module_function

      # Compute SHA-256 checksums for all files under +template_root+.
      #
      # @param template_root [String] absolute path to the template directory
      # @return [Hash{String => String}] relative paths → SHA-256 hex digests, sorted
      def compute(template_root:)
        root = template_root.to_s.chomp("/")
        checksums = {}
        Find.find(root) do |path|
          next unless File.file?(path)

          rel = path.delete_prefix("#{root}/")
          checksums[rel] = Digest::SHA256.file(path).hexdigest
        end
        checksums
      end

      # Load previously stored checksums from the destination .kettle-jem.yml.
      #
      # @param config_path [String] path to .kettle-jem.yml in the destination project
      # @return [Hash{String => String}] stored relative paths → SHA-256 digests (empty if absent)
      def load_stored(config_path:)
        return {} unless File.exist?(config_path.to_s)

        data = YAML.safe_load_file(config_path.to_s, permitted_classes: [], aliases: false)
        return {} unless data.is_a?(Hash)

        entry = data[YAML_KEY]
        return {} unless entry.is_a?(Hash)

        stored = entry[CHECKSUMS_SUBKEY]
        stored.is_a?(Hash) ? stored : {}
      rescue StandardError
        {}
      end

      # Compare current checksums against stored checksums.
      #
      # @param current [Hash{String => String}] freshly computed checksums
      # @param stored  [Hash{String => String}] previously stored checksums
      # @return [Hash{Symbol => Array<String>}] keys: :added, :changed, :removed
      def diff(current:, stored:)
        current_keys = current.keys.to_set
        stored_keys = stored.keys.to_set

        added = (current_keys - stored_keys).sort
        removed = (stored_keys - current_keys).sort
        changed = (current_keys & stored_keys).select { |k| current[k] != stored[k] }.sort

        {added: added, changed: changed, removed: removed}
      end

      # Total number of differences.
      #
      # @param diff [Hash] result of {.diff}
      # @return [Integer]
      def diff_count(diff)
        diff[:added].size + diff[:changed].size + diff[:removed].size
      end

      # Human-readable one-line summary of a diff.
      #
      # @param diff [Hash] result of {.diff}
      # @return [String]
      def summary(diff)
        count = diff_count(diff)
        return "no template files changed since last run" if count.zero?

        parts = []
        parts << "#{diff[:added].size} added" if diff[:added].any?
        parts << "#{diff[:changed].size} changed" if diff[:changed].any?
        parts << "#{diff[:removed].size} removed" if diff[:removed].any?
        "#{count} template file(s) since last run: #{parts.join(", ")}"
      end

      # Multi-line detail listing for verbose output.
      #
      # @param diff [Hash] result of {.diff}
      # @return [Array<String>] individual file-level lines
      def detail_lines(diff)
        lines = []
        diff[:added].each { |f| lines << "  + #{f}" }
        diff[:changed].each { |f| lines << "  ~ #{f}" }
        diff[:removed].each { |f| lines << "  - #{f}" }
        lines
      end

      # Write current checksums into the `kettle-jem:` section of a .kettle-jem.yml file.
      #
      # The file is edited line-by-line so that all existing YAML comments and
      # formatting outside the `kettle-jem:` block are preserved.  If the block
      # is already present it is replaced in-place; otherwise it is appended.
      #
      # @param config_path [String] path to .kettle-jem.yml
      # @param checksums   [Hash{String => String}] current checksums
      # @param version     [String, nil] kettle-jem version string
      # @return [void]
      def write_to_config(config_path:, checksums:, version: nil)
        return unless File.exist?(config_path.to_s)

        content = File.read(config_path.to_s)
        new_block = build_yaml_block(checksums: checksums, version: version)

        updated =
          if content.match?(/^kettle-jem:\s*(?:#[^\n]*)?\n/)
            replace_kettle_jem_block(content, new_block)
          else
            "#{content.rstrip}\n\n#{new_block}\n"
          end

        File.write(config_path.to_s, updated)
      end

      # @api private
      def build_yaml_block(checksums:, version: nil)
        lines = ["#{YAML_KEY}:"]
        lines << "  #{VERSION_SUBKEY}: #{version.to_s.dump}" if version
        lines << "  #{CHECKSUMS_SUBKEY}:"
        checksums.sort.each do |path, sha|
          lines << "    #{path.dump}: #{sha.dump}"
        end
        lines.join("\n")
      end

      # @api private
      def replace_kettle_jem_block(content, new_block)
        # Matches 'kettle-jem:' header line plus any following indented lines
        content.gsub(/^kettle-jem:[^\n]*\n(?:[ \t][^\n]*\n)*/, "#{new_block}\n")
      end
    end
  end
end
